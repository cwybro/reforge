import SwiftUI
import AppKit

/// Quit when the window closes so the app uses nothing while you're not looking at it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if E2E.isActive { E2E.stayOutOfTheWay() }
    }
}

/// The LaunchAgent runs this executable with `--background-check` (see BackgroundCheck.swift):
/// check once and exit without starting the UI. Anything else opens the app.
@main
enum Entry {
    @MainActor static func main() {
        if CommandLine.arguments.contains(BackgroundCheck.argument) { BackgroundCheck.runFromLaunchAgent() }
        ReforgeApp.main()
    }
}

struct ReforgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Production dependencies, unless REFORGE_E2E_FIXTURE selects the E2E stubs (see E2EStubs.swift).
    @State private var model = E2E.makeModel() ?? Model()

    var body: some Scene {
        Window("Reforge", id: "main") {
            RootView(model: model)
                .frame(minWidth: 680, minHeight: 480)
        }
        .defaultSize(width: 760, height: 540)
        // No system title bar or toolbar: both screens draw their own header, so
        // the window controls stay in exactly the same place when switching.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Show Welcome Screen") { withAnimation(.easeInOut(duration: 0.5)) { model.showOnboardingAgain() } }
            }
            CommandGroup(after: .newItem) {
                Button("Check for Updates") { Task { await model.checkForUpdates() } }
                    .keyboardShortcut("r")
            }
        }
        Settings {
            SettingsView(model: model)
                .preferredColorScheme(.dark)
                .tint(Theme.magenta)
        }
    }
}

/// Shows the welcome flow until it's been completed, then the addon list.
struct RootView: View {
    @Bindable var model: Model

    var body: some View {
        ZStack {
            if model.needsOnboarding {
                OnboardingView(model: model).transition(.opacity)
            } else {
                ContentView(model: model).transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.97)),
                    removal: .opacity))
            }
        }
        // Both screens draw edge to edge, under the transparent title bar.
        .ignoresSafeArea()
        .background(Theme.navy.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.magenta)
        .background(WindowConfigurator())
        .task { model.syncBackgroundChecks() }
    }
}

/// Gives the window an empty, transparent toolbar so macOS centres the close/minimise/zoom
/// buttons in a 52pt bar that lines up with our own header, on every screen.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { Self.configure(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func configure(_ window: NSWindow) {
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "reforge.titlebar")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The (empty) toolbar sits on top of our header and would swallow its clicks.
        if let container = window.standardWindowButton(.closeButton)?.superview?.superview {
            TitlebarPassThrough.apply(to: container)
        }
    }
}

/// Lets clicks in the title bar fall through to the SwiftUI header underneath, except on
/// real controls (the close/minimise/zoom buttons). Done by giving the title bar container
/// a tiny runtime subclass whose hitTest drops anything that isn't an NSControl.
private enum TitlebarPassThrough {
    static func apply(to view: NSView) {
        guard let cls = object_getClass(view) else { return }
        let base = NSStringFromClass(cls)
        guard !base.hasPrefix("Reforge_") else { return }
        let name = "Reforge_" + base
        var sub: AnyClass? = NSClassFromString(name)
        if sub == nil, let made = objc_allocateClassPair(cls, name, 0),
           let method = class_getInstanceMethod(cls, #selector(NSView.hitTest(_:))) {
            typealias HitTest = @convention(c) (NSView, Selector, NSPoint) -> NSView?
            let sel = #selector(NSView.hitTest(_:))
            let original = unsafeBitCast(method_getImplementation(method), to: HitTest.self)
            let block: @convention(block) (NSView, NSPoint) -> NSView? = { view, point in
                let hit = original(view, sel, point)
                return hit is NSControl ? hit : nil
            }
            class_addMethod(made, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
            objc_registerClassPair(made)
            sub = made
        }
        if let sub { object_setClass(view, sub) }
    }
}

// MARK: - Main window

struct ContentView: View {
    @Bindable var model: Model
    @State private var showingAdd = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                Header(model: model, showingAdd: $showingAdd)
                    .zIndex(1)
                if !model.hasKey {
                    KeyBanner(model: model).padding(.horizontal, 20).padding(.bottom, 12)
                }
                if model.config.addons.isEmpty {
                    EmptyState().frame(maxHeight: .infinity)
                        .accessibilityIdentifier("main.empty")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.config.addons) { addon in
                                AddonRow(addon: addon, model: model)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 4)
                        .padding(.bottom, 12)
                    }
                    .accessibilityIdentifier("main.list")
                }
                StatusBar(model: model)
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showingAdd) { AddSheet(model: model) }
        .task { await model.checkForUpdates() }
    }
}

