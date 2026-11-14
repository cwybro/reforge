import SwiftUI
import AppKit

// First-run welcome flow: Welcome → AddOns folder → API key → Import → Done.

enum Theme {
    static let navy    = Color(red: 0.05, green: 0.04, blue: 0.15)
    static let purple  = Color(red: 0.25, green: 0.10, blue: 0.46)
    static let violet  = Color(red: 0.55, green: 0.25, blue: 1.00)
    static let magenta = Color(red: 1.00, green: 0.31, blue: 0.85)
    static let cyan    = Color(red: 0.31, green: 0.94, blue: 1.00)
    static let gold    = Color(red: 1.00, green: 0.83, blue: 0.42)
}

struct OnboardingView: View {
    @Bindable var model: Model
    @State private var step = 0
    @State private var forward = true
    private let lastStep = 4

    /// Pointer position relative to the window centre, from -1 to 1 on each axis.
    @State private var pointer = CGPoint.zero

    var body: some View {
        GeometryReader { geo in
            content
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        pointer = CGPoint(x: (p.x / max(geo.size.width, 1)) * 2 - 1,
                                          y: (p.y / max(geo.size.height, 1)) * 2 - 1)
                    case .ended:
                        pointer = .zero
                    }
                }
        }
        .environment(\.parallax, pointer)
        .ignoresSafeArea()
    }

    private var content: some View {
        ZStack {
            MagicBackground()
            VStack(spacing: 0) {
                ZStack {
                    page
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                StepDots(count: lastStep - 1, current: step - 1)
                    .opacity(step == 0 || step == lastStep ? 0 : 1)
                    .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: WelcomeStep(next: next)
        case 1: FolderStep(model: model, next: next, back: back)
        case 2: KeyStep(model: model, next: next, back: back)
        case 3: ImportStep(model: model, next: next, back: back)
        default: DoneStep(count: model.config.addons.count) {
            withAnimation(.easeInOut(duration: 0.55)) { model.finishOnboarding() }
        }
        }
    }

    // Set the direction first, then animate the page change on the next runloop
    // so the outgoing page picks up the right exit edge.
    private func go(_ delta: Int) {
        forward = delta > 0
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { step += delta }
        }
    }
    private func next() { go(1) }
    private func back() { go(-1) }
}

// MARK: - Steps

struct WelcomeStep: View {
    let next: () -> Void
    @Environment(\.parallax) private var parallax
    @Environment(\.controlActiveState) private var activeState
    @State private var appear = false

    /// Animate only while Reforge is the active app.
    private var animating: Bool { activeState != .inactive }

    var body: some View {
        // Spacing groups the content: icon, then name + tagline as a pair,
        // then the description, the feature pills, and finally the button.
        VStack(spacing: 0) {
            FloatingIcon(active: animating)
                .frame(width: 164, height: 164)
                .offset(x: parallax.x * 8, y: parallax.y * 8)
                .animation(.spring(response: 0.9, dampingFraction: 0.85), value: parallax)

            VStack(spacing: 6) {
                Text("Reforge")
                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.gold], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Theme.gold.opacity(0.45), radius: 12)
                Text("Your addons, freshly forged.")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.top, 16)

            Text("The fast, ad-free addon updater for World of Warcraft.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .padding(.top, 18)

            HStack(spacing: 10) {
                FeaturePill(symbol: "bolt.fill", text: "Fast & lightweight", tint: Theme.gold)
                FeaturePill(symbol: "nosign", text: "No ads, ever", tint: Theme.magenta)
                FeaturePill(symbol: "lock.fill", text: "Secure credentials", tint: Theme.cyan)
            }
            .padding(.top, 26)

            Button("Get Started", action: next)
                .buttonStyle(GlowButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.getStarted")
                .padding(.top, 40)
        }
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 16)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { appear = true }
        }
    }
}

struct FolderStep: View {
    @Bindable var model: Model
    let next: () -> Void
    let back: () -> Void

