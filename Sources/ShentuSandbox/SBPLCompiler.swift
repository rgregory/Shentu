import Foundation

/// One SBPL rule before rendering. Paths may start with `~`; they are expanded when rendered.
struct SBPLRule: Sendable {
    enum Action: String, Sendable {
        case allow
        case deny
    }

    var action: Action
    var operations: [String]
    /// nil: the rule applies to the whole operation.
    var filter: SBPLFilter?

    init(_ action: Action, _ operations: [String], _ filter: SBPLFilter? = nil) {
        self.action = action
        self.operations = operations
        self.filter = filter
    }
}

enum SBPLFilter: Hashable, Sendable {
    case subpath(String)
    case literal(String)
    /// A regex on full paths under the home folder (secrets by name, e.g. .env files).
    case homePattern(String)
    /// Comma-separated file extensions ("mp4,mkv"), matched anywhere, in any letter case.
    case fileTypes(String)
}

/// Builds Seatbelt (SBPL) profile text. Order matters: SBPL lets later matching rules override
/// earlier ones. The profile itself is `restrictedProfile` (Restricted.swift).
public struct SBPLCompiler {
    let environment: ShentuEnvironment

    public init(environment: ShentuEnvironment) {
        self.environment = environment
    }

    /// Merges rules into as few statements as possible without changing what they permit.
    /// Allows come first and denies after, so a deny wins over the allows in the same section.
    func statements(_ rules: [SBPLRule]) -> [String] {
        struct Key: Hashable {
            var action: SBPLRule.Action
            var operations: [String]
        }
        var keys: [Key] = []
        var filters: [Key: [String]] = [:]
        for rule in rules {
            let key = Key(action: rule.action, operations: rule.operations)
            if filters[key] == nil { keys.append(key) }
            var list = filters[key, default: []]
            if let filter = rule.filter.map(filterText), !list.contains(filter) { list.append(filter) }
            filters[key] = list
        }
        var out: [String] = []
        for action in [SBPLRule.Action.allow, .deny] {
            // Operation-wide rules (no filter) collapse into one line.
            let bare = keys.filter { $0.action == action && filters[$0]!.isEmpty }
            let ops = bare.flatMap(\.operations).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if !ops.isEmpty { out.append(statement(action.rawValue, ops.sorted(), [], report: false)) }
            for key in keys where key.action == action && !(bare.contains(key)) {
                out.append(statement(action.rawValue, key.operations, filters[key]!, report: false))
            }
        }
        return out
    }

    /// `(allow ops filter)` on one line, or one filter per line when there are several.
    func statement(_ action: String, _ operations: [String], _ filters: [String], report: Bool) -> String {
        let head = "(\(action) \(operations.joined(separator: " "))"
        let tail = report ? " (with report))" : ")"
        if filters.count <= 1 { return head + (filters.first.map { " \($0)" } ?? "") + tail }
        return head + filters.map { "\n    \($0)" }.joined() + tail
    }

    func filterText(_ filter: SBPLFilter) -> String {
        switch filter {
        case .subpath(let path): return "(subpath \(quote(environment.expand(path))))"
        case .literal(let path): return "(literal \(quote(environment.expand(path))))"
        case .homePattern(let raw): return "(require-all (subpath \(quote(environment.home))) (regex #\"\(raw)\"))"
        case .fileTypes(let raw): return "(regex #\"\\.(\(Self.caseInsensitive(raw)))$\")"
        }
    }

    func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Asks the kernel to load the profile (plus permission to exec /usr/bin/true) and run true.
    /// Returns nil on success, or sandbox-exec's error text.
    public static func validate(_ sbplText: String) -> String? {
        let probe = sbplText + "\n(allow process-exec* (literal \"/usr/bin/true\"))\n"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        task.arguments = ["-p", probe, "/usr/bin/true"]
        let err = Pipe()
        task.standardError = err
        task.standardOutput = FileHandle.nullDevice
        do { try task.run() } catch { return "can't run sandbox-exec: \(error)" }
        task.waitUntilExit()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return task.terminationStatus == 0 ? nil : (text.isEmpty ? "exit \(task.terminationStatus)" : text)
    }
}

extension SBPLCompiler {
    /// "mp4,mkv" → "mp4|MP4|mkv|MKV": readable in an audit. SBPL regexes have no
    /// case-insensitive flag (`(?i)` silently matches nothing), but on macOS's default
    /// case-insensitive volumes any mix of case matches anyway (tested). Extensions are validated
    /// to letters and digits when the rule is created.
    static func caseInsensitive(_ extensions: String) -> String {
        extensions.split(separator: ",").flatMap { ext -> [String] in
            let lower = ext.lowercased(), upper = ext.uppercased()
            return lower == upper ? [lower] : [lower, upper]
        }.joined(separator: "|")
    }
}
