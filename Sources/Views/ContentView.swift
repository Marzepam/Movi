import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    // Owned here (not injected via `@EnvironmentObject` from `MoviApp`
    // anymore) so that every window this `WindowGroup` creates — including
    // a new *tab*, which macOS's native window-tabbing spawns as a
    // genuinely separate scene instance under the hood — gets its own,
    // independent `EditorViewModel` and can hold its own video, instead of
    // every window/tab sharing one app-wide instance and all showing
    // whatever the last-touched one was editing. `MoviApp`'s menu commands
    // reach whichever window/tab is actually in front through
    // `.focusedSceneValue(\.editorViewModel, viewModel)` below and
    // `EditorCommands`' `@FocusedValue` — see that file.
    @StateObject private var viewModel = EditorViewModel()
    @State private var isTargeted = false
    @State private var keyMonitor: Any?
    @State private var hostWindow: NSWindow?
    /// Strong reference to the delegate installed on `hostWindow` — kept
    /// alive here because `NSWindow.delegate` itself is a weak property.
    /// See `WindowSizingDelegate` at the bottom of this file for why this
    /// exists at all: it's the actual, reliable enforcement of both the
    /// video's aspect ratio and the floating bar's minimum size, on every
    /// kind of resize (live drag *and* our own programmatic one) — the
    /// `NSWindow.contentAspectRatio`/`minSize` properties set below are
    /// kept too (they drive the live-resize cursor/corner-drag feel
    /// correctly on their own, confirmed by testing), but proved
    /// unreliable on their own for a resize applied *programmatically*,
    /// right when a video loads.
    @State private var windowDelegate = WindowSizingDelegate()
    /// Whether we've already sized the window once for the currently loaded
    /// video. Set back to `false` whenever the timeline empties out, so the
    /// next video that's opened gets a fresh initial size again — but a
    /// mid-edit change (split/trim/append) never yanks a window the person
    /// has already positioned or resized.
    @State private var hasSizedWindowForVideo = false
    /// The last `viewModel.openGeneration` we've already resized the window
    /// for. When it's behind the view model's current value, a brand-new
    /// video was just opened (replacing the whole timeline), which should
    /// always resize the window fresh — even if a differently-shaped video
    /// was already open and `hasSizedWindowForVideo` would otherwise skip it.
    @State private var lastHandledOpenGeneration = 0
    /// height / width of the video the window was last actually sized for.
    /// `undo()` can restore a differently-shaped video without bumping
    /// `openGeneration` (that only advances on a brand-new Open — see
    /// `lastHandledOpenGeneration` above), so this is the mechanism that
    /// still catches the shape change and forces a fresh resize in that
    /// case, instead of silently leaving the window sized for the video
    /// that was just undone away.
    @State private var lastAppliedAspectRatio: CGFloat?
    /// Whether the floating bar and the window's own close/miniaturize/
    /// zoom buttons are currently shown. Both fade together (500ms) —
    /// see `showControls`/`hideControlsNow`/`scheduleAutoHide` below.
    @State private var controlsVisible = true
    @State private var hideControlsWorkItem: DispatchWorkItem?
    /// The window's frame (position + size) right before it entered native
    /// fullscreen — captured on `willEnterFullScreenNotification`, spent on
    /// `didExitFullScreenNotification`. Lets exiting fullscreen put the
    /// window back exactly where the person had it (dragged/resized by
    /// hand), instead of the fresh fit-to-video-and-recenter that used to
    /// run unconditionally on every exit.
    @State private var preFullScreenFrame: NSRect?
    /// The video's aspect ratio at the moment fullscreen was entered —
    /// compared against the current one on exit (see the exit handler) to
    /// tell "same video, restore where it was" apart from "a differently
    /// shaped video got opened while fullscreen, so that saved frame no
    /// longer fits and needs a fresh fit instead".
    @State private var preFullScreenAspectRatio: CGFloat?
    /// Mirrors the unsaved-changes prompt for opening a new video, but for
    /// closing the window (red button, ⌘W, File ▸ Close Window) instead —
    /// see `handleWindowShouldClose()`/the alert bound to this below.
    @State private var pendingWindowClose = false
    /// Set right before calling `hostWindow?.close()` a second time after
    /// the person has already resolved the unsaved-changes prompt (Usuń, or
    /// Zapisz once the save completes) — makes `handleWindowShouldClose()`
    /// wave the close straight through instead of asking again.
    @State private var forceWindowClose = false
    /// Set while waiting for a "Zapisz"-triggered export (from the close
    /// prompt) to actually finish — watched by the `onChange(of:
    /// viewModel.hasUnsavedChanges)` below, which is what actually closes
    /// the window once the save succeeds (export is asynchronous, so this
    /// can't just happen inline in the button action).
    @State private var closeWindowAfterSave = false
    /// Whether the mouse is currently directly over the floating bar itself
    /// — set by a plain `.onHover` on the bar (see `body`), which AppKit
    /// fires reliably on enter/exit regardless of whether the mouse is
    /// moving or sitting still. `scheduleAutoHide` checks this right before
    /// hiding and refuses to hide the bar while it's `true`; leaving the
    /// bar's bounds (this flips back to `false`) lets the normal 3s
    /// inactivity countdown apply again from that point on.
    @State private var isHoveringFloatingBar = false

    var body: some View {
        // A single top-level `GeometryReader` is the one source of truth for
        // "the window's actual current content size" — the video, the
        // floating bar's centering/10%-from-bottom positioning, and the
        // drag-highlight overlay all read from this same `geo`, so they can
        // never disagree with each other (each used to sit in its own
        // sibling, which risked reading a slightly different size if any of
        // them resolved geometry on a different layout pass — including in
        // fullscreen, where the window's size changes without going through
        // `configureWindow` at all).
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if viewModel.segments.isEmpty {
                    emptyState
                } else {
                    VideoPlayerView(player: viewModel.player)
                        .ignoresSafeArea()
                }

                // Zero-size helper that just resolves the hosting `NSWindow`
                // — needed so we can lock the window's own aspect ratio to
                // the video's (see `configureWindow`), which is what makes
                // the video fill the window edge-to-edge with no black
                // bars, even as the window gets resized later.
                WindowAccessor { window in
                    guard hostWindow !== window else { return }
                    hostWindow = window
                    windowDelegate.install(on: window)
                    windowDelegate.shouldCloseHandler = { handleWindowShouldClose() }
                    // Without this, macOS's window-state restoration
                    // (Resume) silently remembers this exact window's
                    // frame across a full quit/relaunch, and the next
                    // launch's still-empty "Otwórz wideo…" window would
                    // open wherever/whatever-shape the *previous* video's
                    // window last was, instead of the plain, centered
                    // default it should start from every time.
                    window.isRestorable = false
                    if viewModel.videoSize == nil {
                        centerOnScreen(window)
                    }
                    configureWindow(for: viewModel.videoSize)
                    updateWindowTitle()
                }
                .frame(width: 0, height: 0)

                VStack {
                    Spacer()
                    if !viewModel.segments.isEmpty {
                        HStack {
                            Spacer(minLength: 0)
                            FloatingControlBar(
                                viewModel: viewModel,
                                onOpen: viewModel.presentOpenPanel,
                                onAppend: viewModel.presentAppendPanel,
                                // `presentExportPanel()` now returns `Bool`
                                // (see `EditorViewModel`) so the close-window
                                // flow can tell whether export actually
                                // started — wrapped in a closure here since
                                // `onExport` (an ordinary button action)
                                // doesn't care and expects `Void`.
                                onExport: { viewModel.presentExportPanel() }
                            )
                            // AppKit's own enter/exit tracking for this
                            // view's bounds — fires reliably even while the
                            // mouse just sits still inside them (unlike
                            // `onContinuousHover`, which only fires on
                            // actual movement). `scheduleAutoHide` reads
                            // `isHoveringFloatingBar` right before hiding and
                            // refuses to hide the bar while the mouse is
                            // still on it.
                            .onHover { hovering in
                                isHoveringFloatingBar = hovering
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                // Bar's bottom edge sits 10% of the window's height up from
                // the bottom, rather than flush against it — proportional
                // to the window's real current height (`geo`), so it's
                // always exactly 10%, the same in a normal window or in
                // fullscreen, whatever video is loaded.
                .padding(.bottom, geo.size.height * 0.1)
                // Auto-hidden after 3s of mouse inactivity, or the instant
                // the mouse leaves the window — see `showControls`/
                // `hideControlsNow` below, driven by `.onContinuousHover`
                // on the whole `ZStack`. `allowsHitTesting(false)` while
                // hidden so an invisible bar can't still catch clicks.
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .animation(.easeInOut(duration: 0.5), value: controlsVisible)

                if isTargeted {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.accentColor, lineWidth: 4)
                        .padding(20)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                if viewModel.isExporting {
                    exportOverlay
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Drives the floating bar's + window buttons' auto-hide: any
            // mouse movement anywhere in the window shows both and resets
            // the 3s inactivity countdown (`.active`); the mouse leaving
            // the window's bounds hides both immediately (`.ended`),
            // rather than waiting out that countdown (which only applies
            // to inactivity *inside* the window). Whether the bar actually
            // hides once that countdown fires is decided in
            // `scheduleAutoHide` itself, via `isHoveringFloatingBar`.
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active:
                    showControls()
                case .ended:
                    hideControlsNow()
                }
            }
        }
        // Only a floor for the empty state (before any video is loaded, or
        // if it's a plain resizable window) — matches
        // `FloatingControlBar.footprintSize` scaled the same way
        // `configureWindow` scales it for `window.minSize`, so SwiftUI's
        // own idea of the window's minimum size (relevant because of
        // `.windowResizability(.contentSize)` on the `WindowGroup` in
        // `MoviApp`) never disagrees with what `WindowSizingDelegate`
        // enforces once a video is loaded.
        .frame(minWidth: FloatingControlBar.minWindowWidth,
               minHeight: FloatingControlBar.footprintSize.height / 0.9)
        .onDrop(of: [.movie, .video, .audiovisualContent], isTargeted: $isTargeted, perform: handleDrop)
        .onAppear {
            installKeyMonitor()
            scheduleAutoHide()
        }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: viewModel.videoSize) { _, newSize in
            configureWindow(for: newSize)
            // Catches the timeline going empty→non-empty or non-empty→empty
            // (delete-last-segment, undo back past the first clip) — a
            // brand-new *same-sized* video replacing the current one is
            // caught separately below, since `videoSize` alone wouldn't
            // change in that case.
            updateWindowTitle()
        }
        .onChange(of: viewModel.openGeneration) { _, _ in
            // A fresh Open (⌘O/folder/drop-on-empty-state) always replaces
            // the tab's video identity, even when the new file happens to
            // share the previous one's pixel dimensions — in which case
            // `videoSize` itself wouldn't change and the `onChange` above
            // wouldn't fire on its own.
            updateWindowTitle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { notification in
            // Captured right before the fullscreen transition starts, while
            // `window.frame` is still the ordinary windowed one — whatever
            // the person last dragged/resized it to. Spent in the
            // `didExitFullScreenNotification` handler below to put the
            // window back exactly there instead of re-centering it fresh.
            guard let window = notification.object as? NSWindow, window === hostWindow else { return }
            preFullScreenFrame = window.frame
            preFullScreenAspectRatio = lastAppliedAspectRatio
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === hostWindow else { return }

            let currentAspectRatio = viewModel.videoSize.flatMap { size -> CGFloat? in
                guard size.width > 0, size.height > 0 else { return nil }
                return size.height / size.width
            }
            let aspectUnchanged: Bool
            switch (currentAspectRatio, preFullScreenAspectRatio) {
            case let (.some(current), .some(previous)):
                aspectUnchanged = abs(current - previous) < 0.001
            case (.none, .none):
                aspectUnchanged = true
            default:
                aspectUnchanged = false
            }

            if let savedFrame = preFullScreenFrame, aspectUnchanged {
                // Same video (or still none) as when fullscreen was
                // entered — put the window back exactly where the person
                // had it, rather than running the fresh fit-and-center
                // below, which used to run unconditionally on every exit
                // and made a manually resized/positioned window snap back
                // to a freshly-centered, default-sized one every time.
                hasSizedWindowForVideo = true
                window.setFrame(savedFrame, display: true, animate: false)
                // Same race as the fresh-fit path below: AppKit's own
                // restore-to-previous-frame animation is often still
                // running when this notification fires, so a second,
                // idempotent application a beat later makes sure ours is
                // the one left standing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    window.setFrame(savedFrame, display: true, animate: false)
                }
            } else {
                // No saved frame (shouldn't normally happen — entering
                // fullscreen always captures one first), or a differently
                // shaped video was opened while fullscreen: the saved
                // frame's shape no longer matches the aspect-locked
                // window, so fall back to a fresh fit instead of forcing a
                // stale size onto the new video.
                hasSizedWindowForVideo = false
                configureWindow(for: viewModel.videoSize)
                if let videoSize = viewModel.videoSize, videoSize.width > 0, videoSize.height > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        applyWindowSize(for: videoSize)
                    }
                }
            }

            preFullScreenFrame = nil
            preFullScreenAspectRatio = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            // Closing the window doesn't quit the app (it stays running —
            // in the Dock/menu bar — since there's no menu item or Dock
            // icon click to reopen a video otherwise), so without this the
            // `AVPlayer` just keeps playing in the background, unseen and
            // unheard-of only until the audio gives it away. Pausing here
            // (rather than tearing down the player entirely) is enough:
            // there's nothing left on screen driving playback forward
            // either way, and it keeps the window's close behavior simple.
            guard let window = notification.object as? NSWindow, window === hostWindow else { return }
            viewModel.player.pause()
        }
        .alert("Błąd", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        // Asking to open a new video (folder icon / ⌘O) while the current
        // timeline has unsaved edits routes through `requestOpen(url:)`,
        // which stashes the URL here instead of opening it immediately —
        // this alert is what actually decides what happens to it. Doesn't
        // fire at all for append or drag-and-drop onto an existing video
        // (those never touch `pendingOpenURL`), and doesn't fire when
        // there's nothing unsaved to lose (see `requestOpen(url:)`).
        .alert("Niezapisane zmiany", isPresented: Binding(
            get: { viewModel.pendingOpenURL != nil },
            set: { if !$0 { viewModel.cancelPendingOpen() } }
        )) {
            Button("Zapisz") { viewModel.saveThenCancelPendingOpen() }
            Button("Usuń", role: .destructive) { viewModel.discardAndOpenPending() }
            Button("Anuluj", role: .cancel) { viewModel.cancelPendingOpen() }
        } message: {
            Text("Bieżące wideo ma niezapisane zmiany. Co zrobić z nimi przed otwarciem nowego pliku?")
        }
        // Mirrors the alert above, but for closing the window itself (red
        // button / ⌘W / File ▸ Close Window) instead of opening a different
        // video — see `WindowSizingDelegate.windowShouldClose(_:)` /
        // `handleWindowShouldClose()`.
        .alert("Niezapisane zmiany", isPresented: $pendingWindowClose) {
            Button("Zapisz") { saveThenCloseWindow() }
            Button("Usuń", role: .destructive) { discardAndCloseWindow() }
            Button("Anuluj", role: .cancel) { pendingWindowClose = false }
        } message: {
            Text("Bieżące wideo ma niezapisane zmiany. Co zrobić z nimi przed zamknięciem okna?")
        }
        // Actually closes the window once a "Zapisz"-from-close-prompt
        // export finishes — export itself is async, so `saveThenCloseWindow`
        // can't just close inline; it sets `closeWindowAfterSave` and this
        // watches for the save to land (`hasUnsavedChanges` flipping back to
        // `false`) instead.
        .onChange(of: viewModel.hasUnsavedChanges) { _, newValue in
            guard closeWindowAfterSave, newValue == false else { return }
            closeWindowAfterSave = false
            forceWindowClose = true
            hostWindow?.close()
        }
        // Lets Finder's "Otwórz z"/"Open With" (and double-clicking a video
        // file whose default app is Movi) hand a file straight to this
        // window's own `viewModel` — moved here from `MoviApp` now that each
        // window/tab owns an independent `EditorViewModel` rather than
        // sharing one app-wide instance (see the `@StateObject` above).
        .onOpenURL { url in
            viewModel.requestOpen(url: url)
        }
        // Exposes this window/tab's `viewModel` to `MoviApp`'s menu commands
        // (`EditorCommands`, via `@FocusedValue`) so File ▸ Open/Export/Undo
        // etc. act on whichever window or tab is actually in front, instead
        // of a single app-wide instance.
        .focusedSceneValue(\.editorViewModel, viewModel)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.4))
            Text("Otwórz wideo (⌘O) albo przeciągnij plik tutaj")
                .foregroundStyle(.white.opacity(0.6))
            Button("Otwórz wideo…", action: viewModel.presentOpenPanel)
                .buttonStyle(.borderedProminent)
        }
    }

    private var exportOverlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: viewModel.exportProgress)
                .frame(width: 240)
            Text(String(format: String(localized: "Eksportowanie… %d%%", comment: "Export progress overlay, e.g. Exporting… 42%"), Int(viewModel.exportProgress * 100)))
                .font(.caption)
                .foregroundStyle(.white)
            Button("Anuluj") {
                viewModel.cancelExport()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Drag & drop

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let openingEmptyTimeline = viewModel.segments.isEmpty
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                if openingEmptyTimeline {
                    await viewModel.open(url: url)
                } else {
                    await viewModel.append(url: url)
                }
            }
        }
        return true
    }

    // MARK: Keyboard shortcuts

    /// Single-key editing shortcuts (space, arrows, delete, S, [, ]) live here
    /// as a local key monitor. The modifier-based shortcuts (⌘O, ⌘⇧A, ⌘E, ⌘Z)
    /// are wired up as native menu commands in `MoviApp`.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // `addLocalMonitorForEvents` is app-wide, not scoped to this one
            // window — with multiple tabs/windows now each installing their
            // own monitor (one `ContentView` instance per window/tab; see
            // the `@StateObject` above), without this guard a keystroke
            // would fire against whichever monitor happens to run first
            // rather than the window the person is actually looking at.
            guard NSApp.keyWindow === hostWindow else { return event }
            guard !viewModel.segments.isEmpty else { return event }

            if let special = event.specialKey {
                switch special {
                case .leftArrow:
                    viewModel.step(seconds: -1.0 / 30.0)
                    return nil
                case .rightArrow:
                    viewModel.step(seconds: 1.0 / 30.0)
                    return nil
                default:
                    break
                }
            }

            if event.keyCode == 51 || event.keyCode == 117 { // Backspace / Forward Delete
                viewModel.deleteActiveSegment()
                return nil
            }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ":
                viewModel.togglePlayPause()
                return nil
            case "s":
                viewModel.splitAtPlayhead()
                return nil
            case "[":
                viewModel.trimStart()
                return nil
            case "]":
                viewModel.trimEnd()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    // MARK: Auto-hide floating bar + window buttons on inactivity

    /// Shows the floating bar and the window's traffic-light buttons and
    /// restarts the 3s inactivity countdown — called on every mouse
    /// movement inside the window (`.onContinuousHover`'s `.active` phase),
    /// so as long as the mouse keeps moving, both stay visible.
    private func showControls() {
        hideControlsWorkItem?.cancel()
        if !controlsVisible {
            controlsVisible = true
        }
        setWindowButtonsHidden(false)
        scheduleAutoHide()
    }

    /// Hides both immediately, bypassing the 3s countdown — used the
    /// instant the mouse leaves the window (`.onContinuousHover`'s `.ended`
    /// phase); that's a stronger signal than mere inactivity *inside* the
    /// window, which is what the countdown below is for.
    private func hideControlsNow() {
        hideControlsWorkItem?.cancel()
        hideControlsWorkItem = nil
        controlsVisible = false
        setWindowButtonsHidden(true)
    }

    /// (Re)starts the 3s "nothing happened" timer that hides both when the
    /// mouse just sits still inside the window instead of leaving it — but
    /// not if the mouse is currently resting directly on the floating bar
    /// itself (`isHoveringFloatingBar`, kept live by the bar's own
    /// `.onHover`): that's a person reading/about to click something on the
    /// bar, not inactivity, so hiding it out from under the cursor would be
    /// actively unhelpful. Window buttons still fade together with the bar
    /// (unchanged), so this exception keeps both visible in that one case
    /// rather than splitting their behavior apart. The moment the mouse
    /// leaves the bar's bounds, `.onHover` flips this back to `false` and
    /// the very next scheduled check (below) hides both again after its own
    /// full 3s, same as ordinary inactivity anywhere else in the window.
    private func scheduleAutoHide() {
        hideControlsWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            guard !isHoveringFloatingBar else {
                // Still sitting on the bar — keep waiting rather than
                // hiding or giving up on the countdown; once the mouse
                // leaves it, `.onHover` clears the flag and the next fired
                // check here (or a fresh one from `showControls()`, if the
                // move off the bar is itself detected as activity first)
                // will hide as normal.
                scheduleAutoHide()
                return
            }
            controlsVisible = false
            setWindowButtonsHidden(true)
        }
        hideControlsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
    }

    /// Fades the window's own close/miniaturize/zoom buttons in or out.
    /// `alphaValue` rather than `isHidden` because only the former
    /// animates — `NSAnimationContext` gives the same 500ms fade as the
    /// floating bar's own `.animation` above, so both appear/disappear
    /// together.
    ///
    /// Skipped entirely in native fullscreen: with a hidden title bar,
    /// these buttons aren't drawn as ordinary window chrome there at all —
    /// AppKit tucks fullscreen window controls into its own auto-revealing
    /// strip at the very top of the screen (alongside the menu bar),
    /// managed by proximity to that edge, not by activity anywhere in the
    /// window. Fighting that with our own alpha toggling doesn't make them
    /// reappear on an ordinary mouse move — it only fights the system's
    /// own show/hide logic for that strip. The floating bar (plain SwiftUI
    /// opacity, no window chrome involved) is unaffected and keeps
    /// auto-hiding/showing in fullscreen exactly as in a normal window —
    /// only this native-button half of the effect is a no-op there. To
    /// leave fullscreen without the traffic lights, use the new "Pełny
    /// ekran" View-menu item/⌃⌘F, or Esc.
    private func setWindowButtonsHidden(_ hidden: Bool) {
        guard let window = hostWindow, !window.styleMask.contains(.fullScreen) else { return }
        let targetAlpha: CGFloat = hidden ? 0 : 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(type)?.animator().alphaValue = targetAlpha
            }
        }
    }

    // MARK: Window sizing — video fills the window edge-to-edge

    /// Locks the window's own aspect ratio to the video's, so `.resizeAspect`
    /// on `VideoPlayerView` never has to letterbox/pillarbox: the window is
    /// always exactly the video's shape, so the video always exactly fills
    /// it, from the first pixel to the last — including the area under the
    /// (hidden) title bar, since the player already `.ignoresSafeArea()`.
    /// This isn't just a one-time fit: both `contentAspectRatio` and
    /// `windowDelegate.aspectRatio` keep holding that shape for every later
    /// resize/zoom too, not only the moment a clip is opened.
    ///
    /// This means the green button's "Fill & Arrange" tiling menu only
    /// ever offers "Enter Full Screen" as selectable — every other option
    /// (Fill, left/right half, …) targets a frame that doesn't match the
    /// video's aspect ratio, so the system can't reach it and grays it
    /// out. That's deliberate, not a bug to chase further: an earlier
    /// attempt at relaxing the lock so those options would "work" (by only
    /// enforcing the aspect ratio for a live drag/our own video-fit call,
    /// and leaving `contentAspectRatio` unset otherwise) let AppKit's own
    /// tiling code hand back a degenerate proposed frame in some cases,
    /// which crashed the app outright (`CGRectContainsRect` assertion,
    /// `NSException`). Full Screen — a separate Space transition that
    /// never goes through any of this — still works fine and is the
    /// supported way to maximize.
    private func configureWindow(for videoSize: CGSize?) {
        guard let window = hostWindow else { return }

        // Never touch window geometry while in native fullscreen — the
        // window already *is* the screen there. Calling `setContentSize`
        // or assigning `contentAspectRatio` on a fullscreen window doesn't
        // resize its *content* the way it does in a normal window: it
        // shrinks the whole window to a small rect pinned to a corner,
        // leaving the rest of the screen empty and black. That's exactly
        // what made the video (and, riding along with it, the floating
        // bar) appear tiny in a corner instead of maximized whenever a new
        // video was opened while already in fullscreen. Left alone here,
        // `AVPlayerView`'s `.resizeAspect` already fits the video into the
        // full screen on its own (letterboxed if the aspect ratios don't
        // match — expected in fullscreen, since the screen itself can't be
        // reshaped to match), and the floating bar's own `GeometryReader`-
        // based centering in `body` already tracks the window's real
        // current size, fullscreen included.
        guard !window.styleMask.contains(.fullScreen) else { return }

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            // No video loaded (or the timeline was just emptied out): drop
            // the aspect-ratio lock so the window is a normal resizable
            // window again, and let the next video opened size it fresh.
            window.contentAspectRatio = .zero
            windowDelegate.aspectRatio = nil
            hasSizedWindowForVideo = false
            lastAppliedAspectRatio = nil
            return
        }

        window.contentAspectRatio = NSSize(width: videoSize.width, height: videoSize.height)
        let newAspectRatio = videoSize.height / videoSize.width
        windowDelegate.aspectRatio = newAspectRatio

        // The video's shape itself changed since the window was last sized
        // for it — most notably `undo()` restoring a previous, differently
        // shaped video, which (unlike a fresh Open) never bumps
        // `openGeneration`. Force a fresh resize in that case too, same as
        // a brand-new Open does below.
        if let lastAppliedAspectRatio, abs(lastAppliedAspectRatio - newAspectRatio) > 0.001 {
            hasSizedWindowForVideo = false
        }

        // Minimum window size = the floating bar's own footprint exactly
        // (see `FloatingControlBar.footprintSize`) — width equal to the
        // bar's rendered width, height equal to the bar's rendered height
        // *plus* the bottom padding it sits on (10% of the window's own
        // height — see the `.padding(.bottom, geo.size.height * 0.1)` in
        // `body`). Since that padding is itself 10% of the window height,
        // solving `barHeight + 0.1 * windowHeight = windowHeight` gives
        // `windowHeight = barHeight / 0.9`. Below this, in either
        // dimension, the bar would no longer fully fit inside the window
        // and would start getting clipped by its edge. Set on both
        // `NSWindow.minSize` (native hint, e.g. for the live-resize
        // cursor) *and* `windowDelegate.minContentSize` — the delegate is
        // what's actually authoritative; see `WindowSizingDelegate` below.
        let barSize = FloatingControlBar.footprintSize
        let minContentSize = NSSize(width: FloatingControlBar.minWindowWidth, height: barSize.height / 0.9)
        window.minSize = minContentSize
        windowDelegate.minContentSize = minContentSize

        // A brand-new video was just opened (replacing the whole timeline,
        // via File > Open / ⌘O / the folder button / a drop onto the empty
        // state) — always resize fresh to fit it, even if a
        // differently-shaped video was already open and the window already
        // had a size. `openGeneration` only advances for this — never for
        // append/split/trim/undo — so those edits never yank a window the
        // person has already positioned.
        if viewModel.openGeneration != lastHandledOpenGeneration {
            lastHandledOpenGeneration = viewModel.openGeneration
            hasSizedWindowForVideo = false
        }

        // Only actually resize the window the moment a video is first
        // loaded (going from no video to some video, or a fresh Open just
        // above). Anything else that happens to touch the same-shaped clip
        // (append/split/trim on material already on the timeline) shouldn't
        // yank a window the person has already positioned.
        guard !hasSizedWindowForVideo else { return }
        hasSizedWindowForVideo = true
        lastAppliedAspectRatio = newAspectRatio

        applyWindowSize(for: videoSize)
    }

    /// Computes the window's target content size directly from the video's
    /// own pixel dimensions — scaled down by a fixed factor — clamps it to
    /// the screen and to the window's minimum, and applies it with
    /// `setFrame(_:display:animate:)` rather than `setContentSize`.
    ///
    /// `setContentSize` turned out to be the actual root cause of the
    /// black bars that kept showing up on a fresh video load (confirmed by
    /// the window always snapping to the *correct*, video-filling shape
    /// the instant the user grabbed a corner and dragged, even by a single
    /// pixel — interactive resizing goes through AppKit's live-resize path
    /// directly, and that path was always sizing things correctly).
    /// `setContentSize` on a `WindowGroup`-hosted window apparently doesn't
    /// reliably stick on its own — something else (most likely SwiftUI's
    /// own automatic window-sizing for `WindowGroup`) was free to resize it
    /// again right after. Two changes close that gap: `MoviApp` now opts
    /// the window out of that automatic behavior via
    /// `.windowResizability(.contentSize)`, and this method goes through
    /// `setFrame` directly instead, which is the same primitive AppKit's
    /// own live-resize path uses.
    private func applyWindowSize(for videoSize: CGSize) {
        guard let window = hostWindow, !window.styleMask.contains(.fullScreen) else { return }

        // 1/2 rather than 1/3 — a 1920×1080 clip now opens at 960×540
        // instead of a noticeably small 640×360 rectangle. Still clamped
        // to 90% of the screen right below, so a much larger source (4K
        // and up) doesn't open oversized.
        let scale: CGFloat = 1.0 / 2.0
        var targetWidth = videoSize.width * scale
        var targetHeight = videoSize.height * scale

        // Never bigger than 90% of the screen — scaled down uniformly (not
        // clamped per-dimension) so the aspect ratio survives the clamp.
        if let screen = window.screen ?? NSScreen.main {
            let maxWidth = screen.visibleFrame.width * 0.9
            let maxHeight = screen.visibleFrame.height * 0.9
            var shrink: CGFloat = 1
            if targetWidth > maxWidth { shrink = min(shrink, maxWidth / targetWidth) }
            if targetHeight > maxHeight { shrink = min(shrink, maxHeight / targetHeight) }
            targetWidth *= shrink
            targetHeight *= shrink
        }

        // Never smaller than the window's minimum (the floating bar's own
        // footprint — see `configureWindow`) — scaled up uniformly for the
        // same reason.
        let minSize = window.minSize
        var grow: CGFloat = 1
        if targetWidth < minSize.width { grow = max(grow, minSize.width / targetWidth) }
        if targetHeight < minSize.height { grow = max(grow, minSize.height / targetHeight) }
        targetWidth *= grow
        targetHeight *= grow

        let targetContentSize = NSSize(width: targetWidth, height: targetHeight)
        var targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize))

        // Every fresh video open re-centers the window on its screen
        // (`applyWindowSize` only runs for a fresh open/shape change — see
        // `hasSizedWindowForVideo` in `configureWindow` — never for a
        // mid-edit change on material already on the timeline, so this
        // never yanks a window the person has since dragged elsewhere).
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            targetFrame.origin.x = visible.midX - targetFrame.width / 2
            targetFrame.origin.y = visible.midY - targetFrame.height / 2
        }

        window.setFrame(targetFrame, display: true, animate: false)
    }

    /// True mathematical center of the window's *current* frame on its
    /// screen, applied in place (size untouched) — not `NSWindow.center()`,
    /// which deliberately sits a window a bit *above* the screen's actual
    /// vertical midpoint (Apple's own convention for dialogs/panels), which
    /// read as "too high, not centered" when this app used it early on.
    /// Used both by `applyWindowSize` above (as part of a fresh video fit)
    /// and by `WindowAccessor`'s first resolve (so the still-empty
    /// "Otwórz wideo…" window starts centered too, rather than wherever
    /// AppKit happens to place a freshly created window).
    private func centerOnScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: true, animate: false)
    }

    /// Sets `window.title` to the currently edited video's own filename (no
    /// extension), or "Brak pliku" when the timeline is empty. The window
    /// itself has no visible title bar (`.hiddenTitleBar`), but `window.title`
    /// is still exactly what macOS's native window tabbing uses as each
    /// tab's own label — so with every window/tab now owning an independent
    /// `EditorViewModel` (see the `@StateObject` above), this is what makes
    /// each tab identifiable by the video it's actually holding instead of
    /// every tab reading the same generic name.
    ///
    /// `segments.first?.sourceURL` — the video `open(url:)` established, not
    /// necessarily whatever's under the playhead — for the same reason
    /// `presentExportPanel()` uses it: appending more clips at the end
    /// shouldn't change what "this" project/tab is named after.
    private func updateWindowTitle() {
        guard let window = hostWindow else { return }
        if let sourceURL = viewModel.segments.first?.sourceURL {
            window.title = sourceURL.deletingPathExtension().lastPathComponent
        } else {
            window.title = String(localized: "Brak pliku", comment: "Window title fallback when no video is loaded")
        }
    }

    // MARK: Unsaved changes on window close

    /// Installed as `windowDelegate.shouldCloseHandler`. Lets the close
    /// proceed immediately when there's nothing unsaved to lose, or when
    /// we've already been through the prompt once for this close attempt
    /// (`forceWindowClose`, set right before the follow-up `close()` call
    /// from `discardAndCloseWindow()`/the save-completion handler below) —
    /// otherwise puts up the prompt and blocks this close attempt.
    private func handleWindowShouldClose() -> Bool {
        if forceWindowClose { return true }
        guard viewModel.hasUnsavedChanges else { return true }
        pendingWindowClose = true
        return false
    }

    private func discardAndCloseWindow() {
        pendingWindowClose = false
        forceWindowClose = true
        hostWindow?.close()
    }

    /// Opens the export panel (same one ⌘E/the export button use); if the
    /// person actually picks a destination and clicks Save, the window
    /// closes on its own once that export finishes — see the
    /// `onChange(of: viewModel.hasUnsavedChanges)` handler in `body`, since
    /// export is asynchronous and can't be waited on inline here. If they
    /// cancel the panel instead, nothing happens and the window stays open
    /// with the prompt dismissed, same as cancelling would.
    private func saveThenCloseWindow() {
        pendingWindowClose = false
        let started = viewModel.presentExportPanel()
        if started {
            closeWindowAfterSave = true
        }
    }
}