/// Static version of the welcome screen's backdrop: same colours, no animation.
private struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.navy
            RadialGradient(colors: [Theme.purple.opacity(0.9), Theme.navy], center: UnitPoint(x: 0.5, y: -0.15),
                           startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color.orange.opacity(0.08), .clear], center: UnitPoint(x: 0.5, y: 1.2),
                           startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

private struct Header: View {
    @Bindable var model: Model
    @Binding var showingAdd: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .shadow(color: Theme.magenta.opacity(0.5), radius: 8)
            Text("Reforge")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.white, Theme.gold], startPoint: .top, endPoint: .bottom))
            Spacer()
            Button { showingAdd = true } label: { Image(systemName: "plus") }
                .buttonStyle(CircleIconButtonStyle())
                .help("Add an addon")
                .disabled(!model.hasKey)
                .accessibilityIdentifier("header.add")
            Button { Task { await model.checkForUpdates() } } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.checking ? 360 : 0))
                    .animation(model.checking ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                               value: model.checking)
            }
            .buttonStyle(CircleIconButtonStyle())
            .help("Check for updates (⌘R)")
            .disabled(!model.hasKey || model.checking)
            .accessibilityIdentifier("header.refresh")
            Button { Task { await model.updateAll() } } label: {
                Label(model.updatable.isEmpty ? "Update All" : "Update All (\(model.updatable.count))",
                      systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(GlowButtonStyle(compact: true))
            .disabled(model.updatable.isEmpty)
            .accessibilityIdentifier("header.updateAll")
        }
        // Leave room for the window's close/minimise/zoom buttons on the left.
        .padding(.leading, 86)
        .padding(.trailing, 14)
        .frame(height: 52)
        .padding(.bottom, 8)
    }
}

private struct AddonRow: View {
    let addon: TrackedAddon
    let model: Model
    @State private var hovering = false

    private var status: RowStatus { model.status[addon.id] ?? .unknown }
    private var hasUpdate: Bool { status == .updateAvailable }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(addon.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("addonRow.\(addon.id).name")
                Text(addon.folders.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            versions
                .frame(maxWidth: 280, alignment: .trailing)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("addonRow.\(addon.id).version")
            StatusCell(addon: addon, model: model)
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(hovering ? 0.09 : 0.05))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hasUpdate ? Theme.gold.opacity(0.5) : .white.opacity(0.08)))
                .shadow(color: hasUpdate ? Theme.gold.opacity(0.25) : .clear, radius: 10)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeInOut(duration: 0.3), value: status)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addonRow.\(addon.id)")
        .contextMenu {
            if let s = addon.websiteURL, let u = URL(string: s) {
                Button("Open on CurseForge") { NSWorkspace.shared.open(u) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(addon.folders.map { model.addonsDir.appendingPathComponent($0) })
            }
            Divider()
            Button("Stop Tracking") { model.remove(addon, deleteFiles: false) }
            Button("Uninstall (Move to Trash)") { model.remove(addon, deleteFiles: true) }
        }
        // The same commands for VoiceOver and other assistive tools (and the E2E tests), which
        // can't rely on a context menu opening.
        .accessibilityAction(named: "Stop Tracking") { model.remove(addon, deleteFiles: false) }
        .accessibilityAction(named: "Uninstall (Move to Trash)") { model.remove(addon, deleteFiles: true) }
    }

    @ViewBuilder private var versions: some View {
        let font = Font.system(size: 12, design: .rounded)
        if hasUpdate, let latest = model.latest[addon.id] {
            HStack(spacing: 6) {
                Text(addon.version).foregroundStyle(.white.opacity(0.4)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").foregroundStyle(Theme.gold.opacity(0.8))
                Text(latest.displayName).foregroundStyle(Theme.gold).lineLimit(1).truncationMode(.middle)
            }
            .font(font)
            .help("\(addon.version) → \(latest.displayName)")
        } else {
            Text(addon.version)
                .font(font)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(addon.version)
        }
    }
}

struct StatusCell: View {
    let addon: TrackedAddon
    let model: Model

    var body: some View {
        switch model.status[addon.id] ?? .unknown {
        case .unknown:
            EmptyView()
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.cyan.opacity(0.75))
                .accessibilityIdentifier("addonRow.\(addon.id).upToDate")
        case .working:
            ProgressView().controlSize(.small)
                .accessibilityIdentifier("addonRow.\(addon.id).working")
        case .updateAvailable:
            Button("Update") { Task { await model.update(addon) } }
                .buttonStyle(GlowButtonStyle(compact: true))
                .accessibilityIdentifier("addonRow.\(addon.id).update")
        case .failed(let err):
            Button { Task { await model.update(addon) } } label: {
                Label("Retry", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(QuietButtonStyle(tint: Theme.magenta))
            .help(err)
            .accessibilityIdentifier("addonRow.\(addon.id).retry")
        }
    }
}

private struct StatusBar: View {
    let model: Model

