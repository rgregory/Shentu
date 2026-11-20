import AppKit
import ShentuCore
import SwiftUI
import UniformTypeIdentifiers

// UI state lives in @Observable models and views take bindings from
// `Binding(get:set:)`: SwiftUI's @State needs a compiler plugin the Command Line Tools lack.

/// Apps dropped on the Dock icon (or opened with Shentu) arrive here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store?
    func application(_ application: NSApplication, open urls: [URL]) {
        store?.dropped(urls)
    }

    /// Quitting Shentu ends every run it is supervising. Without this the app outlives Shentu:
    /// still confined, since the profile is the kernel's, but with nothing watching it, no Stop
    /// to reach for, and its temp folder never deleted.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        let active = store.runs.filter { $0.state.isActive }
        guard !active.isEmpty else { return .terminateNow }
        active.forEach { $0.stop.stop() }
        // Hold the quit open while they end, so each run's own cleanup removes its temp folder.
        // Runner escalates to SIGKILL after five seconds. Wait for its completion and the
        // session's log drain and cleanup rather than racing that escalation with a quit timer.
        waitForRuns(store, sender: sender)
        return .terminateLater
    }

    private func waitForRuns(_ store: Store, sender: NSApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, store.runs.contains(where: { $0.state.isActive }) else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            self.waitForRuns(store, sender: sender)
        }
    }
}

@main
struct ShentuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let store = Store()

    init() {
        // Also behave like a regular app when started as a bare executable (`swift run`).
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("Shentu") {
            // Just the drop zone until something runs (and no sheet is up, so a sheet can grow
            // the window instead of being clipped): the content is then exactly its own
            // height, and .contentSize holds the window to it, even over a taller size macOS
            // saved from an earlier launch. The first run's list makes it at least 440 tall.
            MainView(store: store)
                .frame(minWidth: 480, minHeight: store.runs.isEmpty ? nil : 440)
                .fixedSize(horizontal: false, vertical: store.runs.isEmpty && store.pending == nil && store.inspecting == nil)
                .lookWindow()
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 480, height: 280)
        .windowResizability(.contentSize)
    }
}

/// An app Shentu can't wrap (already in Apple's App Sandbox, or Apple's own), shown with the
/// restrictions its own signature puts on it.
struct Inspected: Identifiable {
    let id = UUID()
    let name: String
    let problem: String
    let confinement: Confinement
}

/// One app dropped and waiting for its options.
struct Pending: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let key: String
    var choice: LaunchChoice
    /// Why the last file or folder picked can't be used.
    var problem: String?
}

/// Where a run is.
enum RunState: Equatable {
    case starting
    case running
    case ended(RunEnd)
    /// Never started: the profile didn't load, the app couldn't be resolved, a picked folder
    /// was refused, …
    case failed(String)

    var title: String {
        switch self {
        case .starting: return "Starting…"
        case .running: return "Running"
        case .ended(let end): return end.title
        case .failed(let why): return "Launch failed: \(why)"
        }
    }

    var symbol: String {
        switch self {
        case .starting: return "hourglass"
        case .running: return "circle.fill"
        case .ended(.quit): return "checkmark.circle"
        case .ended(.stopped): return "stop.circle"
        case .ended: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .starting: return .secondary
        case .running: return .green
        case .ended(let end): return end.isProblem ? .red : .secondary
        case .failed: return .red
        }
    }

    var isActive: Bool { self == .starting || self == .running }
}

/// One launch, running or finished. Only changed on the main thread (the launch thread hops
/// there), hence unchecked.
@Observable final class Run: Identifiable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let summary: String
    let outputFolder: String?
    let stop = StopHandle()
    var state = RunState.starting
    let startedAt = Date()
    /// When it ended (or failed to start): the heart monitor freezes there.
    var endedAt: Date?
    /// Where the pointer is over each heart monitor (the run's row, its activity viewer).
    let rowHover = Hover()
    let viewerHover = Hover()
    var activity = ActivityLog()
    var logURL: URL?
    /// nil until the run ends; false if blocked requests may be missing from the log.
    var logComplete: Bool?
    // The activity viewer's filter.
    var search = ""
    var group: ActivityGroup?
    var showBackground = false

    init(name: String, summary: String, outputFolder: String?) {
        self.name = name
        self.summary = summary
        self.outputFolder = outputFolder
    }
}

@Observable final class Store {
    let environment = Shentu.environment()
    var pending: Pending?
    var runs: [Run] = []
    var message: String?
    /// The run whose activity viewer is open.
    var viewing: Run?
    /// An app that can't be wrapped, shown with its own restrictions.
    var inspecting: Inspected?
    /// Whether the pop-up's Advanced section is open. Kept here, not in the Pending choice:
    /// it is how the pop-up is being looked at, not part of what is remembered for the app.
    var showAdvanced = false

