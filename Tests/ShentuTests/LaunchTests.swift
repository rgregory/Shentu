import Foundation
import Testing
@testable import ShentuCore

/// Each pop-up option, checked by the kernel: a self-built dummy app (never a real one) runs
/// under the profile Shentu builds for a choice and tries each step. Every must-fail group has
/// a must-succeed control in the same profile, and a mutation (the option flipped, or its rule
/// cut from the profile) that makes the must-fail step succeed.
@Suite(.serialized) final class LaunchTests {
    let dir = "/private/tmp/shentu-test-\(UUID().uuidString)"
    let tag = UUID().uuidString.prefix(8)
    var home: String { dir + "/home" }
    var app: String { dir + "/Dummy.app" }
    var bundleId: String { "com.example.shentu-dummy-\(tag)" }
    /// Stands in for the run's temp folder when the profile is used without Shentu.launch.
    var scratch: String { dir + "/shentu-run-test" }
    var drive = ""

    init() throws {
        let fm = FileManager.default
        for d in ["/home/Movies", "/home/Pictures", "/home/Documents", "/home/Library/Application Support",
                  "/Dummy.app/Contents/MacOS", "/shentu-run-test"] {
            try fm.createDirectory(atPath: dir + d, withIntermediateDirectories: true)
        }
        for f in ["Movies/clip.mp4", "Pictures/photo.jpg", "Documents/private.txt"] {
            try "x".write(toFile: "\(home)/\(f)", atomically: true, encoding: .utf8)
        }
        let source = try #require(Bundle.module.url(forResource: "shentuprobe", withExtension: "c", subdirectory: "Fixtures"))
        #expect(sh("/usr/bin/cc", ["-o", app + "/Contents/MacOS/Dummy", source.path]) == 0)
        let plist = ["CFBundleExecutable": "Dummy", "CFBundleIdentifier": bundleId, "CFBundleName": "Dummy",
                     "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))

        // A real external drive: a small disk image, mounted under /Volumes like a USB stick.
        let image = dir + "/drive.dmg", name = "ShentuTest-\(tag)"
        #expect(sh("/usr/bin/hdiutil", ["create", "-quiet", "-size", "4m", "-fs", "HFS+", "-volname", name, image]) == 0)
        #expect(sh("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", image]) == 0)
        drive = "/Volumes/" + name
        try #require(fm.fileExists(atPath: drive))
        for f in ["clip.mp4", "notes.txt"] {
            try "x".write(toFile: "\(drive)/\(f)", atomically: true, encoding: .utf8)
        }
    }

    deinit {
        if !drive.isEmpty { sh("/usr/bin/hdiutil", ["detach", drive, "-force"]) }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Runs a tool and returns its exit status.
    @discardableResult func sh(_ tool: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    func env() -> ShentuEnvironment {
        ShentuEnvironment(home: home, dataRoot: URL(fileURLWithPath: dir + "/data"),
                           logsRoot: URL(fileURLWithPath: dir + "/logs"), userTempRoot: nil)
    }

    /// The profile Shentu.launch would use for this choice, with `scratch` as the run's temp folder.
    func profile(_ choice: LaunchChoice) throws -> String {
        let text = SBPLCompiler(environment: env()).restrictedProfile(try ResolvedTarget.resolve(app), choice.sandbox, scratch: scratch)
        #expect(SBPLCompiler.validate(text) == nil)
        return text
    }

    /// Runs one probe step under the profile; true if it worked.
    func can(_ profile: String, _ step: String...) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", profile, app + "/Contents/MacOS/Dummy"] + step
        p.environment = ["TMPDIR": scratch + "/"]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Cuts one rule from a profile, failing loudly if it isn't there (a mutation that changes
    /// nothing would prove nothing).
    func without(_ rule: String, _ profile: String) throws -> String {
        try #require(profile.contains(rule), "rule not in profile: \(rule)")
        return profile.replacingOccurrences(of: rule, with: "")
    }

    /// A listening socket on localhost; returns (fd, port).
    func listener() -> (Int32, String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        listen(fd, 4)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, String(UInt16(bigEndian: addr.sin_port)))
    }

    @Test func network() throws {
        let (fd, port) = listener()
        defer { close(fd) }
        #expect(try can("(version 1)(allow default)", "connect", port), "control: the connection works unsandboxed")
        let off = try profile(LaunchChoice())
        #expect(try can(off, "write", scratch + "/f"), "control: the app runs and writes its temp folder")
        #expect(try !can(off, "connect", port), "no network")
        #expect(try can(try profile(LaunchChoice(network: true)), "connect", port), "network on")
        #expect(try can(try without("(deny network-outbound (remote ip))", off), "connect", port), "mutation: the rule is what blocks it")
    }

    @Test func writesOnlyToTheRunsTempFolder() throws {
        let strict = try profile(LaunchChoice(kinds: [.movie]))
        #expect(try can(strict, "write", scratch + "/f"), "the run's temp folder")
        #expect(try can(strict, "tmp"), "TMPDIR, which is the run's temp folder")
        #expect(try !can(strict, "write", dir + "/outside.txt"), "the shared /private/tmp")
        #expect(try !can(strict, "write", home + "/Documents/new.txt"), "home")
        #expect(try !can(strict, "write", home + "/Movies/new.mp4"), "home, even a type it can read")
        #expect(try !can(strict, "write", drive + "/new.txt"), "drives")
        #expect(try can(try without("(deny file-write* (subpath \"/\"))", strict), "write", dir + "/outside.txt"),
                "mutation: the rule is what blocks it")
    }

    @Test func readsOnlyTheChosenKinds() throws {
        let media = try profile(LaunchChoice(kinds: [.movie]))
        #expect(try can(media, "read", home + "/Movies/clip.mp4"), "media in home")
        #expect(try can(media, "read", drive + "/clip.mp4"), "media on a drive")
        #expect(try can(media, "read", app + "/Contents/Info.plist"), "its own bundle")
        #expect(try can(media, "read", "/System/Library/CoreServices/SystemVersion.plist"), "system files")
        #expect(try !can(media, "read", home + "/Documents/private.txt"), "a document in home")
        #expect(try !can(media, "read", home + "/Pictures/photo.jpg"), "an image in home")
        #expect(try !can(media, "read", drive + "/notes.txt"), "a document on a drive")

        let images = try profile(LaunchChoice(kinds: [.image]))
        #expect(try can(images, "read", home + "/Pictures/photo.jpg"), "images when chosen")
        #expect(try !can(images, "read", home + "/Movies/clip.mp4"), "then not media")
        #expect(try can(try profile(LaunchChoice(kinds: [.text])), "read", home + "/Documents/private.txt"), "text when chosen")

        #expect(try !can(try profile(LaunchChoice()), "read", home + "/Movies/clip.mp4"), "nothing chosen, nothing read")
        let homeDeny = "(deny file-read* file-write*\n    (subpath \"\(home)\")"
        try #require(media.contains(homeDeny))
        #expect(try can(media.replacingOccurrences(of: homeDeny, with: "(deny file-read* file-write*\n    (subpath \"/nonexistent\")"),
                        "read", home + "/Documents/private.txt"), "mutation: the home rule is what blocks it")
        #expect(try can(try profile(LaunchChoice(kinds: [.movie])).replacingOccurrences(of: "(subpath \"/Volumes\")", with: "(subpath \"/nonexistent\")"),
                        "read", drive + "/notes.txt"), "mutation: the drives rule is what blocks it")
    }

    @Test func keepSettings() throws {
        let folder = "\(home)/Library/Application Support/\(bundleId)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let fresh = try profile(LaunchChoice())
        #expect(try can(fresh, "write", scratch + "/f"), "control: its temp folder")
        #expect(try !can(fresh, "write", folder + "/settings"), "starts fresh: its own data closed")
        #expect(try can(try profile(LaunchChoice(keepSettings: true)), "write", folder + "/settings"), "keep settings: its own data open")
    }

    @Test func noOtherPrograms() throws {
        let strict = try profile(LaunchChoice(network: true, kinds: FileKind.allCases, keepSettings: true))
        #expect(try can(strict, "write", scratch + "/f"), "control: the app itself runs")
        #expect(try !can(strict, "exec"), "even with every option on, no other programs")
        #expect(try can(try without("(deny process-exec* (subpath \"/\"))", strict), "exec"), "mutation: the rule is what blocks it")
    }

    /// The real launch path (log tap, temp folder, launch, cleanup): the app gets its own TMPDIR,
    /// can write there and nowhere else, and the folder is gone when it quits.
    @Test func launchMakesAndRemovesTheTempFolder() throws {
        let ok = try Shentu.launch(app, LaunchChoice(), environment: env(), arguments: ["tmp"])
        #expect(ok.outcome.status == 0, "TMPDIR is the run's own folder and writable")
        let folder = try #require(ok.tempFolder)
        #expect(folder.hasPrefix("/private/tmp/shentu-run-"), "\(folder)")
        #expect(!FileManager.default.fileExists(atPath: folder), "deleted when the app quit")

        let blocked = try Shentu.launch(app, LaunchChoice(), environment: env(), arguments: ["tmp", "write", dir + "/outside.txt"])
        #expect(blocked.outcome.status == 1, "one step fails: the write outside its temp folder")
        #expect(blocked.tempFolder != ok.tempFolder, "a fresh folder every run")
    }

    /// Finder's kinds as macOS classifies them here, and none lets code or private keys through.
    @Test func kindsMatchFinder() {
        #expect(FileKind.movie.extensions.contains("mp4") && !FileKind.movie.extensions.contains("mp3"))
        #expect(FileKind.music.extensions.contains("mp3"))
        #expect(FileKind.pdf.extensions == ["pdf"])
        #expect(FileKind.text.extensions.contains("txt") && !FileKind.text.extensions.contains("pdf"))
        #expect(FileKind.document.extensions.contains("docx") && !FileKind.document.extensions.contains("pptx"))
        #expect(FileKind.presentation.extensions.contains("pptx"))
        #expect(FileKind.archive.extensions.contains("zip"))
        #expect(FileKind.image.extensions.contains("jpg"))
        let all = Set(FileKind.allCases.flatMap(\.extensions))
        #expect(all.isDisjoint(with: ["key", "ts", "sh", "py", "json", "env", "pem"]), "\(all.sorted())")
        for kind in FileKind.allCases { #expect(!kind.extensions.isEmpty, "\(kind)") }
    }

    @Test func choicesAreRemembered() throws {
        let remembered = RememberedChoices(env())
        #expect(remembered.choice(for: "x") == LaunchChoice(), "strict default for a new app")
        let choice = LaunchChoice(network: true, kinds: [.image], keepSettings: true)
        remembered.save(choice, for: "x")
        #expect(RememberedChoices(env()).choice(for: "x") == choice)
    }
}
