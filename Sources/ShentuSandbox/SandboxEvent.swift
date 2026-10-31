import Foundation

public enum Verdict: String, Codable, Sendable {
    case allow
    case deny
}

/// One kernel Seatbelt report, e.g. `Sandbox: VLC(81047) allow mach-lookup com.apple.foo`.
public struct SandboxEvent: Codable, Equatable, Sendable {
    public var process: String
    public var pid: Int32
    public var verdict: Verdict
    public var operation: String
    /// Everything after the operation name, verbatim ("" when the report has no target).
    public var target: String
    /// Number of reports this line stands for ("N duplicate reports for …" lines carry N).
    public var count: Int

    public init(process: String, pid: Int32, verdict: Verdict, operation: String, target: String, count: Int = 1) {
        self.process = process
        self.pid = pid
        self.verdict = verdict
        self.operation = operation
        self.target = target
        self.count = count
    }
}

public enum ReportParser {
    /// Parses the first line of a kernel Sandbox log message. Returns nil for anything that
    /// isn't an allow/deny report (e.g. `Sandbox apply: …`).
    public static func parse(_ message: String) -> SandboxEvent? {
        var line = Substring(message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        var count = 1

        // "317 duplicate reports for Sandbox: …" / "1 duplicate report for Sandbox: …"
        if let first = line.first, first.isNumber, let range = line.range(of: " for Sandbox: ") {
            let prefix = line[line.startIndex..<range.lowerBound]
            let digits = prefix.prefix(while: \.isNumber)
            guard prefix.dropFirst(digits.count).hasPrefix(" duplicate report"), let n = Int(digits) else { return nil }
            count = n
            line = line[range.upperBound...]
        } else if line.hasPrefix("Sandbox: ") {
            line = line.dropFirst("Sandbox: ".count)
        } else {
            return nil
        }

        // Find "(<pid>) allow " or "(<pid>) deny(<n>) ". Process names may contain spaces and
        // parentheses, so scan for the first ")" that is followed by a verdict and preceded by digits.
        var search = line.startIndex
        while let close = line[search...].firstIndex(of: ")") {
            let afterClose = line.index(after: close)
            let tail = line[afterClose...]
            let verdict: Verdict
            let rest: Substring
            if tail.hasPrefix(" allow ") || tail == " allow" {
                verdict = .allow
                rest = tail.dropFirst(" allow".count)
            } else if tail.hasPrefix(" deny("), let endParen = tail.firstIndex(of: ")") {
                verdict = .deny
                rest = tail[tail.index(after: endParen)...]
            } else {
                search = afterClose
                continue
            }
            guard let open = line[..<close].lastIndex(of: "("),
                  let pid = Int32(line[line.index(after: open)..<close]) else {
                search = afterClose
                continue
            }
            let process = String(line[..<open])
            let body = rest.drop(while: { $0 == " " })
            let operation = body.prefix(while: { $0 != " " })
            guard !operation.isEmpty else { return nil }
            let target = body.dropFirst(operation.count).drop(while: { $0 == " " })
            return SandboxEvent(
                process: process, pid: pid, verdict: verdict,
                operation: String(operation), target: String(target), count: count
            )
        }
        return nil
    }
}
