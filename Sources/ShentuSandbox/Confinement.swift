import Foundation

/// What an app's own code signature says about its confinement: Apple's App Sandbox and, area
/// by area, what its entitlements let it do and what the sandbox keeps from it; and the
/// Hardened Runtime and what it relaxes. Shown for apps Shentu can't wrap (already sandboxed,
/// or Apple's own), so you see the restrictions they already run under instead of only a refusal.
public struct Confinement: Equatable, Sendable {
    /// One line of the summary: "Files: ✓ files you pick ✕ Downloads, Pictures, …".
    public struct Area: Equatable, Sendable {
        public var name: String
        public var allowed: [String] = []
        public var denied: [String] = []
    }

    /// In Apple's App Sandbox (com.apple.security.app-sandbox).
    public var sandboxed = false
    /// Signed with the Hardened Runtime.
    public var hardenedRuntime = false
    /// Network, Files, Devices, Personal data, Other; empty if not sandboxed (then nothing is
    /// kept from it).
    public var areas: [Area] = []
    /// Temporary exceptions to its sandbox, with what they name.
    public var exceptions: [String] = []
    /// Hardened Runtime protections it turns off.
    public var relaxed: [String] = []
    /// App groups it shares data with.
    public var groups: [String] = []
    /// Where it can keep data, with ~ for home: its container, its app groups' containers, and
    /// read & write exceptions. Empty if not sandboxed (then it can write wherever you can).
    public var storage: [String] = []
    /// Private Apple entitlements (com.apple.private.*): not documented, so only counted.
    public var privateCount = 0
    /// A way out of, or around, its own confinement, and how much it matters.
    public struct Gap: Equatable, Sendable {
        public enum Severity: Int, Comparable, Sendable {
            /// Code can get in, or the app can act outside its sandbox.
            case high
            /// Data can get out, or the sandbox reaches further than its entitlements say.
            case medium
            /// Worth knowing.
            case low
            public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        }
        public var severity: Severity
        public var text: String
    }

    /// Ways out of, or around, its own confinement, most serious first: what its entitlements
    /// and exceptions open up, and what the App Sandbox leaves open that Shentu closes.
    public var gaps: [Gap] = []
    /// How it could read your secrets (SSH keys, .env files, cloud credentials, password
    /// stores, shell history, …), most serious first. Empty: nothing in its signature lets it.
    public var secrets: [Gap] = []
    /// It can read a secret only if you pick it in an Open panel.
    public var secretsOnlyIfPicked = false

    public init() {}

    /// What an App Sandbox app can be granted, by area: the words, the entitlements that grant
    /// reading only, and those that grant reading and writing (or the whole thing).
    static let capabilities: [(area: String, words: String, read: [String], full: [String])] = [
        ("Network", "connect out", [], ["network.client"]),
        ("Network", "accept connections", [], ["network.server"]),
        ("Files", "files you pick", ["files.user-selected.read-only"], ["files.user-selected.read-write", "files.all"]),
        ("Files", "Downloads", ["files.downloads.read-only"], ["files.downloads.read-write", "files.all"]),
        ("Files", "Pictures", ["assets.pictures.read-only"], ["assets.pictures.read-write", "files.all"]),
        ("Files", "Music", ["assets.music.read-only"], ["assets.music.read-write", "files.all"]),
        ("Files", "Movies", ["assets.movies.read-only"], ["assets.movies.read-write", "files.all"]),
        ("Devices", "camera", [], ["device.camera"]),
        ("Devices", "microphone", [], ["device.audio-input", "device.microphone"]),
        ("Devices", "USB", [], ["device.usb"]),
        ("Devices", "Bluetooth", [], ["device.bluetooth"]),
        ("Devices", "serial ports", [], ["device.serial"]),
        ("Personal data", "contacts", [], ["personal-information.addressbook"]),
        ("Personal data", "calendars", [], ["personal-information.calendars"]),
        ("Personal data", "location", [], ["personal-information.location"]),
        ("Personal data", "Photos", [], ["personal-information.photos-library"]),
        ("Other", "print", [], ["print"]),
        ("Other", "control other apps", [], ["automation.apple-events"]),
    ]

    static let runtimeGaps: [(String, Gap.Severity, String)] = [
        ("cs.allow-dyld-environment-variables", .high, "It accepts DYLD_ environment variables, so code can be injected into it at launch."),
        ("cs.disable-library-validation", .high, "It loads libraries signed by anyone, so a planted library runs inside it."),
        ("cs.debugger", .high, "It can attach to and debug other apps."),
        ("cs.allow-unsigned-executable-memory", .medium, "It can run unsigned code in memory, which makes exploits easier."),
        ("cs.disable-executable-page-protection", .medium, "Executable page protection is off, which makes exploits easier."),
    ]

