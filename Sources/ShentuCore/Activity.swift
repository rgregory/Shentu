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

extension ActivityGroup {
    /// Whether a blocked request is likely something you'd notice (a save, an open, a
    /// connection, starting a program) rather than the app's background housekeeping: its
    /// caches, settings and temp areas (~/Library, the per-user Darwin folders, /dev, /tmp)
    /// and system services. `target` is as logged, with ~ for home.
    public static func isNotable(operation: String, target: String) -> Bool {
        switch of(operation) {
        case .network, .programs: return true
        case .services: return operation == "appleevent-send"
        case .files:
            let background = ["~/Library/", "/private/var/folders/", "/var/folders/", "/dev/", "/private/tmp/",
                              "/tmp/", "/Library/Caches/", "/private/var/db/"]
            return target != "~/Library" && !background.contains { target.hasPrefix($0) }
        }
    }

    /// Plain words for a blocked operation: "save", "open", "connect to", …
    public static func verb(_ operation: String) -> String {
        switch operation {
        case "file-write-create": return "create"
        case "file-write-data": return "save"
        case "file-write-unlink": return "delete"
        case "file-write-mode", "file-write-owner", "file-write-flags", "file-write-times", "file-write-xattr":
            return "change"
        case "network-outbound": return "connect to"
        case "network-bind", "network-inbound": return "listen on"
        case "lsopen": return "open"
        case "appleevent-send": return "control"
        default:
            if operation.hasPrefix("file-write") { return "write" }
            if operation.hasPrefix("file-read") { return "open" }
            if operation.hasPrefix("process-exec") { return "run" }
            return operation
        }
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
    /// Likely something you'd notice, not background housekeeping (`ActivityGroup.isNotable`).
    public var notable: Bool = false

    /// "save /x/report.txt", "connect to 1.2.3.4:443".
    public var sentence: String { "\(ActivityGroup.verb(operation)) \(target.isEmpty ? "(no target)" : target)" }
}

/// Blocked requests over time, in quarter-second buckets per group, for the heart-monitor
/// view. Keeps the last two minutes.
public struct Pulse: Equatable, Sendable {
    public static let bucket: TimeInterval = 0.25
    static let keep: Int64 = 480
    private var counts: [Int64: [ActivityGroup: Int]] = [:]
    private var notables: [Int64: [ActivityGroup: Int]] = [:]
    private var newest: Int64?

    public init() {}

    /// The bucket a moment falls in.
    public static func index(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSinceReferenceDate / bucket).rounded(.down))
    }

    public mutating func add(_ group: ActivityGroup, at date: Date, count: Int, notable: Bool = false) {
        let i = Self.index(date)
        if let newest, i <= newest - Self.keep { return }
        counts[i, default: [:]][group, default: 0] += count
        if notable { notables[i, default: [:]][group, default: 0] += count }
        if newest == nil || i > newest! {
            newest = i
            if counts.count > Int(Self.keep) * 2 {
                counts = counts.filter { $0.key > i - Self.keep }
                notables = notables.filter { $0.key > i - Self.keep }
            }
        }
    }

    /// Notable blocked requests in bucket `i`, for one group or all (nil).
    public func notable(_ group: ActivityGroup?, _ i: Int64) -> Int {
        guard let bucket = notables[i] else { return 0 }
        if let group { return bucket[group] ?? 0 }
        return bucket.values.reduce(0, +)
    }

    /// Blocked requests in bucket `i`, for one group or all (nil).
    public func count(_ group: ActivityGroup?, _ i: Int64) -> Int {
        guard let bucket = counts[i] else { return 0 }
        if let group { return bucket[group] ?? 0 }
        return bucket.values.reduce(0, +)
    }

    /// Blocked requests in the second up to `end`.
    public func rate(_ group: ActivityGroup?, at end: Date) -> Int {
        let last = Self.index(end)
        return (last - 3...last).reduce(0) { $0 + count(group, $1) }
    }

    /// Buckets with anything in them (for tests).
    var filled: Int { counts.count }
}

/// The blocked requests of one run, grouped and counted. Allowed reports are ignored.
public struct ActivityLog: Equatable, Sendable {
    public private(set) var items: [ActivityItem] = []
    public private(set) var pulse = Pulse()
    /// The most recent notable blocked request, if any: shown on the run.
    public private(set) var latestNotable: ActivityItem?
    private var index: [String: Int] = [:]

    public init() {}

    public mutating func add(_ record: EnforceRecord) {
        guard record.verdict == .deny else { return }
        let notable = ActivityGroup.isNotable(operation: record.operation, target: record.target)
        pulse.add(ActivityGroup.of(record.operation), at: record.ts, count: record.count, notable: notable)
        let key = "\(record.operation) \(record.target)"
        let i: Int
        if let existing = index[key] {
            i = existing
            items[i].count += record.count
            items[i].last = max(items[i].last, record.ts)
            if !items[i].processes.contains(record.process) { items[i].processes.append(record.process) }
        } else {
            i = items.count
            index[key] = i
            items.append(ActivityItem(group: ActivityGroup.of(record.operation), operation: record.operation,
                                      target: record.target, count: record.count, processes: [record.process],
                                      first: record.ts, last: record.ts, notable: notable))
        }
        if notable && record.ts >= (latestNotable?.last ?? .distantPast) { latestNotable = items[i] }
    }

    /// Notable blocked requests in total, or in one group.
    public func notableTotal(_ group: ActivityGroup? = nil) -> Int {
        items.filter { $0.notable && (group == nil || $0.group == group) }.reduce(0) { $0 + $1.count }
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
    public func items(in group: ActivityGroup?, matching search: String, background: Bool = true) -> [ActivityItem] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            (group == nil || item.group == group) && (background || item.notable) && (needle.isEmpty
                || item.target.localizedCaseInsensitiveContains(needle)
                || item.operation.localizedCaseInsensitiveContains(needle)
                || item.processes.contains { $0.localizedCaseInsensitiveContains(needle) })
        }
        .sorted { a, b in
            // Notable first, then most frequent.
            if a.notable != b.notable { return a.notable }
            return a.count != b.count ? a.count > b.count : a.target < b.target
        }
    }

    /// CSV with a header row: group, operation, target, count, processes, first, last, notable.
    public static func csv(_ items: [ActivityItem]) -> String {
        let iso = ISO8601DateFormatter()
        func field(_ s: String) -> String {
            // Quote every field; double the quotes. A leading = + - @ is prefixed with ' so
            // spreadsheets don't run a path as a formula.
            let safe = s.first.map { "=+-@".contains($0) } == true ? "'" + s : s
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["group,operation,target,count,processes,first,last,notable"]
        for item in items {
            lines.append([field(item.group.title), field(item.operation), field(item.target), String(item.count),
                          field(item.processes.joined(separator: " ")), iso.string(from: item.first),
                          iso.string(from: item.last), item.notable ? "yes" : "no"].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
