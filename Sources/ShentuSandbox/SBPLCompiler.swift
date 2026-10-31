import Foundation

/// Config → SBPL. Order matters: SBPL lets later matching rules override earlier ones, so the
/// layout is base → always-on → learned → your rules → hardening → final denies (ADR-003).
public struct SBPLCompiler {
    public static let learnProfile = """
        (version 1)
        ;; Shentu learn mode: allow everything, report every operation to the kernel log.
        (allow default (with report))

        """

    let environment: ShentuEnvironment

    public init(environment: ShentuEnvironment) {
        self.environment = environment
    }

    /// Compact SBPL: rules with the same action, operations and logging are merged into one
    /// statement, and learned rules already covered by an always-on rule are left out. The JSON
    /// config keeps every rule with its ID and counts; this file is only what the kernel needs.
    public func compile(_ stored: ShentuConfig, source: String? = nil) -> String {
        let config = withCurrentProtections(stored)
        let t = config.target
        var out = [
            ";; Shentu profile for \(t.name)\(t.bundleId.map { " (\($0))" } ?? "")\(source.map { ", from \($0)" } ?? ""). Edit the JSON, not this file.",
            "(version 1)",
            "(deny default)",
            "(import \"system.sb\")",
            "",
            ";; --- always on",
            "(allow file-read-metadata)",
        ]
        let own = t.path == t.executable ? "(literal \(quote(t.executable)))" : "(subpath \(quote(t.path)))"
        out.append("(allow file-read* file-map-executable \(own))")
        out.append("(allow process-exec* \(own)\(config.logging.exec ? " (with report)" : ""))")
        out.append("(allow signal (target same-sandbox))")
        if config.limits?.memoryMB != nil {
            // The memory limit is applied by taskpolicy inside the sandbox, right before the app.
            out.append("(allow file-read* file-map-executable process-exec* (literal \"/usr/sbin/taskpolicy\"))")
        }
        // launchd and cfprefsd check these in user space, so learning can't see them (ADR-004):
        // the app's own preferences, plus Apple system services and preferences.
        if let domain = t.bundleId {
            out.append("(allow user-preference-read user-preference-write (preference-domain \(quote(domain))))")
        }
        out.append("(allow mach-lookup (global-name-prefix \"com.apple.\")\(config.logging.activity ? " (with report)" : ""))")
        out.append(statement("allow", ["user-preference-read"], ["(preference-domain-prefix \"com.apple.\")",
                   "(preference-domain \"kCFPreferencesAnyApplication\")", "(preference-domain \"pbs\")"], report: false))

        let learned = config.rules.filter { $0.source != .custom && !coveredByAlwaysOn($0, config) }
        let yours = config.rules.filter { $0.source == .custom }
        for (title, rules) in [(";; --- learned", learned),
                               (";; --- your rules (before hardening, so protected locations stay blocked)", yours)] where !rules.isEmpty {
            out.append("")
            out.append(title)
            out += statements(rules, logging: config.logging, config: config)
        }
        out += profileSection(config, own: own)
        out.append("")
        out.append(";; --- hardening (last, so it wins)")
        out += statements(config.hardening, logging: config.logging, config: config)
        out.append("(deny file-link)")
        out.append("")
        return out.joined(separator: "\n")
    }

    /// Profiles restrict what was learned, so they come after learned and your rules. Order
    /// inside matters here: a blanket deny, then the narrow allow that survives it. The blanket
    /// denies carry `(subpath "/")`: a deny with no filter only sets the operation's default and
    /// loses to any filtered allow, whatever the order (tested).
    func profileSection(_ config: ShentuConfig, own: String) -> [String] {
        let profiles = Set(config.profiles ?? [])
        guard !profiles.subtracting([.background]).isEmpty else { return [] }
        let names = Profile.allCases.filter { profiles.contains($0) && $0 != .background }.map(\.rawValue)
        var out = ["", ";; --- profiles: \(names.joined(separator: ", "))"]
        if profiles.contains(.offline) {
            out.append("(deny network-outbound (remote ip))")
            out.append("(deny network-bind network-inbound (local ip))")
        }
        if profiles.contains(.tempOnly) {
            out.append("(deny file-write* (subpath \"/\"))")
            // Shared temp plus the app's own Darwin cache folders, never every app's caches.
            var places = [environment.privateTemp(config.target.key).path]
            if let temp = environment.userTempDir { places.append(temp) }
            places += config.anchors.map(environment.expand)
                .filter { anchor in environment.userAppAreas.contains { anchor.hasPrefix($0 + "/") } }
            out.append(statement("allow", ["file-write*"], places.map { "(subpath \(quote($0)))" } + ["(subpath \"/dev\")"], report: false))
        }
        if profiles.contains(.noLaunch) {
            out.append("(deny process-exec* (subpath \"/\"))")
            let taskpolicy = config.limits?.memoryMB != nil ? " (literal \"/usr/sbin/taskpolicy\")" : ""
            out.append("(allow process-exec* \(own)\(taskpolicy)\(config.logging.exec ? " (with report)" : ""))")
            // Apps, documents and links opened through LaunchServices run outside the sandbox.
            // lsopen is checked with no path, so no filter matches it and this deny has none;
            // it wins because learned lsopen allows have no filter either (finding 30).
            out.append("(deny lsopen)")
        }
        return out
    }

    /// Every profile gets every current protection: ones added to Shentu after a config was
    /// learned are appended (as deny), so nobody has to re-learn to pick them up.
    func withCurrentProtections(_ config: ShentuConfig) -> ShentuConfig {
        let have = Set(config.hardening.map(\.id))
        let current = Hardening(environment: environment, ownAnchors: config.anchors.map(environment.expand)).rules(hits: [:])
        let missing = current.filter { !have.contains($0.id) }
        guard !missing.isEmpty else { return config }
        var copy = config
        copy.hardening += missing
        return copy
    }

