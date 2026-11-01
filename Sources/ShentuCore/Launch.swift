import Foundation
@_exported import ShentuSandbox

/// What you pick in the pop-up for one launch. Everything else is fixed: other writes only to
/// a temp folder made for this run (deleted when the app quits), no other programs, and the
/// sanity set (secrets, other apps' data, persistence) always blocked.
public struct LaunchChoice: Codable, Equatable, Sendable {
    /// What the app may do with one kind of file in your home folder and on drives.
    public enum Access: String, CaseIterable, Sendable {
        case off, read, readWrite

        public var title: String {
            switch self {
            case .off: return "Off"
            case .read: return "Read"
            case .readWrite: return "Read & Write"
            }
        }
    }

    /// How files in your home folder and on drives are opened up: by kind, or one by one.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Every file of the chosen kinds, anywhere in home and on drives.
        case kinds
        /// Only the files and folders you pick (read-only).
        case items

        public var title: String { self == .kinds ? "By kind" : "Only these" }
    }

    /// Internet and local-network connections.
    public var network = false
    public var mode = Mode.kinds
    /// Files and folders it can read when `mode` is `.items`. Absolute paths.
    public var readPaths: [String] = []
    /// The one folder it can write to (and read), kept after it quits. Its contents can be
    /// changed or deleted by the app. Absolute path, or nil.
    public var outputFolder: String?
    /// File kinds (`FileKind` raw values) readable in your home folder and on drives. Includes
    /// every writable kind.
    public var kinds: [String] = []
    /// File kinds also writable there: create, change, rename and delete files of that kind.
    public var writeKinds: [String] = []
    /// Keep a private home keyed by the app's canonical path. Shared preferences stay blocked.
    public var keepSettings = false

    public init(network: Bool = false, kinds: [FileKind] = [], writeKinds: [FileKind] = [], keepSettings: Bool = false,
                mode: Mode = .kinds, readPaths: [String] = [], outputFolder: String? = nil) {
        self.network = network
        self.mode = mode
        self.readPaths = readPaths
        self.outputFolder = outputFolder
        self.writeKinds = writeKinds.map(\.rawValue)
        self.kinds = (kinds + writeKinds.filter { !kinds.contains($0) }).map(\.rawValue)
        self.keepSettings = keepSettings
    }

    /// Choices saved before a field existed load with that field's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = try c.decodeIfPresent(Bool.self, forKey: .network) ?? false
        kinds = try c.decodeIfPresent([String].self, forKey: .kinds) ?? []
        writeKinds = try c.decodeIfPresent([String].self, forKey: .writeKinds) ?? []
        keepSettings = try c.decodeIfPresent(Bool.self, forKey: .keepSettings) ?? false
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .kinds
        readPaths = try c.decodeIfPresent([String].self, forKey: .readPaths) ?? []
        outputFolder = try c.decodeIfPresent(String.self, forKey: .outputFolder)
    }

    /// The readable kinds (writable ones included), in Finder's order. Names this version
    /// doesn't know are ignored.
    public var fileKinds: [FileKind] {
        FileKind.allCases.filter { kinds.contains($0.rawValue) || writeKinds.contains($0.rawValue) }
    }

    /// The writable kinds, in Finder's order.
    public var writableKinds: [FileKind] {
        FileKind.allCases.filter { writeKinds.contains($0.rawValue) }
    }

    public func allows(_ kind: FileKind) -> Bool { access(kind) != .off }

    public func access(_ kind: FileKind) -> Access {
        if writeKinds.contains(kind.rawValue) { return .readWrite }
        return kinds.contains(kind.rawValue) ? .read : .off
    }

    public mutating func set(_ kind: FileKind, _ access: Access) {
        kinds.removeAll { $0 == kind.rawValue }
        writeKinds.removeAll { $0 == kind.rawValue }
        if access != .off { kinds.append(kind.rawValue) }
        if access == .readWrite { writeKinds.append(kind.rawValue) }
    }

    /// The Restricted Sandbox settings for this launch. File kinds count only in `.kinds` mode,
    /// picked files and folders only in `.items` mode; the output folder counts in both.
    public var sandbox: RestrictedSandbox {
        let byKind = mode == .kinds
        return RestrictedSandbox(network: network, otherPrograms: false, ownData: keepSettings,
                                 readWrite: outputFolder.map { [$0] } ?? [],
                                 readOnly: byKind ? [] : readPaths,
                                 readFileTypes: byKind ? fileKinds.flatMap(\.extensions) : [],
                                 writeFileTypes: byKind ? writableKinds.flatMap(\.extensions) : [],
                                 limitDrives: true, ephemeralTemp: true)
    }

    /// Why `path` can't be opened up, or nil if it can. Only things inside your home folder or
    /// on a drive, never the whole home folder, a whole drive, ~/Library (every app's data), or
    /// anything inside a sanity-set location (which would stay blocked anyway).
    public static func problem(with path: String, environment: ShentuEnvironment) -> String? {
        let real = realPath(environment.expand(path))
        let home = realPath(environment.home)
        func within(_ p: String, _ root: String) -> Bool { p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        if !FileManager.default.fileExists(atPath: real) { return "\(path) doesn't exist." }
        let parts = real.split(separator: "/")
        let onDrive = parts.first == "Volumes" && parts.count >= 3
        if !(within(real, home) && real != home) && !onDrive {
            return "Choose something inside your home folder or on a drive, not \(real)."
        }
        if within(real, home + "/Library") { return "~/Library holds every app's data and settings, so nothing in it can be opened up." }
        for entry in Hardening.entries where entry.pattern == nil {
            if within(real, realPath(environment.expand(entry.path))) {
                return "\(environment.abbreviate(real)) is protected (\(entry.title)) and stays blocked."
            }
        }
        return nil
    }
}