    /// The secrets the sanity set protects (Hardening): credentials, keys, tokens, password
    /// stores, shell history, browser and chat sessions. Not other apps' plain data.
    static let secretEntries = Hardening.entries.filter {
        $0.protection == .readWrite && !["H-containers", "H-group-containers", "H-safari", "H-messages", "H-mail",
                                         "H-contacts", "H-calendars", "H-photos", "H-system-keychains"].contains($0.id)
    }

    /// Whether, and how, it can read your secrets: called out first, since that's what a
    /// sandbox is most often trusted to protect.
    static func secretGaps(_ entitlements: [String: Any], _ c: Confinement) -> [Gap] {
        func on(_ key: String) -> Bool { (entitlements["com.apple.security." + key] as? Bool) == true }
        func names(_ key: String) -> [String] {
            let value = entitlements["com.apple.security.temporary-exception." + key]
            return (value as? [String]) ?? (value as? String).map { [$0] } ?? []
        }
        let everything = "SSH keys, .env and key files, cloud and API credentials, password stores, shell history and browser sessions"
        if !c.sandboxed { return [Gap(severity: .high, text: "It can read all of them: \(everything). Nothing stops it.")] }
        if on("files.all") { return [Gap(severity: .high, text: "The all-files entitlement lets it read all of them: \(everything).")] }
        var gaps: [Gap] = []
        // Compare every exception in the same absolute namespace, including exceptions for
        // ancestors of home. Standardize dot components and preserve the filesystem root.
        let home = NSHomeDirectory()
        func normalized(_ path: String) -> String {
            (path as NSString).standardizingPath
        }
        let relative = (names("files.home-relative-path.read-only") + names("files.home-relative-path.read-write")).map {
            normalized(home + ($0.hasPrefix("/") ? $0 : "/" + $0))
        }
        let absolute = (names("files.absolute-path.read-only") + names("files.absolute-path.read-write")).map(normalized)
        for path in Array(Set(relative + absolute)).sorted() {
            let place = path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
            let named = secretEntries.filter {
                guard $0.pattern == nil else { return false }
                let secret = normalized($0.path == "~" ? home : ($0.path.hasPrefix("~/") ? home + $0.path.dropFirst(1) : $0.path))
                return secret.isWithin(path) || path.isWithin(secret)
            }.map(\.title)
            if !named.isEmpty {
                gaps.append(Gap(severity: .high, text: "Its exception for \(place) lets it read \(named.joined(separator: ", "))."))
            } else {
                gaps.append(Gap(severity: .medium, text: "Any .env, key or credential file inside \(place) is readable to it."))
            }
        }
        if ["files.downloads.read-only", "files.downloads.read-write"].contains(where: on) {
            gaps.append(Gap(severity: .medium, text: "Anything saved in Downloads (.env files, keys, exported credentials) is readable to it."))
        }
        return gaps
    }

