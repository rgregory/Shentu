import Foundation
import Security

/// The app or binary being run, and who signed it.
public struct TargetIdentity: Codable, Equatable, Sendable {
    public var path: String
    public var executable: String
    public var name: String
    public var bundleId: String?
    public var teamId: String?
    public var signingId: String?
    public var cdhash: String?

    /// File-name-safe key for profiles, logs and remembered choices.
    public var key: String {
        let raw = bundleId ?? signingId ?? name
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

public struct ResolvedTarget: Sendable {
    public var identity: TargetIdentity
    /// Bundle path for .app targets, nil for bare executables.
    public var bundlePath: String?
    public var isAppleSigned: Bool
    public var hasAppSandbox: Bool

    public static func resolve(_ path: String) throws -> ResolvedTarget {
        let url = URL(fileURLWithPath: realPath(path))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ShentuError.usage("no such file: \(path)")
        }

        let executable: String
        let name: String
        var bundleId: String?
        var bundlePath: String?
        if isDir.boolValue {
            guard let bundle = Bundle(url: url), let exe = bundle.executableURL else {
                throw ShentuError.usage("\(path) is a directory but not an app bundle")
            }
            executable = realPath(exe.path)
            bundleId = bundle.bundleIdentifier
            bundlePath = url.path
            name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        } else {
            executable = url.path
            name = url.lastPathComponent
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ShentuError.usage("not executable: \(executable)")
        }

        let signing = SigningInfo.read(url)
        let identity = TargetIdentity(
            path: url.path, executable: executable, name: name, bundleId: bundleId,
            teamId: signing.teamId, signingId: signing.identifier, cdhash: signing.cdhash
        )
        return ResolvedTarget(
            identity: identity, bundlePath: bundlePath,
            isAppleSigned: signing.isAppleAnchor, hasAppSandbox: signing.hasAppSandbox
        )
    }

    /// Whether Seatbelt can wrap this app, decided from its signature alone (no launch).
    public var wrapStatus: WrapStatus {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            return .unavailable("/usr/bin/sandbox-exec is missing on this system")
        }
        // Apple first: launch constraints apply to Apple's apps whether or not they're sandboxed.
        if isAppleSigned && bundlePath != nil { return .appleApp }
        if hasAppSandbox { return .alreadySandboxed }
        return .wrappable
    }

    /// Refuses targets Seatbelt can't wrap, before anything is launched.
    public func preflight() throws {
        if let problem = wrapStatus.problem(name: identity.name) { throw ShentuError.refused(problem) }
    }
}

struct SigningInfo {
    var teamId: String?
    var identifier: String?
    var cdhash: String?
    var isAppleAnchor = false
    var hasAppSandbox = false

    static func read(_ url: URL) -> SigningInfo {
        var result = SigningInfo()
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return result }

        var cfInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        if SecCodeCopySigningInformation(code, flags, &cfInfo) == errSecSuccess,
           let info = cfInfo as? [String: Any] {
            result.teamId = info[kSecCodeInfoTeamIdentifier as String] as? String
            result.identifier = info[kSecCodeInfoIdentifier as String] as? String
            if let unique = info[kSecCodeInfoUnique as String] as? Data {
                result.cdhash = unique.map { String(format: "%02x", $0) }.joined()
            }
            if let ents = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
                result.hasAppSandbox = (ents["com.apple.security.app-sandbox"] as? Bool) == true
            }
        }

        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
           let req = requirement {
            // Only the anchor matters here, so skip re-hashing every file in the bundle: same answer
            // in under a millisecond instead of up to ~80 ms (measured).
            let quick = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSDoNotValidateExecutable)
            result.isAppleAnchor = SecStaticCodeCheckValidity(code, quick, req) == errSecSuccess
        }
        return result
    }
}

/// Whether Shentu can put an app in its sandbox.
public enum WrapStatus: Equatable, Sendable {
    case wrappable
    /// Already confined by Apple's App Sandbox; Seatbelt refuses a second sandbox.
    case alreadySandboxed
    /// Signed by Apple: launch constraints only let launchd start it.
    case appleApp
    case unavailable(String)

    /// The full reason, nil when the app can be wrapped.
    public func problem(name: String) -> String? {
        switch self {
        case .wrappable:
            return nil
        case .alreadySandboxed:
            return "\(name) already runs in Apple's App Sandbox. Seatbelt won't apply a second sandbox to it (the kernel denies `forbidden-sandbox-reinit` and the app traps at launch). It is already confined by its own entitlements."
        case .appleApp:
            return "\(name) is signed by Apple. macOS launch constraints kill Apple's own apps unless launchd starts them, so they can't be wrapped."
        case .unavailable(let why):
            return why
        }
    }
}