    var body: some View {
        HStack {
            Text(model.message ?? (model.lastChecked.map { "Checked at \($0.formatted(date: .omitted, time: .shortened))" } ?? " "))
                .lineLimit(1)
                .accessibilityIdentifier("status.message")
            Spacer()
            Text("\(model.config.addons.count) addon\(model.config.addons.count == 1 ? "" : "s")")
                .accessibilityIdentifier("status.count")
        }
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(.black.opacity(0.22))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 34))
                .foregroundStyle(LinearGradient(colors: [Theme.cyan, Theme.magenta], startPoint: .top, endPoint: .bottom))
                .shadow(color: Theme.magenta.opacity(0.5), radius: 12)
            Text("No addons yet").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text("Add one with the + button.").font(.callout).foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// Search or browse CurseForge's WoW addons and install them, or paste a link / project ID.
/// Stays open so several addons can be added in one go.
struct AddSheet: View {
    let model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var search: AddonSearch
    @FocusState private var fieldFocused: Bool

    init(model: Model) {
        self.model = model
        _search = State(initialValue: AddonSearch(model: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add Addons")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("addSheet.cancel")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("Search addons, or paste a CurseForge link or project ID", text: $search.text)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .accessibilityIdentifier("addSheet.field")
            }
            .padding(11)
            .background(Card())
            HStack(spacing: 10) {
                Picker("Sort", selection: $search.sort) {
                    ForEach(SearchSort.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .accessibilityIdentifier("search.sort")
                Picker("Category", selection: $search.categoryId) {
                    Text("All categories").tag(Int?.none)
                    ForEach(search.categories) { Text($0.name).tag(Int?.some($0.id)) }
                }
                .fixedSize()
                .accessibilityIdentifier("search.category")
                Spacer()
                if search.loading { ProgressView().controlSize(.small) }
                if search.total > 0 {
                    Text(search.total >= AddonSearch.maxResults ? "\(AddonSearch.maxResults.formatted())+ addons"
                                                                : "\(search.total.formatted()) addons")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                        .accessibilityIdentifier("search.total")
                }
            }
            .labelsHidden()
            .disabled(search.directInput != nil)
            results
        }
        .padding(24)
        .frame(width: 620, height: 580)
        .background(AppBackground())
        .preferredColorScheme(.dark)
        .onAppear { fieldFocused = true }
        .task { await search.loadCategories() }
        // Re-search whenever the text, sort or category changes; the pause lets typing settle
        // (a newer change cancels this task before it fires).
        .task(id: search.query) {
            if !search.results.isEmpty || !search.query.text.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            await search.run()
        }
    }

    @ViewBuilder private var results: some View {
        if let direct = search.directInput {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Install from link or ID").font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(direct).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Install", action: submit)
                    .buttonStyle(GlowButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("addSheet.install")
            }
            .padding(12)
            .background(Card())
            Spacer()
        } else if let error = search.error {
            VStack(spacing: 10) {
                Text(error).foregroundStyle(.orange).multilineTextAlignment(.center)
                Button("Try Again") { Task { await search.run() } }.buttonStyle(QuietButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("search.error")
        } else if search.results.isEmpty {
            Group {
                if search.loading {
                    ProgressView()
                } else {
                    Text(search.query.text.isEmpty ? "No addons found." : "No addons match “\(search.query.text)”.")
                        .foregroundStyle(.white.opacity(0.55))
                        .accessibilityIdentifier("search.empty")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(search.results, id: \.id) { mod in
                        SearchResultRow(mod: mod, search: search)
                            .onAppear {
                                // Infinite scroll: fetch the next page as the last row comes into view.
                                if mod.id == search.results.last?.id { Task { await search.loadMore() } }
                            }
                    }
                }
                .padding(.bottom, 4)
            }
            .accessibilityIdentifier("search.results")
        }
    }

    /// Return: install a pasted link / ID (closing the sheet), or the top result.
    private func submit() {
        if let input = search.directInput {
            dismiss()
            Task { await model.add(input) }
        } else if let first = search.results.first, !search.isInstalled(first.id) {
            Task { await search.install(first) }
        }
    }
}

private struct SearchResultRow: View {
    let mod: CFMod
    let search: AddonSearch

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: mod.logo?.thumbnailUrl.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(mod.name)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let author = mod.authors?.first?.name {
                        Text("by \(author)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }
                    if let site = mod.links?.websiteUrl.flatMap(URL.init(string:)) {
                        Link(destination: site) { Image(systemName: "arrow.up.right.square") }
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .help("Open on CurseForge")
                    }
                }
                if let summary = mod.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !details.isEmpty {
                    Text(details).font(.system(size: 11)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
                }
                if let failure = search.failures[mod.id] {
                    Text(failure).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                        .accessibilityIdentifier("search.result.\(mod.id).failure")
                }
            }
            Spacer(minLength: 8)
            installControl.frame(minWidth: 84, alignment: .trailing)
        }
        .padding(10)
        .background(Card())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.result.\(mod.id)")
    }

    /// "12M downloads · Updated Mar 3, 2026 · Bags & Inventory"
    private var details: String {
        var parts: [String] = []
        if let d = mod.downloadCount { parts.append("\(Int(d).formatted(.number.notation(.compactName))) downloads") }
        if let date = mod.dateModified { parts.append("Updated \(date.formatted(date: .abbreviated, time: .omitted))") }
        if let category = mod.categories?.first?.name { parts.append(category) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var installControl: some View {
        if search.isInstalled(mod.id) {
            Label("Installed", systemImage: "checkmark")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.cyan)
                .accessibilityIdentifier("search.result.\(mod.id).installed")
        } else if search.installing.contains(mod.id) {
            ProgressView().controlSize(.small)
        } else {
            Button("Install") { Task { await search.install(mod) } }
                .buttonStyle(GlowButtonStyle(compact: true))
                .accessibilityIdentifier("search.result.\(mod.id).install")
        }
    }
}

struct KeyBanner: View {
    @Bindable var model: Model
    @State private var key = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.gold)
                .shadow(color: Theme.gold.opacity(0.5), radius: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect to CurseForge to check for updates")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                SecureField("Paste your API key", text: $key)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Card())
                    .accessibilityIdentifier("keyBanner.field")
            }
            Button("Save") {
                Task {
                    if let err = await model.verifyAndSaveKey(key.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        model.message = err
                    } else {
                        await model.checkForUpdates()
                    }
                }
            }
            .buttonStyle(GlowButtonStyle(compact: true))
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("keyBanner.save")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.gold.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.gold.opacity(0.35))))
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CircleIconButton(configuration: configuration)
    }

    private struct CircleIconButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 0.9 : 0.35))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.12 : 0.07))))
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                .contentShape(Circle())
                .onHover { hovering = $0 && isEnabled }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - Settings