    static func gaps(_ entitlements: [String: Any], _ c: Confinement) -> [Gap] {
        func on(_ key: String) -> Bool { (entitlements["com.apple.security." + key] as? Bool) == true }
        func names(_ key: String) -> [String] {
            let value = entitlements["com.apple.security.temporary-exception." + key]
            return (value as? [String]) ?? (value as? String).map { [$0] } ?? []
        }
        func list(_ items: [String]) -> String {
            items.count <= 3 ? items.joined(separator: ", ") : items.prefix(3).joined(separator: ", ") + " and \(items.count - 3) more"
        }
        var gaps: [Gap] = []
        func add(_ severity: Gap.Severity, _ text: String) { gaps.append(Gap(severity: severity, text: text)) }
        guard c.sandboxed else {
            add(.high, "No App Sandbox: it can read and change anything you can, and run other programs.")
            if !c.hardenedRuntime { add(.high, "No Hardened Runtime: code can be injected into it (DYLD_ variables, unsigned libraries).") }
            return gaps
        }
        if !c.hardenedRuntime {
            add(.high, "No Hardened Runtime: code can be injected into it (DYLD_ variables, unsigned libraries).")
        } else {
            for (key, severity, words) in runtimeGaps where on(key) { add(severity, words) }
        }
        if on("files.all") { add(.high, "It has the old all-files entitlement: your whole home folder is open to it.") }
        if on("files.bookmarks.app-scope") { add(.low, "Files you picked once can stay open to it in later runs (bookmarks).") }
        if on("automation.apple-events") {
            add(.high, "It may control other apps with Apple Events (after you allow it). They aren't in its sandbox, so this reaches past it.")
        }
        let scripting = ((entitlements["com.apple.security.scripting-targets"] as? [String: Any]) ?? [:]).keys.sorted()
        let events = names("apple-events")
        if !(scripting + events).isEmpty {
            add(.high, "It may control these apps, outside its sandbox: \(list(scripting + events)).")
        }
        let services = names("mach-lookup.global-name") + names("mach-lookup.local-name") + names("mach-register.global-name")
        if !services.isEmpty { add(.high, "It may talk to services outside its sandbox: \(list(services)).") }
        let paths = names("files.home-relative-path.read-only").map { "~" + $0 } + names("files.home-relative-path.read-write").map { "~" + $0 }
            + names("files.absolute-path.read-only") + names("files.absolute-path.read-write")
        if !paths.isEmpty { add(.medium, "It may reach these places outside its container: \(list(paths)).") }
        let prefs = names("shared-preference.read-only") + names("shared-preference.read-write")
        if !prefs.isEmpty { add(.medium, "It may read or change other apps' settings: \(list(prefs)).") }
        let other = c.exceptions.filter { e in
            !["apple-events", "mach-lookup.", "mach-register.", "files.", "shared-preference."].contains { e.hasPrefix($0) }
        }
        if !other.isEmpty { add(.medium, "Other exceptions to its sandbox: \(list(other)).") }
        if !c.groups.isEmpty {
            add(.low, "It shares a data folder with other apps from the same developer (\(list(c.groups))).")
        }
        if c.privateCount > 0 {
            add(.medium, "\(c.privateCount) private Apple entitlement\(c.privateCount == 1 ? "" : "s") can grant access not listed here.")
        }
        // What the App Sandbox itself leaves open, whatever the entitlements; Shentu closes both.
        add(.medium, "It can open links and other apps (LaunchServices). A link can carry data out even without network access. Shentu blocks this.")
        add(.low, "It can read most of the system outside your home folder (/Applications, /Library and the like).")
        return gaps.enumerated().sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }.map(\.element)
    }

    static let runtimeKeys: [(String, String)] = [
        ("cs.allow-jit", "Generate code at run time (JIT)"),
        ("cs.allow-unsigned-executable-memory", "Run unsigned code in memory"),
        ("cs.disable-executable-page-protection", "Turn off executable page protection"),
        ("cs.disable-library-validation", "Load libraries signed by someone else"),
        ("cs.allow-dyld-environment-variables", "Accept DYLD_ environment variables (code injection)"),
        ("cs.debugger", "Debug other apps"),
    ]

    /// From an entitlements dictionary and whether the Hardened Runtime flag is set.
    /// `bundleId` names its container (~/Library/Containers/<bundle ID>).
    public static func describe(_ entitlements: [String: Any], hardenedRuntime: Bool, bundleId: String? = nil) -> Confinement {
        func on(_ key: String) -> Bool { (entitlements["com.apple.security." + key] as? Bool) == true }
        var c = Confinement()
        c.sandboxed = on("app-sandbox")
        c.hardenedRuntime = hardenedRuntime
        if c.sandboxed {
            let scripting = ((entitlements["com.apple.security.scripting-targets"] as? [String: Any]) ?? [:]).keys.sorted()
            for cap in capabilities {
                if c.areas.last?.name != cap.area {
                    c.areas.append(Area(name: cap.area))
                    if cap.area == "Files" { c.areas[c.areas.count - 1].denied.append("the rest of your home folder and other apps' data") }
                }
                let i = c.areas.count - 1
                if cap.full.contains(where: on) { c.areas[i].allowed.append(cap.words) }
                else if cap.read.contains(where: on) { c.areas[i].allowed.append(cap.words + " (read only)") }
                else if cap.words == "control other apps" && !scripting.isEmpty {
                    c.areas[i].allowed.append("control " + scripting.joined(separator: ", "))
                } else { c.areas[i].denied.append(cap.words) }
            }
        }
        if hardenedRuntime {
            for (key, words) in runtimeKeys where on(key) { c.relaxed.append(words) }
        }
        c.groups = (entitlements["com.apple.security.application-groups"] as? [String] ?? []).sorted()
        let prefix = "com.apple.security.temporary-exception."
        for key in entitlements.keys.sorted() where key.hasPrefix(prefix) {
            let what = String(key.dropFirst(prefix.count))
            let names: [String]
            switch entitlements[key] {
            case let list as [String]: names = list
            case let one as String: names = [one]
            case let flag as Bool: names = flag ? [] : ["(off)"]
            default: names = []
            }
            c.exceptions.append(names.isEmpty ? what : "\(what): \(names.joined(separator: ", "))")
        }
        c.privateCount = entitlements.keys.filter { $0.hasPrefix("com.apple.private.") }.count
        c.gaps = gaps(entitlements, c)
        c.secrets = secretGaps(entitlements, c)
        c.secretsOnlyIfPicked = c.sandboxed
            && ["files.user-selected.read-only", "files.user-selected.read-write"].contains { (entitlements["com.apple.security." + $0] as? Bool) == true }
        if c.sandboxed {
            if let bundleId { c.storage.append("~/Library/Containers/\(bundleId)") }
            c.storage += c.groups.map { "~/Library/Group Containers/\($0)" }
            func paths(_ key: String) -> [String] {
                let value = entitlements["com.apple.security.temporary-exception." + key]
                return (value as? [String]) ?? (value as? String).map { [$0] } ?? []
            }
            c.storage += paths("files.home-relative-path.read-write").map { "~" + ($0.hasPrefix("/") ? $0 : "/" + $0) }
            c.storage += paths("files.absolute-path.read-write")
        }
        return c
    }
}
