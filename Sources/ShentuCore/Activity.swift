import Foundation

/// How a run ended, from the process's exit and whether Shentu stopped it.
public enum RunEnd: Equatable, Sendable {
    /// Exit code 0.
    case quit
    /// A non-zero exit code. Often a refusal from the sandbox the app couldn't work around.
    case exited(Int32)
    /// Killed by a signal Shentu didn't send (a crash: SIGSEGV, SIGABRT, SIGILL, …).
    case crashed(Int32)
    /// Stopped with Stop.
    case stopped

    public init(_ outcome: Runner.Outcome) {
        if outcome.stoppedByShentu { self = .stopped }
        else if outcome.wasSignaled { self = .crashed(outcome.status) }
        else if outcome.status != 0 { self = .exited(outcome.status) }
        else { self = .quit }
    }

    public var title: String {
        switch self {
        case .quit: return "Quit"
        case .exited(let code): return "Quit with an error (exit code \(code))"
        case .crashed(let signal): return "Crashed (\(Self.signalName(signal)))"
        case .stopped: return "Stopped"
        }
    }

    public var isProblem: Bool {
        switch self {
        case .quit, .stopped: return false
        case .exited, .crashed: return true
        }
    }

    static func signalName(_ signal: Int32) -> String {
        let names: [Int32: String] = [SIGSEGV: "SIGSEGV", SIGABRT: "SIGABRT", SIGBUS: "SIGBUS", SIGILL: "SIGILL",
                                      SIGTRAP: "SIGTRAP", SIGKILL: "SIGKILL", SIGTERM: "SIGTERM", SIGFPE: "SIGFPE",
                                      SIGSYS: "SIGSYS", SIGPIPE: "SIGPIPE"]
        return names[signal] ?? "signal \(signal)"
    }
}

extension EnforceSummary {
    /// False if blocked requests may be missing from the log: the closing check never came
    /// through, or the system log reported dropping messages.
    public var logComplete: Bool { drained && streamNotices == 0 }
}

/// What a blocked request was after.
public enum ActivityGroup: String, CaseIterable, Sendable {
    case files, network, programs, services

    public var title: String {
        switch self {
        case .files: return "Files"
        case .network: return "Network"
        case .programs: return "Programs"
        case .services: return "Services"
        }
    }

    public static func of(_ operation: String) -> ActivityGroup {
        if operation.hasPrefix("file-") { return .files }
        if operation.hasPrefix("network-") || operation == "system-socket" { return .network }
        if operation.hasPrefix("process-exec") || operation == "lsopen" { return .programs }
        return .services
    }
}

/// One kind of blocked request: an operation on one target, with how often it happened.
public struct ActivityItem: Identifiable, Equatable, Sendable {
    public var id: String { "\(operation) \(target)" }
    public var group: ActivityGroup
    public var operation: String
    /// A path (with ~ for home), an address, or a service name.
    public var target: String
    public var count: Int
    /// Processes that made it, in order of first appearance.
    public var processes: [String]
    public var first: Date
    public var last: Date
}

/// The blocked requests of one run, grouped and counted. Allowed reports are ignored.
public struct ActivityLog: Equatable, Sendable {
    public private(set) var items: [ActivityItem] = []
    private var index: [String: Int] = [:]

    public init() {}

    public mutating func add(_ record: EnforceRecord) {
        guard record.verdict == .deny else { return }
        let key = "\(record.operation) \(record.target)"
        if let i = index[key] {
            items[i].count += record.count
            items[i].last = max(items[i].last, record.ts)
            if !items[i].processes.contains(record.process) { items[i].processes.append(record.process) }
        } else {
            index[key] = items.count
            items.append(ActivityItem(group: ActivityGroup.of(record.operation), operation: record.operation,
                                      target: record.target, count: record.count, processes: [record.process],
                                      first: record.ts, last: record.ts))
        }
    }

    /// A run's log file (one JSON record per line). Unreadable lines are skipped.
    public static func load(_ url: URL) -> ActivityLog {
        var log = ActivityLog()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return log }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in text.split(separator: "\n") {
            if let record = try? decoder.decode(EnforceRecord.self, from: Data(line.utf8)) { log.add(record) }
        }
        return log
    }

    /// Blocked requests in total, or in one group.
    public func total(_ group: ActivityGroup? = nil) -> Int {
        items.filter { group == nil || $0.group == group }.reduce(0) { $0 + $1.count }
    }

    /// Items in `group` (nil: all) whose target, operation or process contains `search`
    /// (any case), most frequent first.
    public func items(in group: ActivityGroup?, matching search: String) -> [ActivityItem] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            (group == nil || item.group == group) && (needle.isEmpty
                || item.target.localizedCaseInsensitiveContains(needle)
                || item.operation.localizedCaseInsensitiveContains(needle)
                || item.processes.contains { $0.localizedCaseInsensitiveContains(needle) })
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.target < $1.target }
    }

    /// CSV with a header row: group, operation, target, count, processes, first, last.
    public static func csv(_ items: [ActivityItem]) -> String {
        let iso = ISO8601DateFormatter()
        func field(_ s: String) -> String {
            // Quote every field; double the quotes. A leading = + - @ is prefixed with ' so
            // spreadsheets don't run a path as a formula.
            let safe = s.first.map { "=+-@".contains($0) } == true ? "'" + s : s
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["group,operation,target,count,processes,first,last"]
        for item in items {
            lines.append([field(item.group.title), field(item.operation), field(item.target), String(item.count),
                          field(item.processes.joined(separator: " ")), iso.string(from: item.first),
                          iso.string(from: item.last)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