    func dropped(_ urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == "app" }) else {
            message = "Drop a Mac app (a .app) on Shentu."
            return
        }
        do {
            let target = try ResolvedTarget.resolve(url.path)
            switch target.wrapStatus {
            case .alreadySandboxed, .appleApp:
                // Can't be wrapped, but its own signature says how it's confined: show that.
                inspecting = Inspected(name: target.identity.name,
                                       problem: target.wrapStatus.problem(name: target.identity.name) ?? "",
                                       confinement: target.confinement)
                return
            case .wrappable, .unavailable:
                break
            }
            try target.preflight()
            let key = target.identity.choiceKey
            pending = Pending(path: url.path, name: target.identity.name, key: key,
                              choice: RememberedChoices(environment).choice(for: key))
        } catch {
            message = "\(url.deletingPathExtension().lastPathComponent) can't run in Shentu: \(error)"
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { dropped([url]) }
    }

    /// Picks files and folders the pending app may read ("Only these").
    func addReadItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Allow Reading"
        panel.message = "Choose the files and folders it can read. Everything else in your home folder stays closed."
        guard panel.runModal() == .OK else { return }
        pending?.problem = nil
        for url in panel.urls {
            if let problem = LaunchChoice.problem(with: url.path, environment: environment) {
                pending?.problem = problem
            } else if pending?.choice.readPaths.contains(url.path) == false {
                pending?.choice.readPaths.append(url.path)
            }
        }
    }

    /// Picks the one folder the pending app may write to.
    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Allow Changes"
        panel.message = "The app will be able to read, change and delete anything in this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = LaunchChoice.problem(with: url.path, environment: environment) {
            pending?.problem = problem
        } else {
            pending?.problem = nil
            pending?.choice.outputFolder = url.path
        }
    }

    func launch(_ item: Pending) {
        pending = nil
        RememberedChoices(environment).save(item.choice, for: item.key)
        let run = Run(name: item.name, summary: Self.describe(item.choice, environment),
                      outputFolder: item.choice.outputFolder)
        runs.insert(run, at: 0)
        let env = environment
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try Shentu.launch(item.path, item.choice, environment: env, stop: run.stop,
                    onLaunch: { _ in DispatchQueue.main.async { run.state = .running } },
                    onRecord: { record in DispatchQueue.main.async { run.activity.add(record) } },
                    say: { line in
                        guard line.hasPrefix("log: ") else { return }
                        DispatchQueue.main.async { run.logURL = URL(fileURLWithPath: String(line.dropFirst(5))) }
                    })
                DispatchQueue.main.async {
                    run.state = .ended(RunEnd(summary.outcome))
                    run.endedAt = Date()
                    run.logURL = summary.logURL
                    run.logComplete = summary.logComplete
                }
            } catch {
                DispatchQueue.main.async {
                    run.state = .failed("\(error)")
                    run.endedAt = Date()
                }
            }
        }
    }

    static func describe(_ choice: LaunchChoice, _ environment: ShentuEnvironment) -> String {
        var parts = [choice.network ? "Network on" : "No network"]
        switch choice.mode {
        case .kinds:
            let read = FileKind.allCases.filter { choice.access($0) == .read }.map(\.title)
            let written = choice.writableKinds.map(\.title)
            if read.isEmpty && written.isEmpty { parts.append("reads none of your files") }
            if !read.isEmpty { parts.append("reads " + read.joined(separator: ", ")) }
            if !written.isEmpty { parts.append("reads & writes " + written.joined(separator: ", ")) }
        case .items:
            let n = choice.readPaths.count
            parts.append(n == 0 ? "reads none of your files" : "reads \(n) item\(n == 1 ? "" : "s") you picked")
        }
        if let out = choice.outputFolder { parts.append("writes to \(environment.abbreviate(out))") }
        if choice.clipboard { parts.append("clipboard") }
        parts.append(choice.keepSettings ? "keeps isolated data" : "no saved-data access")
        return parts.joined(separator: " · ")
    }
}

struct MainView: View {
    let store: Store

    /// "Shentu 0.2.0 (build 61, a1b2c3d)" from the bundle's Info.plist (scripts/build-app.sh);
    /// "Shentu (development)" when run with `swift run`.
    static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String else { return "Shentu (development)" }
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["ShentuCommit"] as? String
        return "Shentu \(short) (build \(build)\(commit.map { ", \($0)" } ?? ""))"
    }()

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                DropZone(store: store)
                Text(Self.version).font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
            }
            .sheet(item: Binding(get: { store.pending }, set: { store.pending = $0 })) { item in
                OptionsView(store: store, item: item)
            }
            if !store.runs.isEmpty {
                List(store.runs) { RunRow(store: store, run: $0).listRowBackground(Look.panel) }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .lookPanel(padding: 4)
                    .sheet(item: Binding(get: { store.viewing }, set: { store.viewing = $0 })) { run in
                        ActivityView(store: store, run: run)
                    }
            }
        }
        .padding(20)
        .frame(maxHeight: store.runs.isEmpty ? nil : .infinity, alignment: .top)
        .sheet(item: Binding(get: { store.inspecting }, set: { store.inspecting = $0 })) { item in
            ConfinementView(store: store, item: item)
        }
        .alert("Shentu", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.message ?? "")
        }
    }
}

struct DropZone: View {
    let store: Store