/// Resolves the `NSWindow` hosting this SwiftUI view tree by grabbing it off
/// a plain, invisible `NSView` — the standard bridge for the handful of
/// AppKit-only window properties (here: `contentAspectRatio`/`minSize`,
/// plus installing `WindowSizingDelegate`) that SwiftUI's `Scene`/
/// `WindowGroup` API has no direct equivalent for.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

/// The actual, reliable enforcement of the window's aspect ratio and
/// minimum size — for *every* kind of resize: a live corner-drag, the
/// green zoom button, and (crucially) our own programmatic `setFrame` call
/// in `applyWindowSize`. `NSWindow.contentAspectRatio`/`minSize` are also
/// set directly on the window (see `configureWindow`) and do correctly
/// drive live-resize on their own — that was never the broken part — but
/// they turned out not to be enough by themselves to keep a *programmatic*
/// resize from being undone by something else shortly after. This
/// delegate's `windowWillResize(_:to:)` is the AppKit call every resize —
/// interactive or programmatic — actually has to go through, so clamping
/// here is the one place that can't be raced.
///
/// The aspect-ratio lock is unconditional here, on purpose — an earlier
/// attempt at only enforcing it for a live drag/our own video-fit call
/// (to let the green button's "Fill & Arrange" tiling menu offer more than
/// just "Enter Full Screen") let AppKit's own tiling machinery hand back a
/// degenerate proposed frame in some cases and crashed the app outright
/// (`CGRectContainsRect` assertion, uncaught `NSException`). That's
/// reverted for good: every resize this method sees — including a
/// zoom/tiling attempt — gets forced back onto the video's exact aspect
/// ratio, so the system can't offer any tiling target except Full Screen
/// (a separate Space transition that never reaches this method at all) in
/// the first place, and never gets a chance to produce one of those
/// crashing frames.
///
/// `NSWindow.delegate` is a single slot and a weak reference — installing
/// this here would silently break any delegate behavior SwiftUI itself
/// relies on for the window (state restoration, close handling, etc.) if
/// we just replaced it outright. `install(on:)` instead keeps whatever
/// delegate was already there and forwards every method this class doesn't
/// itself implement back to it, via `forwardingTarget(for:)` — the
/// standard Cocoa pattern for adding behavior to an object's delegate
/// without taking over its whole role.
final class WindowSizingDelegate: NSObject, NSWindowDelegate {
    /// height / width of the currently loaded video. `nil` when no video
    /// is loaded — resizing is then unconstrained (aside from the minimum
    /// size below).
    var aspectRatio: CGFloat?
    var minContentSize = NSSize(width: FloatingControlBar.minWindowWidth,
                                 height: FloatingControlBar.footprintSize.height / 0.9)