    private var folderExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: model.config.addonsPath, isDirectory: &isDir) && isDir.boolValue
    }

    var body: some View {
        StepLayout(symbol: "folder.fill", title: "Find your AddOns folder",
                   subtitle: "Reforge installs addons straight into this folder.") {
            VStack(spacing: 14) {
                Picker("", selection: $model.config.gameVersionTypeId) {
                    Text("Retail").tag(517)
                    Text("Classic Era").tag(67408)
                    Text("Mists Classic").tag(79434)
                    Text("Anniversary").tag(73246)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: model.config.gameVersionTypeId) { _, new in
                    model.config.addonsPath = Model.defaultAddonsPath(gameVersionTypeId: new)
                }

                HStack(spacing: 10) {
                    Image(systemName: folderExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(folderExists ? Theme.cyan : .orange)
                        .contentTransition(.symbolEffect(.replace))
                    Text(model.config.addonsPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .accessibilityIdentifier("onboarding.folder.path")
                    Spacer(minLength: 8)
                    Button("Change…", action: choose)
                        .accessibilityIdentifier("onboarding.folder.change")
                }
                .padding(12)
                .background(Card())

                if !folderExists {
                    Text("That folder doesn't exist yet. Pick the AddOns folder inside your World of Warcraft install.")
                        .font(.callout).foregroundStyle(.orange.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: folderExists)

            NavRow(id: "onboarding.folder", back: back, title: "Continue", enabled: folderExists) {
                model.save()
                next()
            }
        }
    }

    private func choose() {
        if let url = model.chooseFolder(URL(fileURLWithPath: model.config.addonsPath)) {
            model.config.addonsPath = url.path
        }
    }
}

struct KeyStep: View {
    @Bindable var model: Model
    let next: () -> Void
    let back: () -> Void
    @State private var key = ""
    @State private var verifying = false
    @State private var error: String?

    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        StepLayout(symbol: "key.fill", title: "Connect to CurseForge",
                   subtitle: "Reforge uses CurseForge's official API, which needs a free key.") {
            VStack(spacing: 14) {
                SecureField(model.hasKey ? "Paste a new key to replace your saved one" : "Paste your API key ($2a$10$…)",
                            text: $key)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Card())
                    .onSubmit(verify)
                    .accessibilityIdentifier("onboarding.key.field")

                Group {
                    if let error {
                        Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.magenta)
                            .accessibilityIdentifier("onboarding.key.error")
                    } else if model.hasKey && trimmed.isEmpty {
                        Label("You're connected to CurseForge.", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.cyan)
                    } else {
                        HStack(spacing: 4) {
                            Text("No key yet?").foregroundStyle(.white.opacity(0.6))
                            Link("Get one from CurseForge", destination: URL(string: "https://docs.curseforge.com/")!)
                        }
                    }
                }
                .font(.callout)
                .transition(.opacity)

                if !model.hasKey {
                    Label("Your key is stored securely on this Mac.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: error)

            NavRow(id: "onboarding.key", back: back, title: verifying ? "Checking…" : "Continue",
                   enabled: !verifying && (model.hasKey || !trimmed.isEmpty), action: verify)
        }
    }

    private func verify() {
        let k = trimmed
        guard !k.isEmpty else { if model.hasKey { next() }; return }
        verifying = true
        error = nil
        Task {
            let err = await model.verifyAndSaveKey(k)
            verifying = false
            if let err { error = err } else { next() }
        }
    }
}

struct ImportStep: View {
    @Bindable var model: Model
    let next: () -> Void
    let back: () -> Void
    @State private var found: [TrackedAddon] = []

    private var subtitle: String {
        if !found.isEmpty {
            return "Found \(found.count) addon\(found.count == 1 ? "" : "s") managed by the CurseForge app. Reforge can keep them up to date from now on."
        }
        if !model.config.addons.isEmpty {
            return "Already tracking \(model.config.addons.count) addons. Add more anytime with the + button."
        }
        return "No CurseForge-managed addons found here. You can add addons anytime with the + button."
    }

    var body: some View {
        StepLayout(symbol: "shippingbox.fill", title: "Bring your addons along", subtitle: subtitle) {
            if !found.isEmpty {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                        ForEach(found) { addon in
                            Text(addon.name)
                                .font(.callout)
                                .lineLimit(1)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .frame(maxWidth: .infinity)
                                .background(Capsule().fill(.white.opacity(0.08)))
                                .overlay(Capsule().strokeBorder(Theme.cyan.opacity(0.25)))
                        }
                    }
                }
                .frame(maxHeight: 130)
            }

            NavRow(id: "onboarding.import", back: back,
                   title: found.isEmpty ? "Continue" : "Import \(found.count) Addon\(found.count == 1 ? "" : "s")",
                   enabled: true,
                   skip: found.isEmpty ? nil : next) {
                if !found.isEmpty { model.importAddons(found) }
                next()
            }
        }
        .onAppear { found = model.importCandidates() }
    }
}

struct DoneStep: View {
    let count: Int
    let finish: () -> Void
    @State private var pop = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.gold.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 100))
                    .frame(width: 200, height: 200)
                    .scaleEffect(pop ? 1 : 0.3)
                    .opacity(pop ? 1 : 0)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 78))
                    .foregroundStyle(LinearGradient(colors: [Theme.gold, Theme.magenta], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Theme.gold.opacity(0.7), radius: 18)
                    .scaleEffect(pop ? 1 : 0.2)
                    .rotationEffect(.degrees(pop ? 0 : -40))
            }
            Text("You're all set!")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 10)
            Text(count == 0
                 ? "Add your first addon with the + button."
                 : "Reforge will check your \(count) addon\(count == 1 ? "" : "s") for updates now.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 12)
            Button("Open Reforge", action: finish)
                .buttonStyle(GlowButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.done.open")
                .padding(.top, 38)
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.55).delay(0.15)) { pop = true } }
    }
}

