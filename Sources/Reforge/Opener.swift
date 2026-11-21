import AppKit
import SwiftUI

/// Opening web pages and revealing files in Finder, in one place: the E2E stub mode records
/// these instead (see E2EStubs.swift), so tests can check them without opening anything.
@MainActor
enum Opener {
    static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    static var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
}

extension View {
    /// Routes SwiftUI `Link`s through `Opener`.
    func opensLinksWithOpener() -> some View {
        environment(\.openURL, OpenURLAction { url in Opener.open(url); return .handled })
    }

    /// Lets VoiceOver and other assistive tools (and the E2E tests) step a menu picker through
    /// `options` with increment/decrement, without opening its menu.
    func adjustable<T: Equatable>(_ selection: Binding<T>, through options: [T]) -> some View {
        accessibilityAdjustableAction { direction in
            guard !options.isEmpty else { return }
            let i = options.firstIndex(of: selection.wrappedValue) ?? -1
            switch direction {
            case .increment: selection.wrappedValue = options[min(i + 1, options.count - 1)]
            case .decrement: selection.wrappedValue = options[max(i - 1, 0)]
            @unknown default: break
            }
        }
    }
}
