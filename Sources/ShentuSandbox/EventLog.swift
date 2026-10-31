import Foundation

/// Appends one JSON object per line to a file. Thread-safe.
final class NDJSONWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let encoder: JSONEncoder

    init(_ url: URL) throws {
        try FileManager.default.ensureDirectory(url.deletingLastPathComponent())
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
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

/// Enforce-mode record: every denial plus the risky allows the profile reports.
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
        if op.hasPrefix("network-") { return ReportCategory.network.rawValue }
        if op.hasPrefix("process-exec") { return ReportCategory.exec.rawValue }
        if op.hasPrefix("file-write") {
            let path = Generalizer.path(from: event.target) ?? ""
            return ownFolders.contains { path.isWithin($0) } ? "write" : ReportCategory.writeOutside.rawValue
        }
        if op.hasPrefix("file-read") || op == "file-map-executable" { return "read" }
        if op.hasPrefix("mach-") { return "service" }
        if op.hasPrefix("iokit") { return "device" }
        return "allowed"
    }
}

/// Raw learn-mode capture, used to (re)generate configs.
func readCapture(_ url: URL) throws -> [SandboxEvent] {
    let decoder = JSONDecoder()
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .compactMap { try? decoder.decode(SandboxEvent.self, from: Data($0.utf8)) }
}