/// The system folder picker. Stub mode swaps in a fixed answer (see E2EStubs.swift).
enum FolderPicker {
    @MainActor static func openPanel(startingAt dir: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = dir
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct SettingsView: View {
    @Bindable var model: Model

    var body: some View {
        Form {
            SecureField("CurseForge API key", text: $model.apiKey)
                .onSubmit { model.saveAPIKey() }
                .accessibilityIdentifier("settings.key")
            HStack {
                TextField("AddOns folder", text: $model.config.addonsPath)
                    .accessibilityIdentifier("settings.folder")
                Button("Choose…") {
                    if let u = model.chooseFolder(model.addonsDir) { model.config.addonsPath = u.path }
                }
                .accessibilityIdentifier("settings.chooseFolder")
            }
            Picker("Game version", selection: $model.config.gameVersionTypeId) {
                Text("Retail").tag(517)
                Text("Classic Era").tag(67408)
                Text("Mists Classic").tag(79434)
                Text("Anniversary").tag(73246)
            }
            .accessibilityIdentifier("settings.gameVersion")
            Toggle("Include beta/alpha releases", isOn: $model.config.allowPrerelease)
                .accessibilityIdentifier("settings.prerelease")
            Toggle("Check for updates while Reforge is closed", isOn: Binding(
                get: { model.config.backgroundCheckHours != nil },
                set: { on in Task { await model.setBackgroundChecks(hours: on ? BackgroundCheck.defaultHours : nil) } }))
                .accessibilityIdentifier("settings.backgroundCheck")
            Picker("Check", selection: Binding(
                get: { model.config.backgroundCheckHours ?? BackgroundCheck.defaultHours },
                set: { hours in Task { await model.setBackgroundChecks(hours: hours) } })) {
                ForEach(BackgroundCheck.intervals, id: \.self) { h in
                    Text(h == 24 ? "Once a day" : h == 1 ? "Every hour" : "Every \(h) hours").tag(h)
                }
            }
            .disabled(model.config.backgroundCheckHours == nil)
            .accessibilityIdentifier("settings.backgroundInterval")
            if let problem = model.backgroundCheckProblem {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("settings.backgroundCheckProblem")
            } else {
                Text("Sends a notification when updates are available. Nothing is downloaded until you open Reforge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Import Addons from CurseForge App") { model.reimportFromCurseForge() }
                .accessibilityIdentifier("settings.import")
        }
        .padding(20)
        .frame(width: 520)
        .onDisappear { model.saveAPIKey(); model.save() }
        .onChange(of: model.config.addonsPath) { model.save() }
        .onChange(of: model.config.gameVersionTypeId) { model.save() }
        .onChange(of: model.config.allowPrerelease) { model.save() }
    }
}
