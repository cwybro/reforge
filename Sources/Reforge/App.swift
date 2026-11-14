import SwiftUI
import AppKit

/// Quit when the window closes so the app uses nothing while you're not looking at it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ReforgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = Model()

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
            Button { Task { await model.checkForUpdates() } } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.checking ? 360 : 0))
                    .animation(model.checking ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                               value: model.checking)
            }
            .buttonStyle(CircleIconButtonStyle())
            .help("Check for updates (⌘R)")
            .disabled(!model.hasKey || model.checking)
            Button { Task { await model.updateAll() } } label: {
                Label(model.updatable.isEmpty ? "Update All" : "Update All (\(model.updatable.count))",
                      systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(GlowButtonStyle(compact: true))
            .disabled(model.updatable.isEmpty)
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
                Text(addon.folders.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            versions
                .frame(maxWidth: 280, alignment: .trailing)
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
        case .working:
            ProgressView().controlSize(.small)
        case .updateAvailable:
            Button("Update") { Task { await model.update(addon) } }
                .buttonStyle(GlowButtonStyle(compact: true))
        case .failed(let err):
            Button { Task { await model.update(addon) } } label: {
                Label("Retry", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(QuietButtonStyle(tint: Theme.magenta))
            .help(err)
        }
    }
}

private struct StatusBar: View {
    let model: Model

    var body: some View {
        HStack {
            Text(model.message ?? (model.lastChecked.map { "Checked at \($0.formatted(date: .omitted, time: .shortened))" } ?? " "))
                .lineLimit(1)
            Spacer()
            Text("\(model.config.addons.count) addon\(model.config.addons.count == 1 ? "" : "s")")
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

struct AddSheet: View {
    let model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an Addon")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Paste a CurseForge link, slug, or project ID.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
            TextField("https://www.curseforge.com/wow/addons/…", text: $text)
                .textFieldStyle(.plain)
                .padding(11)
                .background(Card())
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Install", action: submit)
                    .buttonStyle(GlowButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(AppBackground())
        .preferredColorScheme(.dark)
    }

    private func submit() {
        let input = text
        dismiss()
        Task { await model.add(input) }
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

struct SettingsView: View {
    @Bindable var model: Model

    var body: some View {
        Form {
            SecureField("CurseForge API key", text: $model.apiKey)
                .onSubmit { model.saveAPIKey() }
            HStack {
                TextField("AddOns folder", text: $model.config.addonsPath)
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false
                    p.directoryURL = model.addonsDir
                    if p.runModal() == .OK, let u = p.url { model.config.addonsPath = u.path }
                }
            }
            Picker("Game version", selection: $model.config.gameVersionTypeId) {
                Text("Retail").tag(517)
                Text("Classic Era").tag(67408)
                Text("Mists Classic").tag(79434)
                Text("Anniversary").tag(73246)
            }
            Toggle("Include beta/alpha releases", isOn: $model.config.allowPrerelease)
            Button("Import Addons from CurseForge App") { model.reimportFromCurseForge() }
        }
        .padding(20)
        .frame(width: 520)
        .onDisappear { model.saveAPIKey(); model.save() }
        .onChange(of: model.config.addonsPath) { model.save() }
        .onChange(of: model.config.gameVersionTypeId) { model.save() }
        .onChange(of: model.config.allowPrerelease) { model.save() }
    }
}
