import Foundation
@_exported import MenshenCore

/// What you pick in the pop-up for one launch. Everything else is fixed: writes only to a temp
/// folder made for this run (deleted when the app quits), no other programs, and Menshen's
/// sanity set (secrets, other apps' data, persistence) always blocked.
public struct LaunchChoice: Codable, Equatable, Sendable {
    /// Internet and local-network connections.
    public var network = false
    /// File kinds (`FileKind` raw values) readable in your home folder and on drives.
    public var kinds: [String] = []
    /// The app's own settings, caches and saved state in ~/Library. Off: it starts fresh and
    /// nothing is kept.
    public var keepSettings = false

    public init(network: Bool = false, kinds: [FileKind] = [], keepSettings: Bool = false) {
        self.network = network
        self.kinds = kinds.map(\.rawValue)
        self.keepSettings = keepSettings
    }

    /// The chosen kinds, in Finder's order. Names this version doesn't know are ignored.
    public var fileKinds: [FileKind] {
        FileKind.allCases.filter { kinds.contains($0.rawValue) }
    }

    public func allows(_ kind: FileKind) -> Bool { kinds.contains(kind.rawValue) }

    public mutating func set(_ kind: FileKind, _ on: Bool) {
        kinds.removeAll { $0 == kind.rawValue }
        if on { kinds.append(kind.rawValue) }
    }

    /// The Restricted Sandbox settings for this launch.
    public var sandbox: RestrictedSandbox {
        RestrictedSandbox(network: network, otherPrograms: false, ownData: keepSettings,
                          readFileTypes: fileKinds.flatMap(\.extensions), limitDrives: true, ephemeralTemp: true)
    }
}

public enum Shentu {
    /// Shentu keeps its own profiles, logs and remembered choices, apart from Menshen's.
    public static func environment() -> MenshenEnvironment {
        let lib = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return .current(dataRoot: lib.appendingPathComponent("Application Support/Shentu"),
                        logsRoot: lib.appendingPathComponent("Logs/Shentu"))
    }

    /// Runs the app confined until it quits. Blocks; call it off the main thread.
    public static func launch(
        _ app: String, _ choice: LaunchChoice, environment: MenshenEnvironment,
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

    public init(_ environment: MenshenEnvironment) {
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