    /// Consulted from `windowShouldClose(_:)` below — returns `true` to let
    /// the close proceed immediately, `false` to block it (typically because
    /// it just put up its own "unsaved changes" prompt instead). Set by
    /// `ContentView` to `handleWindowShouldClose()`.
    var shouldCloseHandler: (() -> Bool)?

    private weak var forwardingTarget: NSWindowDelegate?
    private weak var installedWindow: NSWindow?

    func install(on window: NSWindow) {
        guard installedWindow !== window else { return }
        installedWindow = window
        if !(window.delegate === self) {
            forwardingTarget = window.delegate
            window.delegate = self
        }
    }

    /// Fires for both the red traffic-light button and ⌘W / File ▸ Close
    /// Window — both ultimately call AppKit's standard `performClose:`,
    /// which always asks the delegate here first. Lets a video with unsaved
    /// edits put up a Zapisz/Usuń/Anuluj prompt (mirroring the one already
    /// shown when opening a *different* video over unsaved edits) instead of
    /// silently discarding the work.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseHandler?() ?? true
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !sender.styleMask.contains(.fullScreen) else { return frameSize }

        let proposedFrame = NSRect(origin: sender.frame.origin, size: frameSize)
        var contentSize = sender.contentRect(forFrameRect: proposedFrame).size

