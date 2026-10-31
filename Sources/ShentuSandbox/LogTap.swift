import Foundation

/// Streams kernel Seatbelt reports (`log stream`, sender == "Sandbox") while a target runs.
///
/// The reports are never persisted (`log show` finds none), so the stream must be live for the
/// whole run. `waitUntilLive` and `drain` prove that with a canary: a tiny sandboxed `touch` whose
/// denial must show up in the stream before launch and again after the target exits.
public final class LogTap: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var seenTokens: Set<String> = []
    private var watchedTokens: Set<String> = []
    private var notices = 0
    private let handler: @Sendable (SandboxEvent) -> Void
    private let canaryDir: URL

    /// `handler` is called on a background queue for every parsed allow/deny report.
    public init(canaryDir: URL, handler: @escaping @Sendable (SandboxEvent) -> Void) {
        self.canaryDir = canaryDir
        self.handler = handler
    }

    /// Non-log events in the stream (e.g. loss notices when logd drops messages under load).
    public var streamNotices: Int { lock.withLock { notices } }

    public func start() throws {
        try FileManager.default.ensureDirectory(canaryDir)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--level", "debug",
                             "--predicate", "sender == \"Sandbox\""]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.consume(data)
        }
        try process.run()
    }

    /// Blocks until a canary denial is seen in the stream (the stream can take a moment to attach).
    public func waitUntilLive(timeout: TimeInterval = 15) throws {
        guard runCanary(timeout: timeout) else {
            throw ShentuError.failed("log stream did not deliver a sandbox report within \(Int(timeout))s; nothing would be captured")
        }
    }

    /// Blocks until a fresh canary shows up, so reports emitted before it have been read.
    @discardableResult
    public func drain(timeout: TimeInterval = 10) -> Bool {
        runCanary(timeout: timeout)
    }

    public func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    // MARK: - Internals

    private func runCanary(timeout: TimeInterval) -> Bool {
        let token = "shentu-canary-\(UUID().uuidString)"
        lock.withLock { _ = watchedTokens.insert(token) }
        defer { lock.withLock { _ = watchedTokens.remove(token) } }
        let deadline = Date().addingTimeInterval(timeout)
        // Deny reports from processes that exit immediately are sometimes dropped by the kernel,
        // so keep firing the canary until one lands.
        while Date() < deadline {
            let canary = Process()
            canary.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            canary.arguments = ["-D", "C=\(canaryDir.path)",
                                "-p", "(version 1)(allow default)(deny file-write-create (subpath (param \"C\")))",
                                "/usr/bin/touch", canaryDir.appendingPathComponent(token).path]
            canary.standardOutput = FileHandle.nullDevice
            canary.standardError = FileHandle.nullDevice
            try? canary.run()
            canary.waitUntilExit()
            for _ in 0..<5 {
                if lock.withLock({ seenTokens.contains(token) }) { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return false
    }

    private func consume(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        for line in lines {
            guard line.first == UInt8(ascii: "{"),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let type = object["eventType"] as? String, type != "logEvent" {
                lock.withLock { notices += 1 }
                continue
            }
            guard let message = object["eventMessage"] as? String else { continue }
            if message.contains("shentu-canary-") {
                lock.withLock {
                    for token in watchedTokens where message.contains(token) { seenTokens.insert(token) }
                }
                continue
            }
            if let event = ReportParser.parse(message) {
                handler(event)
            }
        }
    }
}