// MARK: - Building blocks

private struct StepLayout<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [Theme.cyan, Theme.magenta], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Theme.magenta.opacity(0.6), radius: 14)
            VStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)
            VStack(spacing: 18) {
                content
            }
            .padding(.top, 32)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 36)
    }
}

private struct NavRow: View {
    /// Accessibility identifier prefix: "<id>.back", "<id>.skip", "<id>.continue".
    let id: String
    var back: (() -> Void)?
    let title: String
    let enabled: Bool
    var skip: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        HStack {
            if let back { Button("Back", action: back).buttonStyle(QuietButtonStyle()).accessibilityIdentifier("\(id).back") }
            Spacer()
            if let skip { Button("Skip", action: skip).buttonStyle(QuietButtonStyle()).accessibilityIdentifier("\(id).skip") }
            Button(title, action: action)
                .buttonStyle(GlowButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled)
                .accessibilityIdentifier("\(id).continue")
        }
        .padding(.top, 22)
    }
}

/// Progress indicator: grey dots with one gradient pill that slides and stretches to the
/// current step, while the slot it leaves shrinks back to a dot at the same pace.
private struct StepDots: View {
    let count: Int
    let current: Int
    @Namespace private var dots

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                ZStack {
                    Capsule().fill(Color.white.opacity(0.22))
                    if i == current {
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.cyan, Theme.magenta], startPoint: .leading, endPoint: .trailing))
                            .matchedGeometryEffect(id: "active", in: dots)
                    }
                }
                .frame(width: i == current ? 26 : 8, height: 8)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: current)
    }
}

private struct FeaturePill: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        Label {
            Text(text).foregroundStyle(.white.opacity(0.85))
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35)))
    }
}

private struct ParallaxKey: EnvironmentKey {
    static let defaultValue = CGPoint.zero
}

extension EnvironmentValues {
    /// Mouse position over the onboarding window, from -1 to 1 on each axis.
    var parallax: CGPoint {
        get { self[ParallaxKey.self] }
        set { self[ParallaxKey.self] = newValue }
    }
}

struct Card: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

struct MagicBackground: View {
    var body: some View {
        ZStack {
            Theme.navy
            RadialGradient(colors: [Theme.purple, Theme.navy], center: UnitPoint(x: 0.5, y: 0.32), startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Color.orange.opacity(0.16), .clear], center: UnitPoint(x: 0.5, y: 1.1), startRadius: 0, endRadius: 380)
            Twinkles()
        }
        .ignoresSafeArea()
    }
}

/// Sparkles that twinkle, hover up and down, and drift against the mouse.
/// The looping animations run in Core Animation (the system render server), so the
/// app itself does no per-frame work; only mouse movement updates the parallax.
private struct Twinkles: View {
    @Environment(\.parallax) private var parallax
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        SparkleField(parallax: parallax, active: activeState != .inactive)
            .allowsHitTesting(false)
    }
}

