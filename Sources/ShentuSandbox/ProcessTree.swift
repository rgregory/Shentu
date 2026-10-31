import Darwin
import Foundation

/// Tracks the target's process tree so reports from unrelated processes are ignored.
/// Seatbelt is inherited across fork/exec, so every descendant belongs to the run.
public final class ProcessTree: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t>
    private var execNames: Set<String> = []

    public init(root: pid_t) {
        pids = [root]
    }

    public var trackedPIDs: Set<pid_t> {
        lock.withLock { pids }
    }

    /// Decides whether `event` came from the tree, learning new descendants as it goes.
    public func claims(_ event: SandboxEvent) -> Bool {
        lock.withLock {
            if pids.contains(event.pid) {
                if event.operation.hasPrefix("process-exec") {
                    let name = (event.target as NSString).lastPathComponent
                    execNames.insert(Self.commandName(name))
                }
                return true
            }
            if let parent = Self.parentPID(of: event.pid) {
                guard pids.contains(parent) else { return false }
                pids.insert(event.pid)
                return true
            }
            // The process is already gone. Accept it only if a tracked process exec'd a binary
            // with this name: short-lived children are common (shell helpers) and can't be
            // looked up after they exit.
            if execNames.contains(Self.commandName(event.process)) {
                pids.insert(event.pid)
                return true
            }
            return false
        }
    }

    /// Adds any children of tracked processes. Call periodically while the target runs.
    public func refresh() {
        let current = trackedPIDs
        var found: [pid_t] = []
        for pid in current {
            found.append(contentsOf: Self.children(of: pid))
        }
        guard !found.isEmpty else { return }
        lock.withLock { pids.formUnion(found) }
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    /// The kernel truncates p_comm to MAXCOMLEN (16) characters in some reports.
    static func commandName(_ name: String) -> String {
        String(name.prefix(Int(MAXCOMLEN)))
    }
}