    /// Merges rules into as few statements as possible without changing what they permit.
    /// Within a section, allows come first and denies after, so a rule you switched off wins
    /// over the section's allows.
    func statements(_ rules: [Rule], logging: LoggingSettings, config: ShentuConfig? = nil) -> [String] {
        struct Key: Hashable {
            var action: RuleAction
            var operations: [String]
            var report: Bool
        }
        var keys: [Key] = []
        var filters: [Key: [String]] = [:]
        for rule in rules {
            let report = rule.action == .allow && (rule.category.map(logging.reports) == true
                || (logging.activity && config.map { watched(rule, $0) } == true))
            let key = Key(action: rule.action, operations: rule.operations, report: report)
            if filters[key] == nil { keys.append(key) }
            var list = filters[key, default: []]
            if let filter = filterText(rule.filter) {
                if !list.contains(filter) { list.append(filter) }
            }
            filters[key] = list
        }
        var out: [String] = []
        for action in [RuleAction.allow, .deny] {
            // Operation-wide rules (no filter, not reported) collapse into one line.
            let bare = keys.filter { $0.action == action && !$0.report && filters[$0]!.isEmpty }
            let ops = bare.flatMap(\.operations).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if !ops.isEmpty { out.append(statement(action.rawValue, ops.sorted(), [], report: false)) }
            for key in keys where key.action == action && !(bare.contains(key)) {
                out.append(statement(action.rawValue, key.operations, filters[key]!, report: key.report))
            }
        }
        return out
    }

    /// Activity worth showing on the live dashboard that no specific switch covers: file access
    /// outside system files and the app itself, local sockets, services and devices. System-file reads would be thousands of
    /// uninteresting lines, so they stay quiet.
    func watched(_ rule: Rule, _ config: ShentuConfig) -> Bool {
        // Network, launches and outside writes have their own logging switches; activity covers the rest.
        if rule.category != nil { return false }
        let ops = Set(rule.operations)
        let interesting = ops.contains { op in
            op.hasPrefix("file-read") || op.hasPrefix("file-write") || op == "file-map-executable"
                || op.hasPrefix("network") || op == "process-exec*" || op == "mach-lookup" || op.hasPrefix("iokit")
        }
        guard interesting else { return false }
        guard let value = rule.filter.value, rule.filter.kind == .subpath || rule.filter.kind == .literal else { return true }
        let path = environment.expand(value)
        if path == "/" || path.hasPrefix("/dev/") || path.isWithin(config.target.path) { return false }
        let systemRead = Generalizer.systemReadRoots.contains { path.isWithin($0) } && !ops.contains("file-write*")
        return !systemRead
    }

    /// `(allow ops filter)` on one line, or one filter per line when there are several.
    func statement(_ action: String, _ operations: [String], _ filters: [String], report: Bool) -> String {
        let head = "(\(action) \(operations.joined(separator: " "))"
        let tail = report ? " (with report))" : ")"
        if filters.count <= 1 { return head + (filters.first.map { " \($0)" } ?? "") + tail }
        return head + filters.map { "\n    \($0)" }.joined() + tail
    }

    /// Learned allows that an always-on rule or system.sb already grants (Apple services and
    /// preferences, per-pid registrations, the app's own preferences and bundle), so they add
    /// nothing to the profile.
    func coveredByAlwaysOn(_ rule: Rule, _ config: ShentuConfig) -> Bool {
        guard rule.action == .allow, let value = rule.filter.value else { return false }
        let ops = Set(rule.operations)
        switch rule.filter.kind {
        case .globalName:
            return ops == ["mach-lookup"] && value.hasPrefix("com.apple.")
        case .localName:
            return ops == ["mach-register"]  // system.sb allows every per-pid registration
        case .preferenceDomain:
            return ops == ["user-preference-read"]
                && (value.hasPrefix("com.apple.") || ["kCFPreferencesAnyApplication", "pbs", config.target.bundleId].contains(value))
        case .subpath, .literal:
            let path = environment.expand(value)
            let own = config.target.path
            let inside = path == own || path.hasPrefix(own + "/")
            let reportsMatch = !ops.contains("process-exec*") || (rule.category == .exec) == config.logging.exec
            return inside && reportsMatch && ops.isSubset(of: ["file-read*", "file-map-executable", "process-exec*"])
        default:
            return false
        }
    }

    func filterText(_ filter: Filter) -> String? {
        guard let raw = filter.value else { return nil }
        let value = environment.expand(raw)
        switch filter.kind {
        case .any: return nil
        case .subpath: return "(subpath \(quote(value)))"
        case .literal: return "(literal \(quote(value)))"
        case .globalName: return "(global-name \(quote(value)))"
        case .xpcServiceName: return "(xpc-service-name \(quote(value)))"
        case .localName: return "(local-name \(quote(value)))"
        case .remote: return "(remote ip \(quote(value)))"
        case .local: return "(local ip \(quote(value)))"
        case .preferenceDomain: return "(preference-domain \(quote(value)))"
        case .iokitUserClientClass: return "(iokit-user-client-class \(quote(value)))"
        case .ipcPosixName: return "(ipc-posix-name \(quote(value)))"
        case .sysctlName: return "(sysctl-name \(quote(value)))"
        case .homePattern: return "(require-all (subpath \(quote(environment.home))) (regex #\"\(raw)\"))"
        case .fileTypes: return "(regex #\"\\.(\(Self.caseInsensitive(raw)))$\")"
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