public enum Shentu {
    /// Shentu's profiles, logs and remembered choices, under ~/Library.
    public static func environment() -> ShentuEnvironment {
        let lib = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return .current(dataRoot: lib.appendingPathComponent("Application Support/Shentu"),
                        logsRoot: lib.appendingPathComponent("Logs/Shentu"))
    }

    /// Runs the app confined until it quits. Blocks; call it off the main thread.
    public static func launch(
        _ app: String, _ choice: LaunchChoice, environment: ShentuEnvironment,
        stop: StopHandle? = nil, arguments: [String] = [],
        onLaunch: (@Sendable (pid_t) -> Void)? = nil,
        onRecord: (@Sendable (EnforceRecord) -> Void)? = nil,
        say: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> EnforceSummary {
        // Checked again at launch: a remembered folder may have moved, or become a link.
        let picked = (choice.mode == .items ? choice.readPaths : []) + (choice.outputFolder.map { [$0] } ?? [])
        for path in picked {
            if let problem = LaunchChoice.problem(with: path, environment: environment) { throw ShentuError.refused(problem) }
        }
        var options = EnforceOptions(target: app)
        options.arguments = arguments
        options.control = SessionControl(forwardSignals: false, stop: stop)
        options.onRecord = onRecord
        options.onLaunch = onLaunch
        return try Enforce.runRestricted(options, sandbox: choice.sandbox, environment: environment, say: say)
    }
}

/// The last choice for each app, so the pop-up starts where you left it.
public struct RememberedChoices {
    let url: URL

    public init(_ environment: ShentuEnvironment) {
        url = environment.dataRoot.appendingPathComponent("choices.json")
    }

    func all() -> [String: LaunchChoice] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: LaunchChoice].self, from: data)) ?? [:]
    }

    /// The strict default (no network, no reads, nothing kept) for an app you haven't run.
    public func choice(for key: String) -> LaunchChoice { all()[key] ?? LaunchChoice() }

    public func save(_ choice: LaunchChoice, for key: String) {
        var choices = all()
        choices[key] = choice
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.ensureDirectory(url.deletingLastPathComponent())
        try? encoder.encode(choices).write(to: url, options: .atomic)
    }
}
