import AppKit
import SwiftUI

@main
struct MoviApp: App {
    // No longer owned here — each window/tab that `WindowGroup` creates now
    // owns its own `EditorViewModel` (a `@StateObject` in `ContentView`), so
    // that native window tabbing (the "Show Tab Bar"/"Add Tab" options that
    // show up in the View menu once a `WindowGroup`-based app has more than
    // one window) can hold a genuinely different video per tab instead of
    // every tab showing whatever the one shared instance last had loaded.
    // Menu commands below reach whichever window/tab is actually focused via
    // `EditorCommands`' `@FocusedValue(\.editorViewModel)`, fed by
    // `ContentView`'s own `.focusedSceneValue(\.editorViewModel, viewModel)`.
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        // Without this, `WindowGroup` keeps a hand on the window's size
        // itself — recomputing and reapplying its own idea of the "right"
        // size for the content on its own schedule, which was silently
        // undoing `ContentView`'s programmatic resize on video load (the
        // window would open sized wrong, with black bars, until the
        // person dragged a corner even one pixel — interactive resize
        // goes through a different AppKit path that `WindowGroup` doesn't
        // fight). `.contentSize` hands sizing over to the content's own
        // min/max/current size instead — i.e. to `ContentView`'s own
        // `.frame(...)` and the `NSWindow` properties/delegate it sets in
        // `configureWindow`/`WindowSizingDelegate` — and leaves it there.
        .windowResizability(.contentSize)
        .commands {
            EditorCommands()
        }
    }
}

/// Menu commands that act on whichever window/tab is currently focused,
/// rather than a single app-wide `EditorViewModel` — necessary now that
/// every window/tab owns its own independent instance (see `MoviApp` above).
/// `viewModel` is `nil` only in the brief window before any `ContentView`
/// has appeared/published its `.focusedSceneValue`; every button below is
/// written to no-op or disable itself gracefully in that case rather than
/// force-unwrap.
struct EditorCommands: Commands {
    @FocusedValue(\.editorViewModel) private var viewModel: EditorViewModel?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Otwórz wideo…") {
                viewModel?.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(viewModel == nil)

            Button("Dołącz wideo na końcu…") {
                viewModel?.presentAppendPanel()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(viewModel == nil)

            Divider()

            Button("Eksportuj…") {
                viewModel?.presentExportPanel()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(viewModel?.segments.isEmpty ?? true)
        }

        CommandGroup(after: .undoRedo) {
            Button("Cofnij edycję") {
                viewModel?.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(viewModel?.canUndo ?? false))
        }

        // Replaces the system-generated "About Movi" (which only ever shows
        // whatever's in Info.plist) with our own, simpler author/version
        // panel, via the same standard About panel AppKit itself uses —
        // `orderFrontStandardAboutPanel` — just fed custom `options`.
        CommandGroup(replacing: .appInfo) {
            Button("O Movi") {
                AboutPanel.show()
            }
        }
    }
}

/// Exposes the focused window/tab's `EditorViewModel` to `EditorCommands`
/// above, via SwiftUI's standard focused-value mechanism — the counterpart
/// to `ContentView`'s `.focusedSceneValue(\.editorViewModel, viewModel)`.
private struct EditorViewModelKey: FocusedValueKey {
    typealias Value = EditorViewModel
}

extension FocusedValues {
    var editorViewModel: EditorViewModel? {
        get { self[EditorViewModelKey.self] }
        set { self[EditorViewModelKey.self] = newValue }
    }
}

/// The standard macOS About panel, fed just an author line and version —
/// no license text.
enum AboutPanel {
    static func show() {
        let authorParagraph = NSMutableParagraphStyle()
        authorParagraph.alignment = .center

        let credits = NSAttributedString(
            string: "Made by Marcin Lipiński",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .paragraphStyle: authorParagraph
            ]
        )

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: "2.0",
            .credits: credits
        ])
    }
}