        if let aspectRatio, aspectRatio > 0 {
            let currentContentSize = sender.contentRect(forFrameRect: sender.frame).size
            let widthDelta = abs(contentSize.width - currentContentSize.width)
            let heightDelta = abs(contentSize.height - currentContentSize.height)
            // Whichever dimension the user is actually dragging (the one
            // that changed more) drives the other, standard aspect-locked
            // resize behavior.
            if widthDelta >= heightDelta {
                contentSize.height = contentSize.width * aspectRatio
            } else {
                contentSize.width = contentSize.height / aspectRatio
            }
        }

        if contentSize.width < minContentSize.width {
            contentSize.width = minContentSize.width
            if let aspectRatio, aspectRatio > 0 { contentSize.height = contentSize.width * aspectRatio }
        }
        if contentSize.height < minContentSize.height {
            contentSize.height = minContentSize.height
            if let aspectRatio, aspectRatio > 0 { contentSize.width = contentSize.height / aspectRatio }
        }
        // Raising one dimension to its floor above can, with an aspect
        // ratio applied, push the *other* back below its own floor —
        // resolve by growing whichever's still short one more time.
        if contentSize.width < minContentSize.width { contentSize.width = minContentSize.width }
        if contentSize.height < minContentSize.height { contentSize.height = minContentSize.height }

        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwardingTarget?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) { return nil }
        return forwardingTarget
    }
}
