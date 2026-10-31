import Foundation

/// How a session is controlled from outside. The CLI forwards Ctrl-C; the GUI and the launcher
/// stop through a `StopHandle` instead.
public struct SessionControl: Sendable {
    public var forwardSignals: Bool
    public var stop: StopHandle?
    public var launch = LaunchOptions()

    public init(forwardSignals: Bool = false, stop: StopHandle? = nil) {
        self.forwardSignals = forwardSignals
        self.stop = stop
    }
}

/// One observed run: log tap up and proven live → target launched under a profile → target
/// exits → stream drained. Only reports from the target's process tree are kept.
public enum Session {
    public struct Result: Sendable {
        public var events: [SandboxEvent]
        public var outcome: Runner.Outcome
        public var streamNotices: Int
        /// False if the closing canary never arrived (late reports may be missing).
        public var drained: Bool
        public var processes: Set<String>
    }

    public static func run(
        profile: URL,
        target: ResolvedTarget,
        arguments: [String],
        duration: TimeInterval?,
        environment: ShentuEnvironment,
        control: SessionControl = SessionControl(),
        onEvent: @escaping @Sendable (SandboxEvent) -> Void = { _ in }
    ) throws -> Result {
        let collector = Collector(onEvent: onEvent)
        let tap = LogTap(canaryDir: environment.canaryDir) { collector.receive($0) }
        try tap.start()
        defer { tap.stop() }
        try tap.waitUntilLive()

        let outcome = try Runner.run(
            profile: profile,
            executable: target.identity.executable,
            arguments: arguments,
            duration: duration,
            forwardSignals: control.forwardSignals,
            stop: control.stop,
            launch: control.launch,
            members: { collector.trackedPIDs },
            onLaunch: { collector.attach(ProcessTree(root: $0)) },
            tick: { collector.refresh() }
        )
        let drained = tap.drain()
        return Result(
            events: collector.accepted,
            outcome: outcome,
            streamNotices: tap.streamNotices,
            drained: drained,
            processes: Set(collector.accepted.map(\.process))
        )
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var tree: ProcessTree?
    private var pending: [SandboxEvent] = []
    private var events: [SandboxEvent] = []
    private let onEvent: @Sendable (SandboxEvent) -> Void

    init(onEvent: @escaping @Sendable (SandboxEvent) -> Void) {
        self.onEvent = onEvent
    }

    var accepted: [SandboxEvent] { lock.withLock { events } }

    var trackedPIDs: Set<pid_t> { lock.withLock { tree }?.trackedPIDs ?? [] }

    func attach(_ tree: ProcessTree) {
        let early = lock.withLock {
            self.tree = tree
            defer { pending.removeAll() }
            return pending
        }
        early.forEach(receive)
    }

    func refresh() {
        lock.withLock { tree }?.refresh()
    }

    func receive(_ event: SandboxEvent) {
        let current: ProcessTree? = lock.withLock {
            if tree == nil { pending.append(event) }
            return tree
        }
        guard let current, current.claims(event) else { return }
        lock.withLock { events.append(event) }
        onEvent(event)
    }
}
