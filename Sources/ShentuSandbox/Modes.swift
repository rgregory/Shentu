import Foundation

public struct LearnOptions: Sendable {
    public var target: String
    public var arguments: [String] = []
    public var duration: TimeInterval?
    public var merge = false
    public var configPath: URL?
    public var control = SessionControl(forwardSignals: true)
    /// Every captured report, as it arrives (for live UIs). Called on a background queue.
    public var onEvent: (@Sendable (SandboxEvent) -> Void)?

    public init(target: String) { self.target = target }
}

public struct LearnSummary: Sendable {
    public var configURL: URL
    public var captureURL: URL
    public var backupURL: URL?
    public var config: ShentuConfig
    public var eventsThisRun: Int
    public var processes: Set<String>
    public var outcome: Runner.Outcome
}

public struct EnforceOptions: Sendable {
    /// An app, binary, or config JSON.
    public var target: String
    public var arguments: [String] = []
    public var configPath: URL?
    public var allowChanged = false
    public var duration: TimeInterval?
    public var control = SessionControl(forwardSignals: true)
    /// Every logged record, as it arrives (for live UIs). Called on a background queue.
    public var onRecord: (@Sendable (EnforceRecord) -> Void)?

    public init(target: String) { self.target = target }
}

public struct EnforceSummary: Sendable {
    public var logURL: URL
    public var profileURL: URL
    public var denials: Int
    public var uniqueDenials: Int
    public var reportedAllows: [String: Int]
    public var outcome: Runner.Outcome
    public var drained: Bool
    public var streamNotices: Int
    /// The run's own temp folder (ephemeral temp), already deleted when this is returned.
    public var tempFolder: String? = nil
}