private struct SparkleField: NSViewRepresentable {
    var parallax: CGPoint
    var active: Bool

    func makeNSView(context: Context) -> SparkleFieldView { SparkleFieldView() }

    func updateNSView(_ view: SparkleFieldView, context: Context) {
        view.setParallax(parallax)
        view.setPaused(!active)
    }
}

final class SparkleFieldView: NSView {
    private struct Star { let x, y, size, phase, depth: CGFloat; let tint: NSColor }
    private static let magenta = NSColor(red: 1.00, green: 0.31, blue: 0.85, alpha: 1)
    private static let cyan = NSColor(red: 0.31, green: 0.94, blue: 1.00, alpha: 1)
    private let stars: [Star] = [
        Star(x: 0.10, y: 0.16, size: 11, phase: 0.0, depth: 0.6, tint: SparkleFieldView.cyan),
        Star(x: 0.87, y: 0.13, size: 16, phase: 0.6, depth: 1.0, tint: SparkleFieldView.magenta),
        Star(x: 0.93, y: 0.60, size: 9, phase: 1.1, depth: 0.45, tint: SparkleFieldView.cyan),
        Star(x: 0.07, y: 0.70, size: 14, phase: 0.3, depth: 0.9, tint: SparkleFieldView.magenta),
        Star(x: 0.72, y: 0.88, size: 8, phase: 0.9, depth: 0.35, tint: SparkleFieldView.cyan),
        Star(x: 0.27, y: 0.90, size: 7, phase: 1.4, depth: 0.3, tint: SparkleFieldView.magenta),
        Star(x: 0.63, y: 0.07, size: 7, phase: 0.2, depth: 0.3, tint: SparkleFieldView.cyan),
        Star(x: 0.20, y: 0.42, size: 6, phase: 1.7, depth: 0.25, tint: SparkleFieldView.magenta),
        Star(x: 0.80, y: 0.38, size: 6, phase: 0.5, depth: 0.25, tint: SparkleFieldView.cyan),
        Star(x: 0.38, y: 0.12, size: 9, phase: 1.2, depth: 0.55, tint: SparkleFieldView.magenta),
        Star(x: 0.55, y: 0.95, size: 10, phase: 0.8, depth: 0.7, tint: SparkleFieldView.cyan),
        Star(x: 0.96, y: 0.85, size: 12, phase: 0.4, depth: 0.8, tint: SparkleFieldView.magenta),
    ]
    /// One layer per star that carries the parallax offset; the looping animations live on its children.
    private var anchors: [CALayer] = []
    /// Child of each anchor that carries only the mouse-parallax offset, so resizing never animates.
    private var shifts: [CALayer] = []
    private var parallax = CGPoint.zero

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
        for star in stars {
            let anchor = CALayer()
            let shift = CALayer()
            let bob = CALayer()
            let halo = CAGradientLayer()
            halo.type = .radial
            halo.colors = [star.tint.withAlphaComponent(0.7).cgColor, star.tint.withAlphaComponent(0).cgColor]
            halo.startPoint = CGPoint(x: 0.5, y: 0.5)
            halo.endPoint = CGPoint(x: 1, y: 1)
            let haloSide = star.size * 3.0
            halo.bounds = CGRect(x: 0, y: 0, width: haloSide, height: haloSide)
            let sparkle = CALayer()
            // The symbol image has built-in padding, so draw it larger than its nominal size.
            sparkle.bounds = CGRect(x: 0, y: 0, width: star.size * 1.5, height: star.size * 1.5)
            sparkle.contentsGravity = .resizeAspect
            sparkle.contents = Self.whiteSparkle(symbol, side: star.size * 1.5)
            let twinkle = CALayer()
            twinkle.addSublayer(halo)
            twinkle.addSublayer(sparkle)
            bob.addSublayer(twinkle)
            shift.addSublayer(bob)
            anchor.addSublayer(shift)
            shifts.append(shift)
            layer?.addSublayer(anchor)
            anchors.append(anchor)

            // Hover up and down.
            let hover = CABasicAnimation(keyPath: "transform.translation.y")
            let amount = 10 * star.depth + 4
            hover.fromValue = -amount
            hover.toValue = amount
            hover.duration = 2.8 + Double(star.phase)
            hover.autoreverses = true
            hover.repeatCount = .infinity
            hover.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            hover.timeOffset = Double(star.phase) * 1.3
            bob.add(hover, forKey: "hover")

            // Twinkle: fade and pulse together.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.3
            fade.toValue = 0.4 + 0.5 * star.depth
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.65
            pulse.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [fade, pulse]
            group.duration = 1.9
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.timeOffset = Double(star.phase)
            twinkle.add(group, forKey: "twinkle")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Renders the sparkle symbol as a solid white bitmap at Retina resolution.
    private static func whiteSparkle(_ symbol: NSImage?, side: CGFloat) -> CGImage? {
        guard let symbol else { return nil }
        let px = Int(ceil(side * 2))
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        symbol.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)
        return ctx.makeImage()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        positionAnchors()
        CATransaction.commit()
    }

