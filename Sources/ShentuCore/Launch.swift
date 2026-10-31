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

    /// Internet and local-network connections.
    public var network = false
    /// File kinds (`FileKind` raw values) readable in your home folder and on drives. Includes
    /// every writable kind.
    public var kinds: [String] = []
    /// File kinds also writable there: create, change, rename and delete files of that kind.
    public var writeKinds: [String] = []
    /// The app's own settings, caches and saved state in ~/Library. Off: it starts fresh and
    /// nothing is kept.
    public var keepSettings = false

    public init(network: Bool = false, kinds: [FileKind] = [], writeKinds: [FileKind] = [], keepSettings: Bool = false) {
        self.network = network
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

    /// The Restricted Sandbox settings for this launch.
    public var sandbox: RestrictedSandbox {
        RestrictedSandbox(network: network, otherPrograms: false, ownData: keepSettings,
                          readFileTypes: fileKinds.flatMap(\.extensions),
                          writeFileTypes: writableKinds.flatMap(\.extensions),
                          limitDrives: true, ephemeralTemp: true)
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
        onRecord: (@Sendable (EnforceRecord) -> Void)? = nil,
        say: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> EnforceSummary {
        var options = EnforceOptions(target: app)
        options.arguments = arguments
        options.control = SessionControl(forwardSignals: false, stop: stop)
        options.onRecord = onRecord
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
