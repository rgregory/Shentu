import Foundation

/// Lets a caller (the GUI, the launcher) stop a running target. Safe to call from any thread,
/// before or after the target starts.
public final class StopHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var action: (() -> Void)?

    public init() {}

    public func stop() {
        let run: (() -> Void)? = lock.withLock {
            requested = true
            return action
        }
        run?()
    }

    func attach(_ newAction: @escaping () -> Void) {
        let already: Bool = lock.withLock {
            action = newAction
            return requested
        }
        if already { newAction() }
    }

    func detach() {
        lock.withLock { action = nil }
    }
}

/// How to launch beyond the profile: resource wrappers and extra environment variables.
public struct LaunchOptions: Sendable {
    /// Commands that exec the next one, e.g. ["/usr/sbin/taskpolicy", "-c", "background"]. Every
    /// wrapper execs in place, so the pid Shentu tracks stays the app's pid.
    public var wrapper: [String] = []
    /// Commands run inside the sandbox, right before the app. Needed for settings that don't
    /// survive sandbox-exec (taskpolicy's memory limit).
    public var inner: [String] = []
    public var environment: [String: String] = [:]

    public init(wrapper: [String] = [], inner: [String] = [], environment: [String: String] = [:]) {
        self.wrapper = wrapper
        self.inner = inner
        self.environment = environment
    }
}

/// Launches the target under a Seatbelt profile. All launching goes through here so the
/// deprecated `sandbox-exec` can be swapped for another launcher later.
public enum Runner {
    public struct Outcome: Sendable {
        public var status: Int32
        public var wasSignaled: Bool
        public var stoppedByShentu: Bool
    }

    /// Runs `executable` under `profile`, inheriting stdio.
    /// - `forwardSignals`: Ctrl-C / SIGTERM to this process are forwarded to the target as
    ///   SIGTERM so Shentu can finish reading the log afterwards. Only the CLI wants this; it
    ///   changes process-wide signal handling, so the GUI and launcher pass false.
    /// - `stop`: stops the target on request (SIGTERM, then SIGKILL after 5 s).
    /// - `onLaunch` gets the pid (sandbox-exec execs into the target, so it is the target's pid).
    /// - `tick` runs every 100 ms while the target is alive.
    public static func run(
        profile: URL,
        executable: String,
        arguments: [String],
        duration: TimeInterval?,
        forwardSignals: Bool = true,
        stop: StopHandle? = nil,
        launch: LaunchOptions = LaunchOptions(),
        onLaunch: (pid_t) -> Void,
        tick: @escaping @Sendable () -> Void
    ) throws -> Outcome {
        let argv = command(profile: profile, executable: executable, arguments: arguments, launch: launch)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: argv[0])
        child.arguments = Array(argv.dropFirst())
        if !launch.environment.isEmpty {
            child.environment = ProcessInfo.processInfo.environment.merging(launch.environment) { $1 }
        }

        let stopped = StopFlag()
        let queue = DispatchQueue(label: "shentu.runner")
        var sources: [DispatchSourceSignal] = []
        if forwardSignals {
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            sources = [SIGINT, SIGTERM].map { sig in
                let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
                source.setEventHandler { terminate(child, stopped) }
                source.resume()
                return source
            }
        }
        defer {
            sources.forEach { $0.cancel() }
            if forwardSignals {
                signal(SIGINT, SIG_DFL)
                signal(SIGTERM, SIG_DFL)
            }
        }

        try child.run()
        stop?.attach { terminate(child, stopped) }
        defer { stop?.detach() }
        onLaunch(child.processIdentifier)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler(handler: tick)
        timer.resume()
        defer { timer.cancel() }

        if let duration {
            queue.asyncAfter(deadline: .now() + duration) { terminate(child, stopped) }
        }
        child.waitUntilExit()
        return Outcome(
            status: child.terminationStatus,
            wasSignaled: child.terminationReason == .uncaughtSignal,
            stoppedByShentu: stopped.value
        )
    }

    /// The full command line: outer wrappers, sandbox-exec, inner wrappers, then the app.
    static func command(profile: URL, executable: String, arguments: [String], launch: LaunchOptions) -> [String] {
        launch.wrapper + ["/usr/bin/sandbox-exec", "-f", profile.path] + launch.inner + [executable] + arguments
    }

    /// SIGTERM now, SIGKILL if the target is still alive 5 s later.
    private static func terminate(_ child: Process, _ flag: StopFlag) {
        guard child.isRunning else { return }
        flag.set()
        let pid = child.processIdentifier
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if child.isRunning { kill(pid, SIGKILL) }
        }
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var value: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}