    func setParallax(_ p: CGPoint) {
        guard p != parallax else { return }
        parallax = p
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (star, shift) in zip(stars, shifts) {
            let drift = 34 * star.depth
            shift.setAffineTransform(CGAffineTransform(translationX: -p.x * drift, y: -p.y * drift))
        }
        CATransaction.commit()
    }

    /// Places each star at its spot in the window. Called during layout with animations off,
    /// so stars track the window edges immediately while it resizes.
    private func positionAnchors() {
        for (star, anchor) in zip(stars, anchors) {
            anchor.position = CGPoint(x: bounds.width * star.x, y: bounds.height * star.y)
        }
    }

    func setPaused(_ paused: Bool) {
        guard let layer else { return }
        CoreAnimationPause.set(paused, on: layer)
    }
}

/// The welcome icon with its soft glow, floating gently. Animated by Core Animation.
private struct FloatingIcon: NSViewRepresentable {
    var active: Bool

    func makeNSView(context: Context) -> FloatingIconView { FloatingIconView() }
    func updateNSView(_ view: FloatingIconView, context: Context) {
        guard let layer = view.layer else { return }
        CoreAnimationPause.set(!active, on: layer)
    }
}

final class FloatingIconView: NSView {
    private let float = CALayer()
    private let glow = CAGradientLayer()
    private let icon = CALayer()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        glow.type = .radial
        glow.colors = [NSColor(red: 1.00, green: 0.31, blue: 0.85, alpha: 0.55).cgColor,
                       NSColor(red: 0.55, green: 0.25, blue: 1.00, alpha: 0.18).cgColor,
                       NSColor.clear.cgColor]
        glow.locations = [0.28, 0.6, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        icon.contents = NSApp.applicationIconImage
        icon.contentsGravity = .resizeAspect
        float.addSublayer(glow)
        float.addSublayer(icon)
        layer?.addSublayer(float)

        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = 7
        bob.toValue = -7
        bob.duration = 2.6
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        float.add(bob, forKey: "float")

        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.45
        breathe.toValue = 1
        breathe.duration = 2.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(breathe, forKey: "breathe")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        float.frame = bounds
        icon.frame = bounds
        glow.bounds = CGRect(x: 0, y: 0, width: 280, height: 280)
        glow.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}

/// Pauses or resumes every Core Animation animation under a layer.
enum CoreAnimationPause {
    static func set(_ paused: Bool, on layer: CALayer) {
        if paused, layer.speed != 0 {
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = now
        } else if !paused, layer.speed == 0 {
            let pausedAt = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        }
    }
}

struct GlowButtonStyle: ButtonStyle {
    /// Smaller variant for rows and the header.
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12.5 : 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 14 : 28).padding(.vertical, compact ? 6 : 11)
            .background(Capsule().fill(LinearGradient(colors: [Theme.magenta, Theme.violet], startPoint: .leading, endPoint: .trailing)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
            .shadow(color: Theme.magenta.opacity(isEnabled ? 0.6 : 0), radius: configuration.isPressed ? 4 : (compact ? 8 : 16))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct QuietButtonStyle: ButtonStyle {
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(tint.opacity(configuration.isPressed ? 0.4 : 0.75))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
    }
}