    var body: some View {
        VStack(spacing: 10) {
            // The app's own icon (assets/AppIcon.png, from icon.jpg).
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Drop a Mac app here").font(Look.font(.title3))
            Text("You choose what it can reach, then it opens in a sandbox.")
                .font(Look.font(.callout)).foregroundStyle(.secondary)
            Button("Choose an App…") { store.choose() }
                .buttonStyle(LookButtonStyle(isDefault: true))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .lookPanel(padding: 0)
        .dropDestination(for: URL.self) { urls, _ in
            store.dropped(urls)
            return true
        }
    }
}

/// An app Shentu can't wrap: why, and the restrictions its own signature already gives it.
struct ConfinementView: View {
    let store: Store
    let item: Inspected

    var body: some View {
        let c = item.confinement
        VStack(alignment: .leading, spacing: 14) {
            Text("\(item.name) can't run in Shentu").lookHeader()
            Text(item.problem)
                .font(Look.font(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Label(c.sandboxed ? "In Apple's App Sandbox" : "Not in Apple's App Sandbox: no restrictions of its own",
                      systemImage: c.sandboxed ? "lock.fill" : "lock.open")
                    .foregroundStyle(c.sandboxed ? Look.text : Color.orange)
                Label(c.hardenedRuntime ? "Hardened Runtime" : "No Hardened Runtime",
                      systemImage: c.hardenedRuntime ? "checkmark.shield" : "shield.slash")
                    .foregroundStyle(c.hardenedRuntime ? Look.text : Color.orange)
            }

            if c.sandboxed {
                // One row per area: what it may (✓) and what its sandbox keeps from it (✕).
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(c.areas, id: \.name) { area in
                        GridRow {
                            Text(area.name).font(Look.font(.headline))
                            VStack(alignment: .leading, spacing: 2) {
                                if !area.allowed.isEmpty {
                                    Text("✓  " + area.allowed.joined(separator: ", "))
                                }
                                if !area.denied.isEmpty {
                                    Text("✕  " + area.denied.joined(separator: ", ")).foregroundStyle(.secondary)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if c.sandboxed {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Where it keeps its data:").font(Look.font(.headline))
                    ForEach(c.storage, id: \.self) { path in
                        let full = store.environment.expand(path)
                        if FileManager.default.fileExists(atPath: full) {
                            Button(path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)]) }
                                .buttonStyle(.link).help("Show in Finder")
                        } else {
                            Text(path + " (not created yet)").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Label("Not sandboxed, so it can keep data anywhere you can write.", systemImage: "externaldrive")
                    .foregroundStyle(.orange)
            }
            // Exceptions, runtime relaxations, app groups and private entitlements all show up
            // here, as what they open up.
            // Secrets on their own: one clear answer, then the gaps that remain.
            VStack(alignment: .leading, spacing: 5) {
                Text("Your secrets (SSH keys, .env files, cloud credentials, password stores, shell history):")
                    .font(Look.font(.headline)).fixedSize(horizontal: false, vertical: true)
                if c.secrets.isEmpty {
                    Label(c.secretsOnlyIfPicked ? "Out of its reach, unless you pick one yourself in an Open panel."
                                                : "Out of its reach.", systemImage: "key.fill")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(red: 0.1, green: 0.5, blue: 0.2))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    gapList(c.secrets)
                }
            }
            if !c.gaps.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Other gaps:").font(Look.font(.headline))
                    // Dark text for contrast; the icon carries the severity, and the serious
                    // ones are bold.
                    gapList(c.gaps)
                }
            }
            Text("From its code signature. Some of these also ask you first (camera, contacts, controlling other apps).")
                .font(Look.font(.caption)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("OK") { store.inspecting = nil }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(LookButtonStyle(isDefault: true))
            }
        }
        .padding(20)
        .frame(width: 600)
        .lookWindow()
    }

    /// Dark text for contrast; the icon carries the severity, and the serious ones are bold.
    private func gapList(_ gaps: [Confinement.Gap]) -> some View {
        ForEach(gaps, id: \.text) { gap in
            Label {
                Text(gap.text).fontWeight(gap.severity == .high ? .semibold : .regular)
                    .foregroundStyle(gap.severity == .low ? Color.secondary : Look.text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: Self.symbol(gap.severity)).foregroundStyle(Self.color(gap.severity))
            }
            .help(gap.text)
        }
    }

    static func symbol(_ severity: Confinement.Gap.Severity) -> String {
        switch severity {
        case .high: return "exclamationmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low: return "info.circle"
        }
    }

    static func color(_ severity: Confinement.Gap.Severity) -> Color {
        switch severity {
        case .high: return Color(red: 0.78, green: 0.1, blue: 0.1)
        case .medium: return Color(red: 0.85, green: 0.45, blue: 0)
        case .low: return .secondary
        }
    }

    @ViewBuilder private func section(_ title: String, _ lines: [String], color: Color = Look.text,
                                      mark: String = "•") -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Look.font(.headline))
                ForEach(lines, id: \.self) { line in
                    Text("\(mark)  " + line).foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true).help(line)
                }
            }
        }
    }
}

/// The pop-up: options for this launch.
struct OptionsView: View {
    let store: Store
    let item: Pending

    private var current: Pending { store.pending ?? item }

