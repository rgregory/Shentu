import Foundation
import CryptoKit

public enum ShentuError: Error, CustomStringConvertible {
    case refused(String)
    case usage(String)
    case failed(String)

    public var description: String {
        switch self {
        case .refused(let why): return "refused: \(why)"
        case .usage(let why): return "usage: \(why)"
        case .failed(let why): return "error: \(why)"
        }
    }
}

/// Where Shentu reads and writes, and whose home directory `~` means. Tests build their own.
public struct ShentuEnvironment: Sendable {
    public var home: String
    public var dataRoot: URL
    public var logsRoot: URL
    /// Per-user Darwin folder (`/private/var/folders/xx/yyy`). Not an anchor itself: it holds
    /// every app's caches. See `userTempDir` and `userAppAreas`.
    public var userTempRoot: String?

    public init(home: String, dataRoot: URL, logsRoot: URL, userTempRoot: String?) {
        self.home = home
        self.dataRoot = dataRoot
        self.logsRoot = logsRoot
        self.userTempRoot = userTempRoot
    }

    /// `SHENTU_DATA=/some/dir` keeps profiles and logs together in one folder (handy for testing).
    public static func current() -> ShentuEnvironment {
        let home = NSHomeDirectory()
        let lib = URL(fileURLWithPath: home).appendingPathComponent("Library")
        if let custom = ProcessInfo.processInfo.environment["SHENTU_DATA"], !custom.isEmpty {
            let root = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            return ShentuEnvironment(home: home, dataRoot: root, logsRoot: root.appendingPathComponent("logs"),
                                      userTempRoot: darwinUserRoot())
        }
        return ShentuEnvironment(
            home: home,
            dataRoot: lib.appendingPathComponent("Application Support/Shentu"),
            logsRoot: lib.appendingPathComponent("Logs/Shentu"),
            userTempRoot: darwinUserRoot()
        )
    }

    /// The current user's environment with explicit data and log folders.
    public static func current(dataRoot: URL, logsRoot: URL) -> ShentuEnvironment {
        ShentuEnvironment(home: NSHomeDirectory(), dataRoot: dataRoot, logsRoot: logsRoot,
                           userTempRoot: darwinUserRoot())
    }

    /// App metadata cannot select another app's storage or Shentu's control files.
    public func isolatedHome(for target: TargetIdentity) -> URL {
        let key = SHA256.hash(data: Data(realPath(target.path).utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: realPath(dataRoot.path)).appendingPathComponent("homes").appendingPathComponent(key)
    }

    public var canaryDir: URL { dataRoot.appendingPathComponent("canary") }
    public func logsDir(_ key: String) -> URL { logsRoot.appendingPathComponent(key) }
    /// `…/T`: the temp folder every unsandboxed app of this user shares (NSTemporaryDirectory).
    public var userTempDir: String? { userTempRoot.map { $0 + "/T" } }
    /// `…/C` (caches) and `…/0`: one folder per app, like the ~/Library areas.
    var userAppAreas: [String] { userTempRoot.map { [$0 + "/C", $0 + "/0"] } ?? [] }

    /// `/private/var/folders/xx/yyy` — parent of the user's T (temp) and C (cache) directories.
    static func darwinUserRoot() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let temp = realPath(String(decoding: bytes, as: UTF8.self))
        return (temp as NSString).deletingLastPathComponent
    }

    /// `/Users/me/Library/x` → `~/Library/x`. Paths outside home are returned unchanged.
    public func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public func expand(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}

public extension FileManager {
    func ensureDirectory(_ url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// The path the kernel sees and Seatbelt matches against (`/private/tmp/x`, not `/tmp/x`).
/// Foundation's `resolvingSymlinksInPath` strips `/private`, which would make rules never match.
public func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Timestamp safe for file names: 20261029-190312.
func fileStamp(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: date)
}
