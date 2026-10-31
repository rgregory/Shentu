import Foundation

/// Appends one JSON object per line to a file. Thread-safe.
final class NDJSONWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let encoder: JSONEncoder

    init(_ url: URL) throws {
        try FileManager.default.ensureDirectory(url.deletingLastPathComponent())
        // O_EXCL: never truncate or append to another run's log.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ShentuError.failed("can't create the log \(url.path): \(String(cString: strerror(errno)))") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    func write<T: Encodable>(_ value: T) {
        guard var data = try? encoder.encode(value) else { return }
        data.append(0x0A)
        lock.withLock { handle.write(data) }
    }

    func close() {
        lock.withLock { try? handle.close() }
    }
}

/// One logged event: every denial the kernel reports for the run.
public struct EnforceRecord: Codable, Equatable, Sendable {
    public var ts: Date
    public var runId: String
    public var pid: Int32
    public var process: String
    public var verdict: Verdict
    public var operation: String
    public var target: String
    public var category: String
    public var count: Int

    /// denied · network · exec · write (in the app's own folders) · write-outside · read · service · device
    static func category(for event: SandboxEvent, ownFolders: [String] = []) -> String {
        let op = event.operation
        if event.verdict == .deny { return "denied" }
        if op.hasPrefix("network-") { return "network" }
        if op.hasPrefix("process-exec") { return "exec" }
        if op.hasPrefix("file-write") {
            let path = Self.path(from: event.target) ?? ""
            return ownFolders.contains { path.isWithin($0) } ? "write" : "write-outside"
        }
        if op.hasPrefix("file-read") || op == "file-map-executable" { return "read" }
        if op.hasPrefix("mach-") { return "service" }
        if op.hasPrefix("iokit") { return "device" }
        return "allowed"
    }

    /// The file path in a sandbox report's target (`path:/x xattr:…`, `target:/x …`, or `/x`).
    static func path(from target: String) -> String? {
        if target.hasPrefix("/") { return target }
        for (prefix, terminators) in [("path:", [" xattr:", " ioctl-command:"]), ("target:", [" extension-class:"])] {
            guard target.hasPrefix(prefix) else { continue }
            var body = Substring(target.dropFirst(prefix.count))
            for t in terminators {
                if let r = body.range(of: t, options: .backwards) { body = body[..<r.lowerBound] }
            }
            return body.hasPrefix("/") ? String(body) : nil
        }
        return nil
    }
}
