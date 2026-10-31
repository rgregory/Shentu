import Foundation
import Testing
@testable import ShentuCore
@testable import ShentuSandbox

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

    /// Another app bundle with the probe inside, whose Info.plist says what the app wants to
    /// be called. Returns the bundle path.
    func bundle(_ folder: String, name: String, id: String) throws -> String {
        let path = "\(dir)/\(folder).app"
        try FileManager.default.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: app + "/Contents/MacOS/Dummy", toPath: path + "/Contents/MacOS/Dummy")
        let plist = ["CFBundleExecutable": "Dummy", "CFBundleIdentifier": id, "CFBundleName": name,
                     "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        return path
    }

    func env() -> ShentuEnvironment {
        ShentuEnvironment(home: home, dataRoot: URL(fileURLWithPath: dir + "/data"),
                           logsRoot: URL(fileURLWithPath: dir + "/logs"), userTempRoot: nil)
    }

    /// The profile Shentu.launch would use for this choice, with `scratch` as the run's temp folder.
    func profile(_ choice: LaunchChoice, app: String? = nil) throws -> String {
        let text = SBPLCompiler(environment: env()).restrictedProfile(try ResolvedTarget.resolve(app ?? self.app), choice.sandbox, scratch: scratch)
        #expect(SBPLCompiler.validate(text) == nil)
        return text
    }

    /// Runs one probe step under the profile; true if it worked.
    func can(_ profile: String, _ step: String...) throws -> Bool {
        try can(profile, as: app + "/Contents/MacOS/Dummy", step)
    }

    /// The same, for another bundle's copy of the probe.
    func can(_ profile: String, as executable: String, _ step: [String]) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", profile, executable] + step
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
        #expect(blocked.logURL != ok.logURL && blocked.profileURL != ok.profileURL, "own log and profile every run, even in the same second")
        for url in [ok.logURL, ok.profileURL, blocked.logURL, blocked.profileURL] {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) kept")
        }
    }

    /// Read & Write: files of that kind can be created and changed in home and on drives, and
    /// nothing else can: other kinds, places outside home and drives, or the sanity set.
    @Test func writesOnlyTheChosenKinds() throws {
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        let rw = try profile(LaunchChoice(kinds: [.image], writeKinds: [.movie]))
        #expect(try can(rw, "write", home + "/Movies/new.mp4"), "a movie in home")
        #expect(try can(rw, "write", home + "/Movies/clip.mp4"), "changing an existing movie")
        #expect(try can(rw, "read", home + "/Movies/clip.mp4"), "writable kinds are readable too")
        #expect(try can(rw, "write", drive + "/new.mp4"), "a movie on a drive")
        #expect(try can(rw, "read", home + "/Pictures/photo.jpg"), "control: the read-only kind reads")
        #expect(try !can(rw, "write", home + "/Pictures/new.jpg"), "not the read-only kind")
        #expect(try !can(rw, "write", home + "/Documents/new.txt"), "not an unchosen kind")
        #expect(try !can(rw, "write", dir + "/outside.mp4"), "not outside home and drives")
        #expect(try !can(rw, "write", home + "/.ssh/stolen.mp4"), "not in the sanity set")
        let rule = try #require(rw.split(separator: "\n").first { $0.hasPrefix("(allow file-write* (require-all (regex") })
        #expect(try !can(try without(String(rule), rw), "write", home + "/Movies/new2.mp4"),
                "mutation: without the rule, no movie is written")
        #expect(try !can(try profile(LaunchChoice(kinds: [.movie])), "write", home + "/Movies/new3.mp4"), "Read alone doesn't write")
    }

    /// The app's name and bundle ID come from its own Info.plist. Neither may open another
    /// app's data or anything in the sanity set, even with "keep its settings" on.
    @Test func appNamesCantReachOtherData() throws {
        let fm = FileManager.default
        let slackData = home + "/Library/Application Support/Slack"
        try fm.createDirectory(atPath: slackData, withIntermediateDirectories: true)
        try "token".write(toFile: slackData + "/session", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        try "key".write(toFile: home + "/.ssh/id_test", atomically: true, encoding: .utf8)
        let keep = LaunchChoice(keepSettings: true)

        let slack = try bundle("NotSlack", name: "Slack", id: "com.example.notslack-\(tag)")
        let exe = slack + "/Contents/MacOS/Dummy"
        let ownFolder = "\(home)/Library/Application Support/com.example.notslack-\(tag)"
        try fm.createDirectory(atPath: ownFolder, withIntermediateDirectories: true)
        let named = try profile(keep, app: slack)
        #expect(try can(named, as: exe, ["write", ownFolder + "/settings"]), "control: its own folder, by bundle ID")
        #expect(try !can(named, as: exe, ["read", slackData + "/session"]), "calling itself Slack doesn't open Slack's data")
        // The sanity set is last, so the last mention of Slack's folder is its deny.
        var mutated = named
        mutated.removeSubrange(try #require(named.range(of: "\n    (subpath \"\(slackData)\")", options: .backwards)))
        #expect(try can(mutated, as: exe, ["read", slackData + "/session"]), "mutation: the sanity set's Slack rule is what blocks it")

        let sneaky = try bundle("Sneaky", name: "../../.ssh", id: "../../.ssh")
        let sneakyProfile = try profile(keep, app: sneaky)
        #expect(!sneakyProfile.split(separator: "\n").contains { $0.contains("(subpath") && $0.contains("..") },
                "no path built from a name with ..")
        #expect(try !can(sneakyProfile, as: sneaky + "/Contents/MacOS/Dummy", ["read", home + "/.ssh/id_test"]),
                "a name with .. doesn't reach ~/.ssh")
        let injector = try bundle("Injector", name: "X\n(allow default)\n", id: "com.example.injector-\(tag)")
        let injected = try profile(keep, app: injector)
        #expect(!injected.contains("\n(allow default)"), "a newline in the name can't start a rule")
        #expect(RestrictedSandbox.plainName("Google/Chrome") == nil && RestrictedSandbox.plainName("..") == nil
                && RestrictedSandbox.plainName(".hidden") == nil && RestrictedSandbox.plainName("My App 2") == "My App 2")
        #expect(Hardening(environment: env()).rules().allSatisfy { $0.action == .deny }, "the sanity set has no exceptions")
    }

    /// Two runs at once, with different choices: each gets its own profile (writing a shared
    /// file let one run start under the other's profile) and its own log.
    @Test func concurrentRunsKeepTheirOwnProfile() throws {
        let (fd, port) = listener()
        defer { close(fd) }
        let results = Results()
        let group = DispatchGroup()
        let app = self.app, home = self.home, dir = self.dir
        for network in [false, true, false, true] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let env = ShentuEnvironment(home: home, dataRoot: URL(fileURLWithPath: dir + "/data"),
                                            logsRoot: URL(fileURLWithPath: dir + "/logs"), userTempRoot: nil)
                let summary = try? Shentu.launch(app, LaunchChoice(network: network), environment: env,
                                                 arguments: ["connect", port])
                results.add(network, summary)
            }
        }
        group.wait()
        let all = results.all
        #expect(all.count == 4)
        for (network, summary) in all {
            let summary = try #require(summary)
            #expect((summary.outcome.status == 0) == network, "network \(network ? "on" : "off") got its own profile")
        }
        #expect(Set(all.compactMap { $0.1?.logURL }).count == 4, "four logs")
        #expect(Set(all.compactMap { $0.1?.profileURL }).count == 4, "four profiles")
    }

    /// Reads the pid a probe helper wrote, waiting briefly for it to appear.
    func helperPID(_ path: String) throws -> pid_t {
        for _ in 0..<50 {
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            usleep(100_000)
        }
        throw ShentuError.failed("the helper never wrote its pid")
    }

    /// True once `pid` is gone (zombies are reaped by launchd within moments).
    func gone(_ pid: pid_t) -> Bool {
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { return true }
            usleep(100_000)
        }
        return false
    }

    /// Stop ends the app and everything it started, not just the app.
    @Test func stopEndsHelpersToo() throws {
        let out = dir + "/out"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let pidfile = out + "/helper.pid"
        let stop = StopHandle()
        var options = EnforceOptions(target: app)
        options.arguments = ["helper", pidfile, "sleep", "60"]
        options.control = SessionControl(stop: stop)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { stop.stop() }
        let start = Date()
        let summary = try Enforce.runRestricted(options, sandbox: RestrictedSandbox(readWrite: [out], ephemeralTemp: true),
                                                environment: env())
        #expect(summary.outcome.stoppedByShentu)
        #expect(RunEnd(summary.outcome) == .stopped)
        #expect(Date().timeIntervalSince(start) < 30, "stopped, not waited out")
        let helper = try helperPID(pidfile)
        #expect(gone(helper), "the helper was stopped too")
    }

    /// Helpers don't outlive the app when it quits by itself.
    @Test func helpersEndWithTheApp() throws {
        let out = dir + "/out2"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let pidfile = out + "/helper.pid"
        var options = EnforceOptions(target: app)
        options.arguments = ["helper", pidfile]
        options.control = SessionControl()
        let summary = try Enforce.runRestricted(options, sandbox: RestrictedSandbox(readWrite: [out], ephemeralTemp: true),
                                                environment: env())
        #expect(summary.outcome.status == 0)
        let helper = try helperPID(pidfile)
        #expect(gone(helper), "the helper ended with the app")
    }

    /// The output folder: the one place it writes that survives the run. Readable too, and
    /// the sanity set still applies inside it.
    @Test func outputFolderKeepsItsWork() throws {
        let out = home + "/Out"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let choice = LaunchChoice(outputFolder: out)
        let p = try profile(choice)
        #expect(try can(p, "write", out + "/result.txt"), "writes in the output folder")
        #expect(try can(p, "read", out + "/result.txt"), "and reads it back")
        #expect(try !can(p, "write", home + "/Documents/new.txt"), "nowhere else in home")
        #expect(try !can(p, "write", out + "/.env"), "the sanity set still applies inside it")
        #expect(try !can(try without("(allow file-write* (subpath \"\(out)\"))", p), "write", out + "/again.txt"),
                "mutation: the folder's rule is what allows it")

        let run = try Shentu.launch(app, choice, environment: env(), arguments: ["write", out + "/kept.txt"])
        #expect(RunEnd(run.outcome) == .quit)
        #expect(FileManager.default.fileExists(atPath: out + "/kept.txt"), "kept after the app quit")
    }

    /// "Only these": just the picked files and folders, read-only; file kinds don't count.
    @Test func onlyThePickedItems() throws {
        let choice = LaunchChoice(kinds: [.movie], mode: .items,
                                  readPaths: [home + "/Documents/private.txt", home + "/Pictures"])
        let p = try profile(choice)
        #expect(try can(p, "read", home + "/Documents/private.txt"), "a picked file")
        #expect(try can(p, "read", home + "/Pictures/photo.jpg"), "inside a picked folder")
        #expect(try !can(p, "read", home + "/Movies/clip.mp4"), "file kinds are off in this mode")
        #expect(try !can(p, "write", home + "/Pictures/new.jpg"), "read-only")
        #expect(try !can(try without("\n    (subpath \"\(home)/Pictures\")", p), "read", home + "/Pictures/photo.jpg"),
                "mutation: the folder's rule is what allows it")
    }

    /// What can be picked: something inside home or on a drive, never home, a drive, ~/Library,
    /// or a protected place. Checked again at launch.
    @Test func picksAreChecked() throws {
        let fm = FileManager.default
        for d in ["/Library/Foo", "/.ssh", "/Out"] { try fm.createDirectory(atPath: home + d, withIntermediateDirectories: true) }
        try fm.createDirectory(atPath: drive + "/sub", withIntermediateDirectories: true)
        func problem(_ path: String) -> String? { LaunchChoice.problem(with: path, environment: env()) }
        #expect(problem(home + "/Out") == nil)
        #expect(problem(home + "/Documents/private.txt") == nil)
        #expect(problem(drive + "/sub") == nil)
        for bad in ["/", home, home + "/Library", home + "/Library/Foo", home + "/.ssh", "/Applications", drive,
                    home + "/missing"] {
            #expect(problem(bad) != nil, "\(bad)")
        }
        #expect(throws: (any Error).self, "a bad remembered folder is refused at launch") {
            try Shentu.launch(app, LaunchChoice(outputFolder: home), environment: env(), arguments: [])
        }
    }

    /// How a run ended: quit, an error exit, a crash; and the app's start is reported.
    @Test func runEnds() throws {
        let started = Results()
        let ok = try Shentu.launch(app, LaunchChoice(), environment: env(), arguments: ["tmp"],
                                   onLaunch: { _ in started.add(true, nil) })
        #expect(RunEnd(ok.outcome) == .quit)
        #expect(started.all.count == 1, "onLaunch was called")
        let failed = try Shentu.launch(app, LaunchChoice(), environment: env(), arguments: ["write", dir + "/outside.txt"])
        #expect(RunEnd(failed.outcome) == .exited(1))
        #expect(RunEnd(failed.outcome).isProblem)
        let crashed = try Shentu.launch(app, LaunchChoice(), environment: env(), arguments: ["crash"])
        #expect(RunEnd(crashed.outcome) == .crashed(SIGABRT))
        #expect(RunEnd(crashed.outcome).title.contains("SIGABRT"))

        // The blocked write shows up in the activity log, under Files.
        let activity = ActivityLog.load(failed.logURL)
        let item = try #require(activity.items.first { $0.target.hasSuffix("outside.txt") })
        #expect(item.group == .files && item.operation.hasPrefix("file-write"))
    }

    /// Grouping, counting, search and CSV export of blocked requests.
    @Test func activityLog() {
        func record(_ op: String, _ target: String, _ verdict: Verdict = .deny, count: Int = 1, process: String = "App") -> EnforceRecord {
            EnforceRecord(ts: Date(), runId: "r", pid: 1, process: process, verdict: verdict, operation: op,
                          target: target, category: "denied", count: count)
        }
        var log = ActivityLog()
        log.add(record("file-read-data", "~/Documents/a.txt"))
        log.add(record("file-read-data", "~/Documents/a.txt", count: 3, process: "Helper"))
        log.add(record("network-outbound", "1.2.3.4:443"))
        log.add(record("mach-lookup", "com.example.service"))
        log.add(record("process-exec*", "/bin/sh"))
        log.add(record("file-read-data", "~/x", .allow))
        #expect(log.items.count == 4, "allowed reports are ignored; repeats merge")
        #expect(log.total() == 7 && log.total(.files) == 4 && log.total(.network) == 1)
        #expect(log.total(.services) == 1 && log.total(.programs) == 1)
        let a = log.items.first { $0.target == "~/Documents/a.txt" }
        #expect(a?.processes == ["App", "Helper"])
        #expect(log.items(in: nil, matching: "DOCUMENTS").count == 1, "search ignores case")
        #expect(log.items(in: .network, matching: "").count == 1)
        #expect(log.items(in: nil, matching: "helper").count == 1, "search covers processes")
        #expect(log.items(in: nil, matching: "").first?.count == 4, "most frequent first")

        let csv = ActivityLog.csv([ActivityItem(group: .files, operation: "file-read-data", target: "=cmd \"x\"", count: 2,
                                                processes: ["App"], first: Date(), last: Date())])
        #expect(csv.hasPrefix("group,operation,target,count,processes,first,last\n"))
        #expect(csv.contains("\"'=cmd \"\"x\"\"\""), "quoted, quotes doubled, formula defused: \(csv)")
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
        let choice = LaunchChoice(network: true, kinds: [.image], writeKinds: [.text], keepSettings: true)
        remembered.save(choice, for: "x")
        #expect(RememberedChoices(env()).choice(for: "x") == choice)
        #expect(choice.access(.image) == .read && choice.access(.text) == .readWrite && choice.access(.movie) == .off)
        // Choices saved before Read & Write existed still load.
        let old = try JSONDecoder().decode(LaunchChoice.self, from: Data(#"{"network":true,"kinds":["movie"],"keepSettings":false}"#.utf8))
        #expect(old == LaunchChoice(network: true, kinds: [.movie]))
    }
}

/// Collects results from concurrent runs.
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Bool, EnforceSummary?)] = []
    func add(_ network: Bool, _ summary: EnforceSummary?) { lock.withLock { items.append((network, summary)) } }
    var all: [(Bool, EnforceSummary?)] { lock.withLock { items } }
}
