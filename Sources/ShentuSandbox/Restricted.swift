import Foundation

/// The Restricted Sandbox: one set of restrictions you choose once, applied to any app you drop
/// on Shentu, with no learning. Everything is allowed except what is switched off here, and
/// the sanity set (secrets, other apps' data, persistence) is always blocked.
public struct RestrictedSandbox: Equatable, Sendable {
    /// Internet and local-network connections. Local sockets (logging, DNS) always work.
    public var network = false
    /// Starting other programs, and having macOS open apps, documents or links. Bundled
    /// helpers can fork/exec; posix_spawn is blocked to prevent group changes.
    public var otherPrograms = false
    /// A private home for this app, keyed by canonical bundle path. Shared preferences stay blocked.
    public var ownData = true
    /// The only places outside temp folders it can write, and the only places in your home
    /// folder it can read.
    public var readWrite: [String] = []
    /// Readable, never writable.
    public var readOnly: [String] = []
    /// File extensions readable anywhere in your home folder (and on drives, with `limitDrives`),
    /// e.g. a `FileKind`'s extensions. Stored as the list itself, so it stays auditable.
    public var readFileTypes: [String] = []
    /// File extensions also writable (create, change, rename, delete) in your home folder and,
    /// with `limitDrives`, on drives. Nowhere else, and never in the sanity set.
    public var writeFileTypes: [String] = []
    /// External drives (`/Volumes`) get the same limits as your home folder: names visible,
    /// contents only for the folders and file types you chose.
    public var limitDrives = false
    /// Writes go only to a fresh folder made for this run (exported as TMPDIR) and deleted when
    /// the app quits, instead of the shared temp folders. Mac apps ignore TMPDIR
    /// (NSTemporaryDirectory, reference row 21), so their usual temp writes are blocked.
    public var ephemeralTemp = false

    public init(network: Bool = false, otherPrograms: Bool = false, ownData: Bool = true,
                readWrite: [String] = [], readOnly: [String] = [], readFileTypes: [String] = [],
                writeFileTypes: [String] = [], limitDrives: Bool = false, ephemeralTemp: Bool = false) {
        self.network = network
        self.otherPrograms = otherPrograms
        self.ownData = ownData
        self.readWrite = readWrite
        self.readOnly = readOnly
        self.readFileTypes = readFileTypes
        self.writeFileTypes = writeFileTypes
        self.limitDrives = limitDrives
        self.ephemeralTemp = ephemeralTemp
    }

    /// One-line summary for the profile's header and the run's output.
    public var summary: String {
        var parts = [network ? "network on" : "no network"]
        let temp = ephemeralTemp ? "a temp folder for this run" : "temp"
        parts.append(readWrite.isEmpty ? "writes only to \(temp)" : "writes to \(temp) and \(readWrite.count) folder\(readWrite.count == 1 ? "" : "s")")
        if !readOnly.isEmpty { parts.append("reads \(readOnly.count) more") }
        if !readFileTypes.isEmpty { parts.append("reads \(readFileTypes.count) file type\(readFileTypes.count == 1 ? "" : "s")") }
        if !writeFileTypes.isEmpty { parts.append("writes \(writeFileTypes.count) file type\(writeFileTypes.count == 1 ? "" : "s")") }
        if limitDrives { parts.append("drives limited") }
        if !otherPrograms { parts.append("no other programs") }
        if !ownData { parts.append("no saved data") }
        return parts.joined(separator: " · ")
    }

    /// A private home keyed by canonical bundle path, never by app-supplied names or IDs.
    static func ownFolders(_ target: TargetIdentity, _ environment: ShentuEnvironment) -> [String] {
        [environment.isolatedHome(for: target).path]
    }

    /// `name` if it is safe as one folder name: letters, digits, space, `.`, `-` and `_`, not
    /// starting with a dot (so not "." or ".."), at most 255 bytes. Otherwise nil.
    static func plainName(_ name: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("."), name.utf8.count <= 255,
              name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " .-_".unicodeScalars.contains($0)) })
        else { return nil }
        return name
    }
}

extension SBPLCompiler {
    /// Operation families a normal app uses. Left out on purpose: boot-arg-set,
    /// opendirectory-user-modify and fs-snapshot*; anything not listed is denied and logged.
    static let restrictedBase = [
        "file*", "ipc*", "iokit*", "mach*", "network*", "process*", "signal", "sysctl*", "system*",
        "user-preference*", "nvram*", "job-creation", "lsopen", "pseudo-tty", "dynamic-code-generation",
        "darwin-notification-post", "distributed-notification-post", "authorization-right-obtain",
        "hid-control", "appleevent-send", "syscall*", "generic-issue-extension", "socket-ioctl",
        "device*", "qtn-user",
    ]

