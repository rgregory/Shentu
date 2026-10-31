import AppKit
import ShentuCore
import SwiftUI

// Like Menshen.app, UI state lives in @Observable models and views take bindings from
// `Binding(get:set:)`: SwiftUI's @State needs a compiler plugin the Command Line Tools lack.

/// Apps dropped on the Dock icon (or opened with Shentu) arrive here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store?
    func application(_ application: NSApplication, open urls: [URL]) {
        store?.dropped(urls)
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
            MainView(store: store)
                .frame(minWidth: 460, minHeight: 420)
                .onAppear { delegate.store = store }
        }
    }
}

/// One app dropped and waiting for its options.
struct Pending: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let key: String
    var choice: LaunchChoice
}

/// One launch, running or finished. Only changed on the main thread (the launch thread hops
/// there), hence unchecked.
@Observable final class Run: Identifiable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let summary: String
    let stop = StopHandle()
    var running = true
    var blocked = 0
    var status = "Starting…"
    var logURL: URL?

    init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

@Observable final class Store {
    let environment = Shentu.environment()
    var pending: Pending?
    var runs: [Run] = []
    var message: String?

    func dropped(_ urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == "app" }) else {
            message = "Drop a Mac app (a .app) on Shentu."
            return
        }
        do {
            let target = try ResolvedTarget.resolve(url.path)
            try target.preflight()
            let key = target.identity.key
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

    func launch(_ item: Pending) {
        pending = nil
        RememberedChoices(environment).save(item.choice, for: item.key)
        let run = Run(name: item.name, summary: Self.describe(item.choice))
        runs.insert(run, at: 0)
        let env = environment
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try Shentu.launch(item.path, item.choice, environment: env, stop: run.stop,
                    onRecord: { record in
                        guard record.verdict == .deny else { return }
                        DispatchQueue.main.async { run.blocked += record.count }
                    },
                    say: { line in
                        guard line.hasPrefix("log: ") else { return }
                        DispatchQueue.main.async { run.logURL = URL(fileURLWithPath: String(line.dropFirst(5))) }
                    })
                DispatchQueue.main.async {
                    run.running = false
                    run.logURL = summary.logURL
                    run.status = "Quit. Its temp folder was deleted."
                }
            } catch {
                DispatchQueue.main.async {
                    run.running = false
                    run.status = "Couldn't run: \(error)"
                }
            }
        }
        run.status = "Running"
    }

    static func describe(_ choice: LaunchChoice) -> String {
        var parts = [choice.network ? "Network on" : "No network"]
        let kinds = choice.categories.map { $0.title.lowercased() }
        parts.append(kinds.isEmpty ? "reads none of your files" : "reads " + kinds.joined(separator: ", "))
        parts.append(choice.keepSettings ? "keeps its settings" : "starts fresh")
        return parts.joined(separator: " · ")
    }
}

struct MainView: View {
    let store: Store

    var body: some View {
        VStack(spacing: 16) {
            DropZone(store: store)
            if !store.runs.isEmpty {
                List(store.runs) { RunRow(run: $0) }
                    .listStyle(.inset)
            }
        }
        .padding(20)
        .sheet(item: Binding(get: { store.pending }, set: { store.pending = $0 })) { item in
            OptionsView(store: store, item: item)
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
            Text("Drop a Mac app here").font(.title3)
            Text("You choose what it can reach, then it opens in a sandbox.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Choose an App…") { store.choose() }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6])).foregroundStyle(.tertiary))
        .dropDestination(for: URL.self) { urls, _ in
            store.dropped(urls)
            return true
        }
    }
}

/// The pop-up: options for this launch.
struct OptionsView: View {
    let store: Store
    let item: Pending

    private var choice: Binding<LaunchChoice> {
        Binding(get: { store.pending?.choice ?? item.choice }, set: { store.pending?.choice = $0 })
    }

    private func kind(_ category: FileCategory) -> Binding<Bool> {
        Binding(get: { choice.wrappedValue.allows(category) }, set: { choice.wrappedValue.set(category, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open \(item.name) in Shentu").font(.headline)

            Toggle("Internet and network", isOn: choice.network)

            VStack(alignment: .leading, spacing: 6) {
                Text("Files it can open in your home folder and on drives:")
                ForEach(FileCategory.allCases, id: \.self) { category in
                    Toggle(category.title, isOn: kind(category))
                }
                Text("It can see file and folder names, but not other files' contents. System files and the app itself are always readable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keep its settings between runs", isOn: choice.keepSettings)
                Text("Off: it starts fresh every time and nothing is saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label("Saves files only to a temporary folder, deleted when it quits.", systemImage: "trash")
                Label("Can't start other programs or open links.", systemImage: "nosign")
            }
            .font(.callout).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { store.pending = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { store.launch(store.pending ?? item) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct RunRow: View {
    let run: Run

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(run.name).font(.headline)
                Text(run.summary).font(.caption).foregroundStyle(.secondary)
                Text(run.blocked > 0 ? "\(run.status) · \(run.blocked) blocked" : run.status)
                    .font(.caption)
            }
            Spacer()
            if run.running {
                Button("Stop") { run.stop.stop() }
            }
            if let log = run.logURL {
                Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
            }
        }
        .padding(.vertical, 4)
    }
}