public enum Learn {
    public static func run(
        _ options: LearnOptions,
        environment: ShentuEnvironment = .current(),
        say: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> LearnSummary {
        let target = try ResolvedTarget.resolve(Swap.resolveOriginal(options.target))
        try target.preflight()
        let key = target.identity.key
        let fm = FileManager.default
        let learnDir = environment.learnDir(key)
        try fm.ensureDirectory(learnDir)
        let configURL = options.configPath ?? environment.configURL(key)

        let profile = learnDir.appendingPathComponent("learn.sb")
        try SBPLCompiler.learnProfile.write(to: profile, atomically: true, encoding: .utf8)
        let onEvent = options.onEvent
        let captureURL = learnDir.appendingPathComponent("\(fileStamp()).ndjson")
        let capture = try NDJSONWriter(captureURL)
        defer { capture.close() }

        say("learning \(target.identity.name) (\(target.identity.executable)). Use the app normally, then quit it\(options.duration.map { " or wait \(Int($0))s" } ?? "").")
        let result = try Session.run(
            profile: profile, target: target, arguments: options.arguments,
            duration: options.duration, environment: environment, control: options.control,
            onEvent: { event in
                capture.write(event)
                onEvent?(event)
            }
        )
        capture.close()

        var warnings: [String] = []
        if result.events.isEmpty {
            warnings.append("No reports were captured from the app. The config would be empty; check that the app actually ran.")
        }
        if !result.drained {
            warnings.append("The log stream never confirmed it had caught up after the app exited; the last reports may be missing.")
        }
        if result.streamNotices > 0 {
            warnings.append("log stream reported \(result.streamNotices) non-log notice(s), possibly dropped messages. Consider another learn run with --merge.")
        }
        warnings.append("Child processes that exit within milliseconds may be under-reported by the kernel. Exercise features more than once, or re-run with --merge.")

        let previous = fm.fileExists(atPath: configURL.path) ? try? ShentuConfig.load(configURL) : nil
        var captures = [captureURL.path]
        var runs = 1
        if options.merge, let previous {
            captures = previous.learning.captures + captures
            runs = previous.learning.runs + 1
        }
        let normalPath = Swap.records(environment).first { $0.hiddenPath == target.identity.path }?.appPath
            ?? target.identity.path
        let config = regenerate(target: target, normalPath: normalPath, captures: captures, runs: runs,
                                warnings: warnings, previous: previous, keepEdits: options.merge,
                                environment: environment)
        let backupURL = try config.save(to: configURL)
        return LearnSummary(configURL: configURL, captureURL: captureURL, backupURL: backupURL, config: config,
                            eventsThisRun: result.events.count, processes: result.processes,
                            outcome: result.outcome)
    }

    /// Regenerates a config from the learn captures it lists, without running the app, so that
    /// improvements in how reports become rules reach configs learned earlier. Keeps your rules,
    /// profiles, limits, switches and switched-off rules, like a merge.
    public static func rebuild(
        configURL: URL, environment: ShentuEnvironment = .current()
    ) throws -> (config: ShentuConfig, backupURL: URL?) {
        let previous = try ShentuConfig.load(configURL)
        let captures = previous.learning.captures
        let missing = captures.filter { !FileManager.default.fileExists(atPath: $0) }
        guard !captures.isEmpty, missing.isEmpty else {
            // A partial rebuild would silently drop rules the app needs.
            throw ShentuError.refused(captures.isEmpty
                ? "the config lists no learn captures; run `shentu learn` instead"
                : "learn capture(s) missing: \(missing.joined(separator: ", ")); run `shentu learn` instead")
        }
        let t = previous.target
        let target = ResolvedTarget(identity: t, bundlePath: t.path == t.executable ? nil : t.path,
                                    isAppleSigned: false, hasAppSandbox: false)
        var config = regenerate(target: target, normalPath: t.path, captures: captures, runs: previous.learning.runs,
                                warnings: previous.learning.warnings, previous: previous, keepEdits: true,
                                environment: environment)
        config.learning.warnings = config.learning.warnings.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        return (config, try config.save(to: configURL))
    }

    /// Captures → config. Keeps your rules, profiles and limits from `previous`, and with
    /// `keepEdits` also its switches and rule actions.
    static func regenerate(
        target: ResolvedTarget, normalPath: String, captures: [String], runs: Int, warnings: [String],
        previous: ShentuConfig?, keepEdits: Bool, environment: ShentuEnvironment
    ) -> ShentuConfig {
        // Configs always describe the app at its normal location. Captures recorded while it was
        // replaced (running from `.Name.shentu.app`) are mapped back, so merging captures from
        // before and after a Replace/Restore gives the same rules.
        let hidden = Swap.hiddenPath(for: normalPath)
        var events: [SandboxEvent] = []
        for path in captures {
            events += (try? readCapture(URL(fileURLWithPath: path))) ?? []
        }
        events = events.map { event in
            var event = event
            event.target = event.target.replacingOccurrences(of: hidden, with: normalPath)
            return event
        }

        var config = build(target: target.moved(to: normalPath), events: events, environment: environment,
                           runs: runs, captures: captures, warnings: warnings)
        // Your rules are your intent, not observations: keep them whether or not this is a merge.
        if let previous {
            let ids = Set(config.rules.map(\.id))
            config.rules += previous.rules.filter { $0.source == .custom && !ids.contains($0.id) }
            config.profiles = previous.profiles
            config.limits = previous.limits
        }
        if let previous, keepEdits {
            config.keepEdits(from: previous)
        }
        return config
    }

    /// Pure: events → config. Used by `learn` and by tests.
    public static func build(
        target: ResolvedTarget, events: [SandboxEvent], environment: ShentuEnvironment,
        runs: Int = 1, captures: [String] = [], warnings: [String] = []
    ) -> ShentuConfig {
        let generalizer = Generalizer(environment: environment, target: target.identity, bundlePath: target.bundlePath)
        let output = generalizer.generalize(events)
        let hardening = Hardening(environment: environment, ownAnchors: output.anchors.map(environment.expand))
        return ShentuConfig(
            schemaVersion: 1,
            generatedBy: "shentu \(shentuVersion)",
            generatedAt: Date(),
            target: target.identity,
            anchors: output.anchors,
            learning: LearningInfo(runs: runs, events: events.reduce(0) { $0 + $1.count },
                                   captures: captures, warnings: warnings + output.warnings),
            logging: LoggingSettings(),
            rules: output.rules,
            hardening: hardening.rules(hits: output.hits)
        )
    }
}

public enum Enforce {
    /// Finds the config: an explicit path, a .json target, or the default for the target's key.
    public static func locateConfig(_ options: EnforceOptions, environment: ShentuEnvironment) throws -> (URL, ShentuConfig) {
        let url: URL
        if let explicit = options.configPath {
            url = explicit
        } else if options.target.hasSuffix(".json") {
            url = URL(fileURLWithPath: options.target)
        } else {
            url = environment.configURL(try ResolvedTarget.resolve(Swap.resolveOriginal(options.target)).identity.key)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ShentuError.usage("no config at \(url.path). Run `shentu learn \(options.target)` first.")
        }
        return (url, try ShentuConfig.load(url))
    }