    /// The Restricted Sandbox profile. Starts by allowing everything an app normally does, so any
    /// app runs without learning, then takes away: the network, your home folder (except the folders you chose and
    /// the app's own), writes outside temp and your read & write folders, other programs. The
    /// sanity set comes last so it wins. Every deny carries a filter: a filter-less deny would
    /// only set the operation's default. The exception is `lsopen`, which the kernel
    /// checks with no path, so no filter matches it.
    /// `scratch` is the run's own temp folder when `box.ephemeralTemp` is on.
    public func restrictedProfile(_ target: ResolvedTarget, _ box: RestrictedSandbox, scratch: String? = nil) -> String {
        let t = target.identity
        let home = environment.home
        let rw = box.readWrite.map(environment.expand).map(realPath)
        let ro = box.readOnly.map(environment.expand).map(realPath)
        let own = box.ownData ? RestrictedSandbox.ownFolders(t, environment) : []
        func subpaths(_ paths: [String]) -> [String] { paths.map { "(subpath \(quote($0)))" } }
        let ownBundle = t.path == t.executable ? "(literal \(quote(t.executable)))" : "(subpath \(quote(t.path)))"

        // The name and bundle ID are the app's own text: no control characters (a newline would
        // end the comment and start a rule).
        let label = "\(t.name)\(t.bundleId.map { " (\($0))" } ?? "")".unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
            .map(String.init).joined()
        var out = [
            ";; Shentu Restricted Sandbox for \(label): \(box.summary).",
            "(version 1)",
            "(deny default)",
            "(import \"system.sb\")",
            ";; everything an app normally does, as explicit allows: under (allow default) the kernel",
            ";; enforces the denies below but never logs them (tested), so nothing would show up.",
            "(allow \(Self.restrictedBase.joined(separator: " ")))",
        ]
        if !box.network {
            out += ["", ";; no network",
                    "(deny network-outbound (remote ip))",
                    "(deny network-bind network-inbound (local ip))"]
        }
        // Order: no writes anywhere, then temp; then nothing in home (whatever the earlier lines
        // allowed); then only your folders and the app's own. Allows use the same wildcard
        // `file-read*` as the sanity set's denies: a rule naming a specific operation
        // (file-read-data) beats a wildcard one whatever the order, so it would have re-opened
        // .env files in your folders (tested). File names in home stay visible: many apps stop
        // working without file-read-metadata. The shared temp `…/T`, not its Darwin folder:
        // that holds every app's caches; the app's own are among its own folders.
        // With an ephemeral temp, the run's own folder replaces the shared ones.
        let temp = (box.ephemeralTemp ? [scratch.map(realPath)] : [environment.userTempDir, "/private/tmp"])
            .compactMap { $0 } + ["/dev"]
        let closed = [home] + (box.limitDrives ? ["/Volumes"] : [])
        out += ["", ";; writes: only \(box.ephemeralTemp ? "this run's temp folder" : "temp folders") and your read & write folders",
                "(deny file-write* (subpath \"/\"))",
                statement("allow", ["file-write*"], subpaths(temp), report: false),
                ";; your home folder\(box.limitDrives ? " and drives" : ""): only the folders you chose\(box.ownData ? " and the app's own data" : "")",
                statement("deny", ["file-read*", "file-write*"], subpaths(closed), report: false),
                statement("allow", ["file-read-metadata"], subpaths(closed), report: false)]
        if !(rw + own).isEmpty {
            out.append(statement("allow", ["file-write*"], subpaths(rw + own), report: false))
        }
        // Shared cfprefsd domains are not isolated by HOME or filesystem rules.
        out.append("(deny user-preference* (preference-domain-prefix \"\"))")
        let readable = [t.path] + rw + ro + own + [home + "/Library/Fonts"]
        out.append(statement("allow", ["file-read*"], subpaths(readable), report: false))
        // Everything outside home and drives is readable already, so the regex needs no place.
        // Folders become listable too: without that, the app (and its own Open panel, which
        // runs in-process for unsandboxed apps) couldn't find the files it may read (tested).
        func valid(_ list: [String]) -> [String] { list.filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber } } }
        let types = valid(box.readFileTypes)
        if !types.isEmpty {
            let filter = filterText(.fileTypes(types.joined(separator: ",")))
            out.append(";; files of the types you chose, and folder listings to find them")
            out.append(statement("allow", ["file-read*"], [filter, "(vnode-type DIRECTORY)"], report: false))
        }
        // Writing files of the chosen types, only where reading was closed (home, and drives):
        // the regex alone would also match /Applications or /Library. A save that goes through
        // a temporary file with another name (NSDocument's safe save) is still blocked.
        let writeTypes = valid(box.writeFileTypes)
        if !writeTypes.isEmpty {
            let filter = filterText(.fileTypes(writeTypes.joined(separator: ",")))
            let places = subpaths(closed)
            let place = places.count == 1 ? places[0] : "(require-any \(places.joined(separator: " ")))"
            out.append(";; writing files of the types you chose, in your home folder\(box.limitDrives ? " and on drives" : "")")
            out.append("(allow file-write* (require-all \(filter) \(place)))")
        }
        if !box.otherPrograms {
            out += ["", ";; no other programs, nor apps, documents or links opened through LaunchServices",
                    "(deny process-exec* (subpath \"/\"))",
                    "(allow process-exec* \(ownBundle))",
                    "(deny lsopen)"]
        }
        let rules = Hardening(environment: environment).rules()
        out += ["", ";; sanity set (last, so it wins)"] + statements(rules)
        // Keep every descendant in the process group created before applying Seatbelt.
        // posix_spawn can change groups internally without invoking setpgid/setsid.
        out.append("(deny syscall-unix (syscall-number SYS_setsid SYS_setpgid SYS_posix_spawn))")
        // Even broad file-kind/output grants must not expose the control plane or other homes.
        let protected = [realPath(environment.dataRoot.path), realPath(environment.logsRoot.path),
                         environment.home + "/Library/Application Support/Shentu",
                         environment.home + "/Library/Logs/Shentu"]
        for path in Set(protected).sorted() {
            let exceptions = own.map { "(require-not (subpath \(quote($0))))" }.joined(separator: " ")
            out.append("(deny file-read* file-write* (require-all (subpath \(quote(path))) \(exceptions)))")
        }
        out.append("(deny file-link (subpath \"/\"))")
        return out.joined(separator: "\n") + "\n"
    }
}
