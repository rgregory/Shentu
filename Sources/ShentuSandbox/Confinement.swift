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
