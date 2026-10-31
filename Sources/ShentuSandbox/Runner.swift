import Darwin
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

    /// Runs `executable` under `profile`, inheriting stdio, in a new process group led by the
    /// target. Everything the target starts is stopped with it: on a stop request, at the time
    /// limit, and when the target itself quits (helpers don't outlive the run, whose temp folder
    /// is deleted).
    /// - `forwardSignals`: Ctrl-C / SIGTERM to this process are forwarded to the target as
    ///   SIGTERM so Shentu can finish reading the log afterwards. It changes process-wide signal
    ///   handling, so the GUI passes false.
    /// - `stop`: stops the target and its helpers on request (SIGTERM, then SIGKILL after 5 s).
    /// - `onLaunch` gets the pid (sandbox-exec execs into the target, so it is the target's pid).
    /// - `members`: pids seen in the target's process tree. Helpers that left the process group
    ///   (setpgid/setsid) are found here, as long as their parent is still in the run.
    /// - `tick` runs every 100 ms while the target is alive.
    public static func run(
        profile: URL,
        executable: String,
        arguments: [String],
        duration: TimeInterval?,
        forwardSignals: Bool = true,
        stop: StopHandle? = nil,
        launch: LaunchOptions = LaunchOptions(),
        members: @escaping @Sendable () -> Set<pid_t> = { [] },
        onLaunch: (pid_t) -> Void,
        tick: @escaping @Sendable () -> Void
    ) throws -> Outcome {
        let argv = command(profile: profile, executable: executable, arguments: arguments, launch: launch)
        let environment = launch.environment.isEmpty
            ? ProcessInfo.processInfo.environment
            : ProcessInfo.processInfo.environment.merging(launch.environment) { $1 }

        let stopped = StopFlag()
        let queue = DispatchQueue(label: "shentu.runner")
        let started = Child(pid: try spawn(argv, environment: environment), members: members)
        var sources: [DispatchSourceSignal] = []
        if forwardSignals {
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            sources = [SIGINT, SIGTERM].map { sig in
                let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
                source.setEventHandler { terminate(started, stopped) }
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

        stop?.attach { terminate(started, stopped) }
        defer { stop?.detach() }
        onLaunch(started.pid)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler(handler: tick)
        timer.resume()
        defer { timer.cancel() }

        if let duration {
            queue.asyncAfter(deadline: .now() + duration) { terminate(started, stopped) }
        }
        let status = started.wait()
        // The target is gone: end whatever it left behind, SIGKILL after 2 s for the stubborn.
        started.signalAll(SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while started.hasLeftovers && Date() < deadline { usleep(50_000) }
        if started.hasLeftovers { started.signalAll(SIGKILL) }

        // Same encoding as Foundation's Process: the exit code, or the signal number.
        let signaled = status & 0x7f != 0
        return Outcome(
            status: signaled ? status & 0x7f : (status >> 8) & 0xff,
            wasSignaled: signaled,
            stoppedByShentu: stopped.value
        )
    }

    /// The full command line: outer wrappers, sandbox-exec, inner wrappers, then the app.
    static func command(profile: URL, executable: String, arguments: [String], launch: LaunchOptions) -> [String] {
        launch.wrapper + ["/usr/bin/sandbox-exec", "-f", profile.path] + launch.inner + [executable] + arguments
    }

    /// posix_spawn into a new process group (so the whole group can be signaled), with default
    /// signal handling and an empty signal mask, and only stdin/stdout/stderr inherited: none of
    /// Shentu's other file descriptors leak into the sandbox.
    static func spawn(_ argv: [String], environment: [String: String]) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
                                              | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = ~sigset_t(0)
        var none = sigset_t(0)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addinherit_np(&actions, fd) }

        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
        guard rc == 0 else {
            throw ShentuError.failed("can't start \(argv[0]): \(String(cString: strerror(rc)))")
        }
        return pid
    }

    /// SIGTERM to the target and its helpers now, SIGKILL to whatever is left 5 s later.
    private static func terminate(_ child: Child, _ flag: StopFlag) {
        guard child.isRunning else { return }
        flag.set()
        child.signalAll(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if child.isRunning || child.hasLeftovers { child.signalAll(SIGKILL) }
        }
    }
}

/// The launched target: the leader of its own process group.
private final class Child: @unchecked Sendable {
    let pid: pid_t
    /// Processes started before the target can't be its helpers (guards against pid reuse).
    private let startedAt = time(nil)
    private let members: @Sendable () -> Set<pid_t>
    private let lock = NSLock()
    private var exited = false

    init(pid: pid_t, members: @escaping @Sendable () -> Set<pid_t>) {
        self.pid = pid
        self.members = members
    }

    var isRunning: Bool { lock.withLock { !exited } }

    /// Blocks until the target exits; returns its raw wait status.
    func wait() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        lock.withLock { exited = true }
        return status
    }

    /// True while anything from the run is still alive.
    var hasLeftovers: Bool { kill(-pid, 0) == 0 || !strays().isEmpty }

    /// Signals the process group, plus helpers that left it but still have a parent in the run.
    func signalAll(_ sig: Int32) {
        kill(-pid, sig)
        for stray in strays() { kill(stray, sig) }
    }

    /// Tracked pids outside the group that still belong to this run: started after the target,
    /// with a parent that is the target or another tracked process.
    private func strays() -> [pid_t] {
        let tracked = members()
        return tracked.filter { candidate in
            guard candidate != pid else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(candidate, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
            guard time_t(info.pbi_start_tvsec) >= startedAt, pid_t(info.pbi_pgid) != pid else { return false }
            let parent = pid_t(info.pbi_ppid)
            return parent == pid || tracked.contains(parent)
        }
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var value: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}