    private var choice: Binding<LaunchChoice> {
        Binding(get: { store.pending?.choice ?? item.choice }, set: { store.pending?.choice = $0 })
    }

    private func access(_ kind: FileKind) -> Binding<LaunchChoice.Access> {
        Binding(get: { choice.wrappedValue.access(kind) }, set: { choice.wrappedValue.set(kind, $0) })
    }

    private func short(_ path: String) -> String { store.environment.abbreviate(path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open \(item.name) in Shentu").lookHeader()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Internet and network", isOn: choice.network)
                Text(stateText(networkCaption))
                    .font(Look.font(.callout)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(networkHelp)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Clipboard", isOn: choice.clipboard)
                Text(stateText(clipboardCaption))
                    .font(Look.font(.callout)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(clipboardHelp)

            advanced

            if let problem = current.problem {
                Label(problem, systemImage: "xmark.octagon")
                    .font(Look.font(.caption)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                fact("trash", choice.wrappedValue.outputFolder == nil && choice.wrappedValue.writableKinds.isEmpty
                     ? "Saves files only to a temporary folder, deleted when it quits."
                     : "Anything else it saves goes to a temporary folder, deleted when it quits.")
                fact("powerplug", "It cannot reach other apps' sockets, such as Docker's or ssh-agent's; only the system log is open.")
                fact("nosign", "It cannot start other programs or open links.")
            }
            .font(Look.font(.callout)).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { store.pending = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(LookButtonStyle())
                Button("Open") { store.launch(current) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(LookButtonStyle(isDefault: true))
            }
        }
        .padding(20)
        .frame(width: 480)
        .lookWindow()
    }

    /// One fact about the run, whatever the choices are. Not `Label`: the symbols are different
    /// widths, so each row's text would start at a different place, and a wrapped label centres
    /// its icon against both lines instead of the first.
    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).frame(width: 16, alignment: .center)
            Text(stateText(text)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// "can" in green, "can't" and "cannot" in red, both bold: the state is then readable at a
    /// glance, without reading the sentence that carries it.
    private func stateText(_ text: String) -> AttributedString {
        var out = AttributedString()
        for (i, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { out += AttributedString(" ") }
            var piece = AttributedString(String(word))
            switch word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()")) {
            case "can":
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = Look.allowed
            case "can't", "cannot":
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = Look.blocked
            default:
                break
            }
            out += piece
        }
        return out
    }

    /// Each caption says what is true right now, then what clicking will change. "Off means\u{2026}"
    /// described the state the user was not in, so the current one had to be inferred backwards.
    private var networkCaption: String {
        choice.wrappedValue.network
            ? "It can reach the internet and your network."
            : "It cannot reach the internet or your network."
    }

    private var clipboardCaption: String {
        choice.wrappedValue.clipboard
            ? "It can read and change the clipboard."
            : "It cannot read or change the clipboard."
    }

    private var keepSettingsCaption: String {
        choice.wrappedValue.keepSettings
            ? "It can save settings between runs."
            : "It cannot save settings: every run starts fresh."
    }

    // The rest on hover: true whatever the toggle says, so it crowds the panel without
    // telling the user where they stand.
    private let networkHelp = "Servers on this Mac (localhost) count as your network. "
        + "Either state leaves other apps' Unix-domain sockets blocked \u{2014} Docker's, ssh-agent's, "
        + "any app with a socket in your home folder \u{2014} with only the system log open."
    private let clipboardHelp = "Copying and pasting inside the app, and drag and drop, may not "
        + "work either: they use the same service."
    private let keepSettingsHelp = "A separate home folder, not your real one. Shared macOS "
        + "preferences stay blocked either way, and apps that ignore the folder still can't save."

    /// What the closed Advanced section is currently allowing, in one line, so that closing it
    /// never hides a choice the user has made.
    private var advancedSummary: String {
        var parts: [String] = []
        switch choice.wrappedValue.mode {
        case .kinds:
            let read = FileKind.allCases.filter { choice.wrappedValue.access($0) == .read }.map(\.title)
            let written = choice.wrappedValue.writableKinds.map(\.title)
            if read.isEmpty && written.isEmpty { parts.append("opens none of your files") }
            if !read.isEmpty { parts.append("reads " + read.joined(separator: ", ")) }
            if !written.isEmpty { parts.append("reads & writes " + written.joined(separator: ", ")) }
        case .items:
            let n = choice.wrappedValue.readPaths.count
            parts.append(n == 0 ? "opens none of your files" : "opens \(n) item\(n == 1 ? "" : "s") you picked")
        }
        if let out = choice.wrappedValue.outputFolder { parts.append("writes to \(short(out))") }
        if choice.wrappedValue.keepSettings { parts.append("keeps its data between runs") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Files, the output folder and saved data. Closed by default: every one of them starts at
    /// the safe answer, and an app is usually dropped here to be tried, not to be set up.
    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { store.showAdvanced.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.showAdvanced ? "chevron.down" : "chevron.right")
                        .font(Look.font(.caption))
                    Text("Advanced")
                    if !store.showAdvanced {
                        Text(advancedSummary)
                            .font(Look.font(.caption)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if store.showAdvanced {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Files it can open in your home folder and on drives:")
                        Spacer()
                        LookSegmented(selection: choice.mode,
                                      options: LaunchChoice.Mode.allCases.map { ($0, $0.title) })
                            .fixedSize()
                    }
                    if choice.wrappedValue.mode == .kinds { kinds } else { items }
                }

                outputFolder

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Keep its isolated data between runs", isOn: choice.keepSettings)
                    Text(stateText(keepSettingsCaption))
                        .font(Look.font(.callout)).foregroundStyle(.secondary)
                }
                .help(keepSettingsHelp)
            }
        }
    }

    /// Off / Read / Read & Write for each of Finder's kinds.
    private var kinds: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Finder's Kind names; hover one for the exact extensions.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(FileKind.allCases, id: \.self) { kind in
                    GridRow {
                        Text(kind.title)
                            .help(kind.extensions.map { "." + $0 }.joined(separator: " "))
                        LookSegmented(selection: access(kind),
                                      options: LaunchChoice.Access.allCases.map { ($0, $0.title) })
                            .frame(width: 250)
                    }
                }
            }
            Text("Every file of a chosen kind, anywhere in your home folder and on drives. It can see file and folder names, but not other files' contents. Read & Write lets it create, change, rename and delete files of that kind; apps that save through a temporary file can't save them.")
                .font(Look.font(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Only the files and folders picked, read-only.
    private var items: some View {
        VStack(alignment: .leading, spacing: 6) {
            if choice.wrappedValue.readPaths.isEmpty {
                Text("None yet: it can't open any of your files.")
                    .foregroundStyle(.secondary)
            }
            ForEach(choice.wrappedValue.readPaths, id: \.self) { path in
                HStack {
                    Image(systemName: isFolder(path) ? "folder" : "doc")
                    Text(short(path)).lineLimit(1).truncationMode(.middle)
                        .help(path)
                    Spacer()
                    Button {
                        choice.wrappedValue.readPaths.removeAll { $0 == path }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                }
            }
            Button("Add Files or Folders…") { store.addReadItems() }
            Text("Read-only, and only these: a folder includes everything inside it. Less access than a file kind, which opens every matching file you have.")
                .font(Look.font(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The one folder it can write to, kept after it quits.
    private var outputFolder: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output folder:")
                if let out = choice.wrappedValue.outputFolder {
                    Image(systemName: "folder")
                    Text(short(out)).lineLimit(1).truncationMode(.middle).help(out)
                    Spacer()
                    Button("Change…") { store.chooseOutputFolder() }
                    Button("Remove") { choice.wrappedValue.outputFolder = nil }
                } else {
                    Text("None").foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { store.chooseOutputFolder() }
                }
            }
            if choice.wrappedValue.outputFolder != nil {
                Label("It can read, change and delete anything in this folder. What it saves there stays after it quits.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Look.font(.caption)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A folder whose contents it may change, so its work isn't lost when it quits.")
                    .font(Look.font(.caption)).foregroundStyle(.secondary)
            }
        }
    }

    private func isFolder(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}

struct RunRow: View {
    let store: Store
    let run: Run

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HeartMonitor(run: run, leads: [nil], span: 30, hover: run.rowHover)
                .frame(height: 104)
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(run.name).font(Look.font(.headline))
                Text(run.summary).font(Look.font(.caption)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Label(run.state.title, systemImage: run.state.symbol)
                        .foregroundStyle(run.state.color)
                        .lineLimit(2)
                    if run.activity.total() > 0 {
                        Text("· \(run.activity.total()) blocked").foregroundStyle(.secondary)
                    }
                }
                .font(Look.font(.caption))
                if let latest = run.activity.latestNotable {
                    // The last block you'd likely notice (a save, an open, a connection), so a
                    // failed save in the app isn't lost among background cache writes.
                    HStack(spacing: 4) {
                        Label("Blocked: \(latest.sentence)", systemImage: "hand.raised.fill")
                            .lineLimit(1).truncationMode(.middle)
                        Text(latest.last, style: .relative).foregroundStyle(.secondary)
                        Text("ago").foregroundStyle(.secondary)
                        if run.activity.notableTotal() > latest.count {
                            Text("· \(run.activity.notableTotal()) noticeable in all").foregroundStyle(.secondary)
                        }
                    }
                    .font(Look.font(.caption)).foregroundStyle(.red)
                    .help(latest.sentence)
                }
                if run.logComplete == false {
                    Label("Logging was incomplete: some blocked requests may be missing.", systemImage: "exclamationmark.triangle")
                        .font(Look.font(.caption)).foregroundStyle(.orange)
                }
            }
            Spacer()
            if run.state.isActive {
                Button("Stop") { run.stop.stop() }.buttonStyle(LookButtonStyle())
            }
            if let out = run.outputFolder {
                Button("Output") { NSWorkspace.shared.open(URL(fileURLWithPath: out)) }.buttonStyle(LookButtonStyle())
                    .help("Open \(store.environment.abbreviate(out)) in Finder")
            }
            if run.logURL != nil {
                Button("Activity") { store.viewing = run }.buttonStyle(LookButtonStyle())
            }
        }
    }
}

/// What the app was blocked from, grouped and counted, searchable, exportable.
struct ActivityView: View {
    let store: Store
    let run: Run

    private var shown: [ActivityItem] {
        run.activity.items(in: run.group, matching: run.search, background: run.showBackground)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(run.name): blocked requests").font(Look.font(.headline))
                Spacer()
                Label(run.state.title, systemImage: run.state.symbol)
                    .font(Look.font(.caption)).foregroundStyle(run.state.color)
            }
            HeartMonitor(run: run, leads: ActivityGroup.allCases.map { Optional($0) }, span: 60, hover: run.viewerHover)
                .frame(height: 240)
            if run.logComplete == false {
                Label("Logging was incomplete: the system log dropped messages or the final check didn't arrive, so some blocked requests may be missing.",
                      systemImage: "exclamationmark.triangle")
                    .font(Look.font(.caption)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                LookSegmented(selection: Binding(get: { run.group }, set: { run.group = $0 }),
                              options: [(ActivityGroup?.none, "All \(run.activity.total())")]
                                + ActivityGroup.allCases.map { (Optional($0), "\($0.title) \(run.activity.total($0))") })
                    .fixedSize()
                TextField("Search paths, addresses, services", text: Binding(get: { run.search }, set: { run.search = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("\(run.activity.notableTotal()) you'd likely notice (your files, network, other programs) · \(run.activity.total() - run.activity.notableTotal()) background (its caches, settings, temp files)")
                    .font(Look.font(.caption)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show background", isOn: Binding(get: { run.showBackground }, set: { run.showBackground = $0 }))
                    .font(Look.font(.caption))
            }
            if shown.isEmpty {
                VStack {
                    Spacer()
                    Text(run.activity.items.isEmpty ? "Nothing was blocked."
                         : run.showBackground || run.activity.notableTotal() > 0 ? "No blocked requests match."
                         : "Only background requests were blocked. Turn on Show background to see them.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Table(shown) {
                    TableColumn("Count") { item in Text("\(item.count)").monospacedDigit() }
                        .width(min: 44, ideal: 54, max: 70)
                    TableColumn("What") { item in
                        Text(item.target.isEmpty ? "—" : item.target)
                            .foregroundStyle(item.notable ? Color.red : Color.primary)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .help(item.target)
                    }
                    TableColumn("Request") { item in Text(item.operation).foregroundStyle(.secondary) }
                        .width(min: 100, ideal: 150)
                    TableColumn("Group") { item in Text(item.group.title).foregroundStyle(.secondary) }
                        .width(min: 60, ideal: 70, max: 90)
                    TableColumn("Process") { item in Text(item.processes.joined(separator: ", ")).foregroundStyle(.secondary) }
                        .width(min: 70, ideal: 100)
                }
            }
            HStack {
                if let log = run.logURL {
                    Button("Show Log File") { NSWorkspace.shared.activateFileViewerSelecting([log]) }.buttonStyle(LookButtonStyle())
                }
                Spacer()
                Button("Export Shown…") { export(shown) }.buttonStyle(LookButtonStyle())
                    .disabled(shown.isEmpty)
                Button("Done") { store.viewing = nil }
                    .buttonStyle(LookButtonStyle(isDefault: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .lookWindow()
        .frame(minWidth: 760, minHeight: 480)
    }

    private func export(_ items: [ActivityItem]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(run.name) blocked requests.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ActivityLog.csv(items).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            store.message = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

/// Where the pointer is over a heart monitor, if it is. A class so the monitor can change it
/// without @State (which needs a compiler plugin the Command Line Tools lack).
@Observable final class Hover {
    var x: CGFloat?
}

/// Blocked requests as a heart monitor: each lead is a trace scrolling right to left, with a
/// spike for every quarter second that had blocks (taller for more, on a log scale). On the
/// all-groups lead each spike takes the color of the group that made most of it. A block
/// you'd likely notice (a save, an open, a connection) is a full-height red spike with a
/// marker. A time axis runs along the bottom; hovering shows that second's blocks by group
/// and what you'd notice in it. Live while the app runs; once it ends the trace turns grey and
/// shows the whole run (up to the two minutes kept).
struct HeartMonitor: View {
    let run: Run
    /// One trace each; nil is all groups together.
    let leads: [ActivityGroup?]
    /// Seconds across the width while the app runs.
    let span: TimeInterval
    let hover: Hover

    static let axisHeight: CGFloat = 14
    static let font = Font.system(size: 10, weight: .medium).monospacedDigit()

    var body: some View {
        let active = run.state.isActive
        let endedAt = run.endedAt
        let hoverX = hover.x
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { timeline in
            let end = endedAt ?? timeline.date
            Canvas { context, size in
                draw(&context, size: size, end: end, active: active, hoverX: hoverX)
            }
        }
        .background(Color.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover.x = point.x
            case .ended: hover.x = nil
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Blocked requests over time")
        .accessibilityValue("\(run.activity.pulse.rate(nil, at: run.endedAt ?? Date())) per second")
    }

    static func color(_ lead: ActivityGroup?, active: Bool) -> Color {
        guard active else { return .gray }
        switch lead {
        case nil, .files?: return .green
        case .network?: return .cyan
        case .programs?: return .yellow
        case .services?: return .pink
        }
    }

    /// Seconds across the width: `span` while running; once ended, the whole run (at least 10 s,
    /// at most what the pulse keeps).
    private func window(end: Date, active: Bool) -> TimeInterval {
        if active { return span }
        let kept = Double(Pulse.keep) * Pulse.bucket
        return min(max(end.timeIntervalSince(run.startedAt) + 1, 10), kept)
    }

    /// The group with the most blocks in bucket `i`.
    private func dominant(_ i: Int64) -> ActivityGroup {
        let pulse = run.activity.pulse
        return ActivityGroup.allCases.max { pulse.count($0, i) < pulse.count($1, i) } ?? .files
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, end: Date, active: Bool, hoverX: CGFloat?) {
        let plotHeight = size.height - Self.axisHeight
        // Monitor paper: a faint grid.
        var grid = Path()
        for x in stride(from: 0, through: size.width, by: 12) {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: plotHeight))
        }
        for y in stride(from: 0, through: plotHeight, by: 12) {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(grid, with: .color(.green.opacity(0.07)), lineWidth: 0.5)

        let bucket = Pulse.bucket
        let span = window(end: end, active: active)
        let endTime = end.timeIntervalSinceReferenceDate
        let startTime = endTime - span
        let first = Pulse.index(Date(timeIntervalSinceReferenceDate: startTime))
        let last = Pulse.index(end)
        let width = size.width * CGFloat(bucket / span)
        let laneHeight = plotHeight / CGFloat(max(leads.count, 1))
        let pulse = run.activity.pulse
        let alarm = active ? Color.red : Color.red.opacity(0.6)

        for (lane, lead) in leads.enumerated() {
            let top = CGFloat(lane) * laneHeight
            let base = top + laneHeight * 0.7
            let amplitude = laneHeight * 0.5
            let color = Self.color(lead, active: active)
            var trace = Path()
            var alarms = Path()
            var tinted: [ActivityGroup: Path] = [:]
            var markers: [CGPoint] = []
            var peak = 0
            var pen = CGPoint(x: 0, y: base)
            trace.move(to: pen)
            for i in first...last {
                let x = CGFloat((Double(i) * bucket - startTime) / span) * size.width
                let count = pulse.count(lead, i)
                peak = max(peak, count)
                guard count > 0 else {
                    pen = CGPoint(x: x + width, y: base)
                    trace.addLine(to: pen)
                    continue
                }
                // Q dip, R spike, S dip, back to baseline. 127 blocks a bucket fills the lane;
                // a block you'd notice always does.
                let notable = pulse.notable(lead, i) > 0
                let a = notable ? amplitude : amplitude * CGFloat(min(1, log2(1 + Double(count)) / 7))
                let points = [CGPoint(x: x, y: base), CGPoint(x: x + width * 0.2, y: base + a * 0.15),
                              CGPoint(x: x + width * 0.45, y: base - a), CGPoint(x: x + width * 0.7, y: base + a * 0.3),
                              CGPoint(x: x + width, y: base)]
                for p in points.dropFirst() { trace.addLine(to: p) }
                if notable {
                    alarms.move(to: points[0])
                    for p in points.dropFirst() { alarms.addLine(to: p) }
                    markers.append(points[2])
                } else if lead == nil {
                    var path = tinted[dominant(i), default: Path()]
                    path.move(to: points[0])
                    for p in points.dropFirst() { path.addLine(to: p) }
                    tinted[dominant(i)] = path
                }
                pen = points[4]
            }
            // Phosphor glow, then the line itself; on the all-groups lead, each spike again in its group's color.
            ctx.stroke(trace, with: .color(color.opacity(0.3)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            ctx.stroke(trace, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            for (group, path) in tinted where group != .files {
                ctx.stroke(path, with: .color(Self.color(group, active: active)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            ctx.stroke(alarms, with: .color(alarm.opacity(0.35)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            ctx.stroke(alarms, with: .color(alarm), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            for m in markers {
                ctx.fill(Path(ellipseIn: CGRect(x: m.x - 3, y: m.y - 3, width: 6, height: 6)), with: .color(alarm))
            }
            if active {
                let dot = CGRect(x: min(pen.x, size.width) - 3, y: pen.y - 3, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(color.opacity(0.3)))
                ctx.fill(Path(ellipseIn: dot), with: .color(color))
            }

            // Top left: totals, and on the all-groups lead the split by group.
            var label = Text("\(lead?.title ?? "Blocked")  \(run.activity.total(lead))").foregroundColor(color.opacity(0.9))
            if lead == nil {
                for group in ActivityGroup.allCases where run.activity.total(group) > 0 {
                    label = label + Text("   \(group.title) \(run.activity.total(group))")
                        .foregroundColor(Self.color(group, active: active).opacity(0.85))
                }
            }
            let notable = run.activity.notableTotal(lead)
            if notable > 0 { label = label + Text("   \(notable) noticeable").foregroundColor(alarm) }
            ctx.draw(label.font(Self.font), at: CGPoint(x: 8, y: top + 4), anchor: .topLeading)

            // Top right: blocks in the last second, and the busiest quarter second on screen.
            let rate = active ? "\(pulse.rate(lead, at: end))/s   " : ""
            let busiest = peak > 0 ? "peak \(peak * 4)/s" : ""
            ctx.draw(Text(rate + busiest).font(Self.font).foregroundColor(color.opacity(0.85)),
                     at: CGPoint(x: size.width - 8, y: top + 4), anchor: .topTrailing)
            if lane > 0 {
                var divider = Path()
                divider.move(to: CGPoint(x: 0, y: top))
                divider.addLine(to: CGPoint(x: size.width, y: top))
                ctx.stroke(divider, with: .color(.white.opacity(0.08)), lineWidth: 1)
            }
        }

        drawAxis(&ctx, size: size, span: span, startTime: startTime, active: active)
        if let hoverX, hoverX >= 0, hoverX <= size.width {
            drawHover(&ctx, size: size, x: hoverX, span: span, startTime: startTime, end: end, active: active)
        }
    }

    /// Ticks along the bottom: seconds ago while running ("−20s … now"), seconds since launch
    /// once it has ended ("0s … 14s").
    private func drawAxis(_ ctx: inout GraphicsContext, size: CGSize, span: TimeInterval, startTime: TimeInterval, active: Bool) {
        let y = size.height - Self.axisHeight
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(line, with: .color(.white.opacity(0.12)), lineWidth: 1)
        let step: TimeInterval = span <= 15 ? 2 : span <= 40 ? 5 : span <= 80 ? 10 : 20
        let launch = run.startedAt.timeIntervalSinceReferenceDate
        let tick = Color.white.opacity(0.45)
        var t: TimeInterval = 0
        while t <= span + 0.001 {
            let x = size.width * CGFloat(1 - t / span)
            let text: String
            if active { text = t == 0 ? "now" : "−\(Int(t))s" }
            else { text = "\(max(0, Int((startTime + span - t - launch).rounded())))s" }
            let anchor: UnitPoint = x > size.width - 20 ? .topTrailing : x < 20 ? .topLeading : .top
            var mark = Path()
            mark.move(to: CGPoint(x: x, y: y))
            mark.addLine(to: CGPoint(x: x, y: y + 3))
            ctx.stroke(mark, with: .color(tick), lineWidth: 1)
            ctx.draw(Text(text).font(.system(size: 9).monospacedDigit()).foregroundColor(tick),
                     at: CGPoint(x: min(max(x, 2), size.width - 2), y: y + 2), anchor: anchor)
            t += step
        }
    }

    /// A cursor and a label for the second under the pointer: when, blocks by group, and the
    /// first thing you'd notice in it.
    private func drawHover(_ ctx: inout GraphicsContext, size: CGSize, x: CGFloat, span: TimeInterval,
                           startTime: TimeInterval, end: Date, active: Bool) {
        let plotHeight = size.height - Self.axisHeight
        var cursor = Path()
        cursor.move(to: CGPoint(x: x, y: 0))
        cursor.addLine(to: CGPoint(x: x, y: plotHeight))
        ctx.stroke(cursor, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        let t = startTime + Double(x / size.width) * span
        let centre = Pulse.index(Date(timeIntervalSinceReferenceDate: t))
        let buckets = (centre - 2)...(centre + 1)
        let pulse = run.activity.pulse
        let when = active ? "\(Int((end.timeIntervalSinceReferenceDate - t).rounded()))s ago"
                          : "at \(max(0, Int((t - run.startedAt.timeIntervalSinceReferenceDate).rounded())))s"
        var lines = [when]
        let counts = ActivityGroup.allCases.map { g in (g, buckets.reduce(0) { $0 + pulse.count(g, $1) }) }.filter { $0.1 > 0 }
        lines.append(counts.isEmpty ? "nothing blocked" : counts.map { "\($0.0.title) \($0.1)" }.joined(separator: " · "))
        let moment = Date(timeIntervalSinceReferenceDate: t)
        let noticed = run.activity.items.filter { $0.notable && $0.first <= moment.addingTimeInterval(0.6) && $0.last >= moment.addingTimeInterval(-0.6) }
        if let item = noticed.first {
            let sentence = item.sentence
            lines.append("Blocked: " + (sentence.count > 60 ? String(sentence.prefix(28)) + "…" + String(sentence.suffix(31)) : sentence))
            if noticed.count > 1 { lines.append("and \(noticed.count - 1) more you'd notice") }
        }

        let text = ctx.resolve(Text(lines.joined(separator: "\n")).font(Self.font).foregroundColor(.white))
        let box = text.measure(in: CGSize(width: size.width - 16, height: plotHeight))
        let pad: CGFloat = 5
        let w = box.width + pad * 2, h = box.height + pad * 2
        let left = x + 8 + w <= size.width ? x + 8 : x - 8 - w
        let rect = CGRect(x: max(2, left), y: 4, width: w, height: min(h, plotHeight - 6))
        ctx.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(.black.opacity(0.85)))
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(.white.opacity(0.25)), lineWidth: 1)
        ctx.draw(text, in: rect.insetBy(dx: pad, dy: pad))
    }
}