    public static func run(
        _ options: EnforceOptions,
        environment: ShentuEnvironment = .current(),
        say: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> EnforceSummary {
        let (configURL, stored) = try locateConfig(options, environment: environment)
        let targetPath = Swap.resolveOriginal(options.target.hasSuffix(".json") ? stored.target.path : options.target)
        let target = try ResolvedTarget.resolve(targetPath)
        try target.preflight()
        try checkIdentity(expected: stored.target, actual: target.identity, allowChanged: options.allowChanged, say: say)
        // A replaced app runs from its hidden location; its own-bundle rules must follow it.
        let config = stored.rebased(to: target.identity.path)

        let text = SBPLCompiler(environment: environment).compile(config, source: configURL.path)
        if let error = SBPLCompiler.validate(text) {
            throw ShentuError.failed("the compiled profile doesn't load:\n\(error)")
        }
        let profileURL = configURL.deletingPathExtension().appendingPathExtension("sb")
        try text.write(to: profileURL, atomically: true, encoding: .utf8)

        var control = options.control
        control.launch = try launchOptions(config, environment: environment)
        say("enforcing \(configURL.path) on \(target.identity.name).")
        return try logged(profileURL: profileURL, target: target, options: options, control: control,
                          logging: config.logging, ownFolders: config.anchors.map(environment.expand),
                          environment: environment, say: say)
    }

    /// The Restricted Sandbox, no learning needed: any app runs with only the access you chose
    /// (see `RestrictedSandbox`), and everything it was blocked from is logged.
    public static func runRestricted(
        _ options: EnforceOptions,
        sandbox: RestrictedSandbox,
        environment: ShentuEnvironment = .current(),
        say: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> EnforceSummary {
        let target = try ResolvedTarget.resolve(Swap.resolveOriginal(options.target))
        try target.preflight()
        let fm = FileManager.default
        var control = options.control
        var scratch: String?
        if sandbox.ephemeralTemp {
            let base = environment.userTempDir ?? "/private/tmp"
            let dir = realPath(base) + "/shentu-run-\(target.identity.key)-\(UUID().uuidString.prefix(8))"
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            scratch = dir
            control.launch.environment["TMPDIR"] = dir + "/"
        }
        defer { if let scratch { try? fm.removeItem(atPath: scratch) } }

        let text = SBPLCompiler(environment: environment).restrictedProfile(target, sandbox, scratch: scratch)
        if let error = SBPLCompiler.validate(text) {
            throw ShentuError.failed("the Restricted Sandbox profile doesn't load:\n\(error)")
        }
        try fm.ensureDirectory(environment.profilesDir)
        let profileURL = environment.profilesDir.appendingPathComponent("\(target.identity.key).restricted.sb")
        try text.write(to: profileURL, atomically: true, encoding: .utf8)
        say("running \(target.identity.name) in the Restricted Sandbox: \(sandbox.summary).")
        if let scratch { say("temp folder for this run (deleted when it quits): \(scratch)") }
        var summary = try logged(profileURL: profileURL, target: target, options: options, control: control,
                                 logging: LoggingSettings(), ownFolders: sandbox.readWrite.map(environment.expand),
                                 environment: environment, say: say)
        summary.tempFolder = scratch
        return summary
    }

    /// Runs the target under a profile and writes every denial (and reported allow) to a new log.
    static func logged(
        profileURL: URL, target: ResolvedTarget, options: EnforceOptions, control: SessionControl,
        logging: LoggingSettings, ownFolders: [String], environment: ShentuEnvironment,
        say: @escaping @Sendable (String) -> Void
    ) throws -> EnforceSummary {
        let runId = UUID().uuidString
        let logURL = environment.logsDir(target.identity.key).appendingPathComponent("\(fileStamp()).jsonl")
        let log = try NDJSONWriter(logURL)
        defer { log.close() }
        let tally = Tally()
        let onRecord = options.onRecord

        say("log: \(logURL.path)")
        let result = try Session.run(
            profile: profileURL, target: target, arguments: options.arguments,
            duration: options.duration, environment: environment, control: control,
            onEvent: { event in
                if event.verdict == .deny && !logging.denials { return }
                let record = EnforceRecord(
                    ts: Date(), runId: runId, pid: event.pid, process: event.process,
                    verdict: event.verdict, operation: event.operation,
                    target: environment.abbreviate(event.target),
                    category: EnforceRecord.category(for: event, ownFolders: ownFolders), count: event.count)
                log.write(record)
                onRecord?(record)
                if tally.add(record) {
                    say("DENY \(record.operation) \(record.target)  [\(record.process) \(record.pid)]")
                }
            }
        )
        return EnforceSummary(
            logURL: logURL, profileURL: profileURL, denials: tally.denials, uniqueDenials: tally.unique,
            reportedAllows: tally.allows, outcome: result.outcome, drained: result.drained,
            streamNotices: result.streamNotices
        )
    }

    /// Background priority and hard limits wrap the launch; Temp-only exports a private TMPDIR.
    static func launchOptions(_ config: ShentuConfig, environment: ShentuEnvironment) throws -> LaunchOptions {
        let profiles = Set(config.profiles ?? [])
        var launch = LaunchOptions()
        if let seconds = config.limits?.cpuSeconds, seconds > 0 {
            launch.wrapper += ["/bin/sh", "-c", "ulimit -t \(seconds); exec \"$@\"", "sh"]
        }
        if profiles.contains(.background) {
            launch.wrapper += ["/usr/sbin/taskpolicy", "-c", "background", "-d", "throttle"]
        }
        // The memory limit doesn't survive sandbox-exec (tested), so it's applied inside, right before the app.
        if let mb = config.limits?.memoryMB, mb > 0 {
            launch.inner = ["/usr/sbin/taskpolicy", "-m", String(mb)]
        }
        if profiles.contains(.tempOnly) {
            let dir = environment.privateTemp(config.target.key)
            try FileManager.default.ensureDirectory(dir)
            launch.environment["TMPDIR"] = dir.path + "/"
        }
        return launch
    }

    static func checkIdentity(expected: TargetIdentity, actual: TargetIdentity, allowChanged: Bool,
                              say: (String) -> Void) throws {
        var changes: [String] = []
        if expected.teamId != actual.teamId { changes.append("team ID \(expected.teamId ?? "none") → \(actual.teamId ?? "none")") }
        if expected.signingId != actual.signingId { changes.append("signing ID \(expected.signingId ?? "none") → \(actual.signingId ?? "none")") }
        if expected.cdhash != actual.cdhash { changes.append("code hash changed (updated or rebuilt)") }
        guard !changes.isEmpty else { return }
        let message = "\(actual.name) isn't the binary this config was learned from: " + changes.joined(separator: "; ")
        if allowChanged {
            say("warning: \(message). Continuing because of --allow-changed.")
        } else {
            throw ShentuError.refused("\(message). Re-run `shentu learn` (add --merge to keep your edits), or pass --allow-changed.")
        }
    }
}

/// Counts enforce events and decides which denials are new enough to print.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<String> = []
    private(set) var denials = 0
    private(set) var allows: [String: Int] = [:]
    var unique: Int { lock.withLock { seen.count } }

    /// Returns true for the first occurrence of each distinct denial.
    func add(_ record: EnforceRecord) -> Bool {
        lock.withLock {
            if record.verdict == .allow {
                allows[record.category, default: 0] += record.count
                return false
            }
            denials += record.count
            return seen.insert("\(record.operation) \(record.target)").inserted
        }
    }
}
