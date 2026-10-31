import Foundation

public struct EnforceOptions: Sendable {
    /// The app or binary to run.
    public var target: String
    public var arguments: [String] = []
    public var duration: TimeInterval?
    public var control = SessionControl(forwardSignals: true)
    /// Every logged record, as it arrives (for live UIs). Called on a background queue.
    public var onRecord: (@Sendable (EnforceRecord) -> Void)?
    /// The target's pid, once it has been started (the log is live by then).
    public var onLaunch: (@Sendable (pid_t) -> Void)?

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

public enum Enforce {
    /// The Restricted Sandbox, no learning needed: any app runs with only the access you chose
    /// (see `RestrictedSandbox`), and everything it was blocked from is logged.
    public static func runRestricted(
        _ options: EnforceOptions,
        sandbox: RestrictedSandbox,
        environment: ShentuEnvironment = .current(),
        say: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> EnforceSummary {
        let target = try ResolvedTarget.resolve(options.target)
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
        // Each run gets its own profile and log, named by time plus a random part: two runs of
        // the same app (even in the same second) never share or overwrite either file.
        let runDir = environment.logsDir(target.identity.key)
        let runName = "\(fileStamp())-\(UUID().uuidString.prefix(8))"
        try fm.ensureDirectory(runDir)
        let profileURL = runDir.appendingPathComponent("\(runName).sb")
        try Data(text.utf8).write(to: profileURL, options: .withoutOverwriting)
        say("running \(target.identity.name) in the Restricted Sandbox: \(sandbox.summary).")
        if let scratch { say("temp folder for this run (deleted when it quits): \(scratch)") }
        var summary = try logged(profileURL: profileURL, logURL: runDir.appendingPathComponent("\(runName).jsonl"), target: target, options: options, control: control,
                                 ownFolders: sandbox.readWrite.map(environment.expand),
                                 environment: environment, say: say)
        summary.tempFolder = scratch
        return summary
    }

    /// Runs the target under a profile and writes every denial (and reported allow) to a new log.
    static func logged(
        profileURL: URL, logURL: URL, target: ResolvedTarget, options: EnforceOptions, control: SessionControl,
        ownFolders: [String], environment: ShentuEnvironment,
        say: @escaping @Sendable (String) -> Void
    ) throws -> EnforceSummary {
        let runId = UUID().uuidString
        let log = try NDJSONWriter(logURL)
        defer { log.close() }
        let tally = Tally()
        let onRecord = options.onRecord

        say("log: \(logURL.path)")
        let result = try Session.run(
            profile: profileURL, target: target, arguments: options.arguments,
            duration: options.duration, environment: environment, control: control,
            onLaunch: options.onLaunch,
            onEvent: { event in
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
