import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// All editor state and every editing action lives here. The timeline is a
/// plain `[TimelineSegment]` array; every mutating action (split/delete/
/// trim/append) updates that array and then rebuilds the `AVMutableComposition`
/// backing the preview player (see `rebuildComposition`).
@MainActor
final class EditorViewModel: ObservableObject {

    // MARK: Published state

    @Published var segments: [TimelineSegment] = []
    @Published var currentTime: CMTime = .zero
    @Published var duration: CMTime = .zero
    @Published var isPlaying = false
    @Published var isScrubbing = false
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var errorMessage: String?

    /// The current timeline's (orientation-corrected) frame size — the
    /// canonical size every segment is fitted into (see
    /// `VideoExporter.CompositionResult.renderSize`). The window is kept
    /// locked to this aspect ratio so the video always fills it edge-to-edge
    /// with no black letterbox/pillarbox bars. Nil when there's no video
    /// loaded.
    @Published var videoSize: CGSize?

    /// Bumped every time `open(url:)` loads a brand-new video, replacing
    /// the whole timeline — never for edits (`append`/split/trim/undo) that
    /// keep working with material already on the timeline. `ContentView`
    /// compares this to know a fresh Open just happened (as opposed to the
    /// existing video merely being re-fitted), so it always resizes the
    /// window to the newly opened video's own shape — even if a
    /// differently-shaped video was already open and the window already
    /// had a size from it.
    @Published private(set) var openGeneration = 0

    /// Whether the currently loaded video has edits since it was opened (or
    /// since it was last exported) that haven't been exported yet. Drives
    /// the unsaved-changes prompt in `requestOpen(url:)`/`ContentView` —
    /// deliberately not a deep comparison against the original timeline
    /// (a trim/split back to the exact original shape still counts as
    /// "changed"), which matches what people actually expect from a dirty
    /// flag.
    @Published private(set) var hasUnsavedChanges = false

    /// Set by `requestOpen(url:)` (folder icon / ⌘O) when there ARE unsaved
    /// edits to ask about — never by `append`/drag-and-drop, which don't go
    /// through the prompt at all. `ContentView`'s alert reads this to offer
    /// Zapisz/Usuń/Anuluj, and resolves it via `discardAndOpenPending()`/
    /// `cancelPendingOpen()`/`saveThenCancelPendingOpen()`.
    @Published var pendingOpenURL: URL?

    /// 0...1. Mirrors `player.volume`.
    @Published var volume: Double = 1.0 {
        didSet { player.volume = Float(volume) }
    }
    @Published var isMuted: Bool = false {
        didSet { player.isMuted = isMuted }
    }

    /// The segment explicitly clicked on its scrubber "frame" — highlighted
    /// yellow. Independent of the playhead; selecting never seeks.
    @Published var selectedSegmentID: UUID?

    let player = AVPlayer()

    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: Private

    private var undoStack: [[TimelineSegment]] = []
    private var timeObserverToken: Any?
    private var cancellables = Set<AnyCancellable>()
    private var exportTask: Task<Void, Never>?

    /// Source files we currently hold a sandbox security-scope grant on.
    /// See `ensureAccess`/`reconcileAccessedURLs`.
    private var accessedURLs: Set<URL> = []

    // MARK: Init

    init() {
        observePlayer()
        addPeriodicTimeObserver()
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: File loading

    func open(url: URL) async {
        ensureAccess(url)
        guard await validate(url: url) else { reconcileAccessedURLs(); return }
        guard let assetDuration = await loadDuration(of: url) else { reconcileAccessedURLs(); return }

        // A brand-new video replaces the whole timeline — nothing about the
        // *previous* video's edit history applies to it, so the undo stack
        // is cleared rather than pushed onto (this is also what makes
        // "cofnij edycję" correctly unavailable right after "Usuń" in the
        // unsaved-changes prompt discards the old video and opens this
        // one). The freshly opened video itself starts out unedited.
        undoStack.removeAll()
        segments = [TimelineSegment(sourceURL: url, sourceRange: CMTimeRange(start: .zero, duration: assetDuration))]
        openGeneration += 1
        hasUnsavedChanges = false
        reconcileAccessedURLs()
        await rebuildComposition(preservingTime: .zero)
        // `AVPlayer.rate` persists across `replaceCurrentItem` — which is
        // exactly why a video opened *while another was already playing*
        // carried on playing by itself, but the very first video of a run
        // (rate still at its initial 0) just sat there waiting for the
        // person to press play. Starting playback explicitly here makes
        // every fresh open behave the same way, first one included.
        player.play()
    }

    func append(url: URL) async {
        ensureAccess(url)
        guard await validate(url: url) else { reconcileAccessedURLs(); return }
        guard let assetDuration = await loadDuration(of: url) else { reconcileAccessedURLs(); return }

        pushUndoSnapshot()
        let resumeTime = currentTime
        segments.append(TimelineSegment(sourceURL: url, sourceRange: CMTimeRange(start: .zero, duration: assetDuration)))
        hasUnsavedChanges = true
        reconcileAccessedURLs()
        await rebuildComposition(preservingTime: resumeTime)
    }

    // MARK: Sandboxed file access
    //
    // The app is sandboxed (see Movi.entitlements). Files picked via
    // NSOpenPanel stay readable for the life of the run, but files that
    // arrive via drag & drop are only guaranteed to be readable for as long
    // as we hold their security scope open — and previously we never called
    // `startAccessingSecurityScopedResource()` at all. Once that grant
    // lapsed (typically after a few more edits), `AVAssetExportSession`
    // would stall on the now-unreadable source file instead of failing
    // cleanly, which is what made export look like it "hung" the app. We
    // now grab the scope the moment a URL is used and keep it open for as
    // long as any timeline segment still references that file.

    private func ensureAccess(_ url: URL) {
        if accessedURLs.insert(url).inserted {
            _ = url.startAccessingSecurityScopedResource()
        }
    }

    private func reconcileAccessedURLs() {
        let needed = Set(segments.map { $0.sourceURL })
        for url in needed.subtracting(accessedURLs) {
            _ = url.startAccessingSecurityScopedResource()
        }
        for url in accessedURLs.subtracting(needed) {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs = needed
    }

    private func validate(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else {
                errorMessage = String(
                    format: String(localized: "Plik „%@” nie zawiera ścieżki wideo.", comment: "Error when an opened/appended file has no video track"),
                    url.lastPathComponent
                )
                return false
            }
            return true
        } catch {
            errorMessage = String(
                format: String(localized: "Nie udało się wczytać pliku „%@”: %@", comment: "Error when loading a file's tracks fails; second %@ is the underlying system error description"),
                url.lastPathComponent, error.localizedDescription
            )
            return false
        }
    }

    private func loadDuration(of url: URL) async -> CMTime? {
        let asset = AVURLAsset(url: url)
        guard let assetDuration = try? await asset.load(.duration), assetDuration.isNumeric, assetDuration > .zero else {
            errorMessage = String(
                format: String(localized: "Nie udało się odczytać długości pliku „%@”.", comment: "Error when a file's duration can't be read"),
                url.lastPathComponent
            )
            return nil
        }
        return assetDuration
    }

    // MARK: Editing actions

    /// Splits the segment under the playhead into two at the current time.
    func splitAtPlayhead() {
        guard let idx = segmentIndex(at: currentTime) else { return }
        let starts = segmentsWithTimelineStarts()
        let (segment, segmentStart) = starts[idx]
        let localOffset = currentTime - segmentStart

        let minGap = CMTime(value: 1, timescale: 30) // ~1 frame guard against zero-length splits
        guard localOffset > minGap, (segment.duration - localOffset) > minGap else { return }

        let splitPoint = segment.sourceRange.start + localOffset
        let first = TimelineSegment(sourceURL: segment.sourceURL,
                                     sourceRange: CMTimeRange(start: segment.sourceRange.start, end: splitPoint))
        let second = TimelineSegment(sourceURL: segment.sourceURL,
                                      sourceRange: CMTimeRange(start: splitPoint, end: segment.sourceRange.end))

        pushUndoSnapshot()
        segments.replaceSubrange(idx...idx, with: [first, second])
        hasUnsavedChanges = true
        Task { await rebuildComposition(preservingTime: currentTime) }
    }

    /// Deletes the segment that's explicitly selected (highlighted yellow
    /// on the scrubber) — and *only* that one. Deliberately does **not**
    /// fall back to whatever the playhead happens to be sitting over: the
    /// trash button/Delete key used to also delete that, which meant it
    /// silently removed a chunk of the timeline even when nothing was
    /// selected. Now a click with nothing selected — or before there's
    /// more than one segment to select from at all — does nothing.
    func deleteActiveSegment() {
        guard let selectedID = selectedSegmentID,
              let idx = segments.firstIndex(where: { $0.id == selectedID }) else { return }
        let starts = segmentsWithTimelineStarts()
        let targetTime = starts[idx].start // where the following content now begins

        pushUndoSnapshot()
        segments.remove(at: idx)
        selectedSegmentID = nil
        hasUnsavedChanges = true
        reconcileAccessedURLs()
        Task { await rebuildComposition(preservingTime: targetTime) }
    }

    /// Removes everything on the timeline before the playhead.
    func trimStart() {
        guard let idx = segmentIndex(at: currentTime) else { return }
        let starts = segmentsWithTimelineStarts()
        let (segment, segmentStart) = starts[idx]
        let localOffset = currentTime - segmentStart

        pushUndoSnapshot()
        var newSegments = Array(segments[idx...])
        let newStart = segment.sourceRange.start + localOffset
        if newStart < segment.sourceRange.end {
            newSegments[0].sourceRange = CMTimeRange(start: newStart, end: segment.sourceRange.end)
        } else {
            newSegments.removeFirst()
        }
        segments = newSegments
        hasUnsavedChanges = true
        reconcileAccessedURLs()
        Task { await rebuildComposition(preservingTime: .zero) }
    }

    /// Removes everything on the timeline after the playhead.
    func trimEnd() {
        guard let idx = segmentIndex(at: currentTime) else { return }
        let starts = segmentsWithTimelineStarts()
        let (segment, segmentStart) = starts[idx]
        let localOffset = currentTime - segmentStart

        pushUndoSnapshot()
        var newSegments = Array(segments[0...idx])
        let newEnd = segment.sourceRange.start + localOffset
        if newEnd > segment.sourceRange.start {
            newSegments[newSegments.count - 1].sourceRange = CMTimeRange(start: segment.sourceRange.start, end: newEnd)
        } else {
            newSegments.removeLast()
        }
        segments = newSegments
        hasUnsavedChanges = true
        reconcileAccessedURLs()
        Task { await rebuildComposition(preservingTime: currentTime) }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        segments = previous
        hasUnsavedChanges = true
        reconcileAccessedURLs()
        Task { await rebuildComposition(preservingTime: currentTime) }
    }

    // MARK: Timeline lookup helpers

    /// Each segment paired with its absolute start time in the composition timeline.
    private func segmentsWithTimelineStarts() -> [(segment: TimelineSegment, start: CMTime)] {
        var result: [(TimelineSegment, CMTime)] = []
        var cursor = CMTime.zero
        for segment in segments {
            result.append((segment, cursor))
            cursor = cursor + segment.duration
        }
        return result
    }

    private func segmentIndex(at time: CMTime) -> Int? {
        let withStarts = segmentsWithTimelineStarts()
        for (i, entry) in withStarts.enumerated() {
            let end = entry.start + entry.segment.duration
            if time >= entry.start && time < end {
                return i
            }
        }
        if time >= duration, let lastIndex = withStarts.indices.last {
            return lastIndex
        }
        return nil
    }

    struct SegmentSpan: Identifiable, Equatable {
        let id: UUID
        let startFraction: Double
        let endFraction: Double
    }

    /// Every segment's [0,1] fraction span along the total duration — one
    /// per split fragment, used to draw a bordered "frame" for each on the
    /// scrubber. Tapping a frame selects it (see `selectSegment`); it never
    /// moves the playhead. Empty until there's more than one segment (i.e.
    /// after the first split or the first appended clip) — a single frame
    /// spanning the whole bar has nothing to distinguish, so none is drawn.
    func segmentSpans() -> [SegmentSpan] {
        guard duration.seconds > 0, segments.count > 1 else { return [] }
        return segmentsWithTimelineStarts().map { entry in
            SegmentSpan(
                id: entry.segment.id,
                startFraction: entry.start.seconds / duration.seconds,
                endFraction: (entry.start + entry.segment.duration).seconds / duration.seconds
            )
        }
    }

    /// Marks a segment as selected (its scrubber frame turns yellow).
    /// Deliberately does not touch `currentTime`/seek — selecting a frame
    /// is purely a marker, not a transport action.
    func selectSegment(_ id: UUID) {
        selectedSegmentID = id
    }

    // MARK: Playback

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func toggleMute() {
        isMuted.toggle()
    }

    func step(seconds: Double) {
        seek(to: currentTime + CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Used only by the floating bar's frame-step buttons (the keyboard
    /// arrow shortcuts still call `step(seconds:)` directly, unaffected).
    /// If the video is currently playing, a single frame's difference is
    /// essentially invisible against real motion, so the *first* press just
    /// pauses instead of stepping — a second press, now that playback is
    /// actually stopped, then steps for real. This still reads as one
    /// unambiguous action per press: press once while playing to stop
    /// exactly, then keep pressing to nudge frame by frame.
    func stepOrPauseFromButton(seconds: Double) {
        if isPlaying {
            togglePlayPause()
        } else {
            step(seconds: seconds)
        }
    }

    func seek(to time: CMTime) {
        let clamped = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: duration))
        currentTime = clamped
        player.seek(to: clamped, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func scrub(toFraction fraction: CGFloat) {
        guard duration.seconds > 0 else { return }
        let clampedFraction = min(max(fraction, 0), 1)
        seek(to: CMTime(seconds: duration.seconds * Double(clampedFraction), preferredTimescale: 600))
    }

    private func observePlayer() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = status == .playing
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [weak self] _ in
                guard let self else { return }
                self.player.pause()
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.currentTime = .zero
            }
            .store(in: &cancellables)
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        // `AVPlayer.addPeriodicTimeObserver`'s handler is typed `@Sendable`
        // regardless of which queue you hand it, so the compiler can't see
        // that `queue: .main` guarantees this always runs on the main
        // actor — assert that explicitly with `MainActor.assumeIsolated`
        // instead of hopping via `Task { @MainActor in … }`, which would
        // delay every tick by a runloop turn and defeat the point of a
        // high-frequency observer.
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time
            }
        }
    }

    // MARK: Composition / export

    private func rebuildComposition(preservingTime target: CMTime) async {
        guard !segments.isEmpty else {
            player.replaceCurrentItem(with: nil)
            duration = .zero
            currentTime = .zero
            videoSize = nil
            return
        }
        do {
            let result = try await VideoExporter.buildComposition(segments: segments)
            let newDuration = try await result.composition.load(.duration)
            let item = AVPlayerItem(asset: result.composition)
            // Mirrors the export path: when sources differ in size/rate,
            // the preview shows the same fitted (letterboxed/pillarboxed)
            // frame the export will produce, not just the raw first track.
            item.videoComposition = result.videoComposition
            player.replaceCurrentItem(with: item)
            duration = newDuration
            videoSize = result.renderSize
            seek(to: min(target, newDuration))
        } catch {
            errorMessage = String(
                format: String(localized: "Błąd budowania osi czasu: %@", comment: "Error when building the preview composition fails"),
                error.localizedDescription
            )
        }
    }

    /// Kicks off export as a cancellable task (see `cancelExport`) rather
    /// than a plain `async` call, so the UI has a way to bail out instead of
    /// just waiting indefinitely if something goes wrong underneath.
    func export(to url: URL) {
        guard !segments.isEmpty else { return }
        exportTask?.cancel()
        isExporting = true
        exportProgress = 0

        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isExporting = false }
            do {
                let result = try await VideoExporter.buildComposition(segments: self.segments)
                try await VideoExporter.export(
                    composition: result.composition,
                    videoComposition: result.videoComposition,
                    to: url
                ) { [weak self] value in
                    self?.exportProgress = value
                }
                // Exported successfully — the currently loaded video is no
                // longer "unsaved", so opening a new one from here on won't
                // prompt again until it's actually edited further.
                self.hasUnsavedChanges = false
            } catch VideoExporter.ExportError.cancelled {
                // Cancelled by the user — nothing to report.
            } catch is CancellationError {
                // Cancelled by the user — nothing to report.
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = String(
                        format: String(localized: "Eksport nie powiódł się: %@", comment: "Error when export itself fails"),
                        error.localizedDescription
                    )
                }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    // MARK: NSOpenPanel / NSSavePanel

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        configureVideoPanel(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        requestOpen(url: url)
    }

    /// Entry point for "open a new video" — the folder icon, ⌘O, and
    /// Finder's "Otwórz z"/"Open With" or double-click (see `ContentView`'s
    /// `.onOpenURL`) — as opposed to `append`/a drop onto an already-loaded
    /// video, which call `append(url:)` directly and never go through here
    /// or prompt at all. Opens immediately when there's nothing to lose (no
    /// video loaded, or the current one has no unsaved edits); otherwise
    /// stashes `url` here for `ContentView`'s alert to resolve via
    /// `discardAndOpenPending()`/`cancelPendingOpen()`/
    /// `saveThenCancelPendingOpen()`.
    func requestOpen(url: URL) {
        guard hasUnsavedChanges else {
            Task { await open(url: url) }
            return
        }
        pendingOpenURL = url
    }

    /// "Usuń" in the unsaved-changes prompt — discards the current edits
    /// and opens the newly picked video. `open(url:)` itself clears the
    /// undo stack, so "cofnij edycję" is correctly unavailable again once
    /// the new video has loaded.
    func discardAndOpenPending() {
        guard let url = pendingOpenURL else { return }
        pendingOpenURL = nil
        Task { await open(url: url) }
    }

    /// "Anuluj" — stays on the current video exactly as it was left; the
    /// newly picked file is never opened.
    func cancelPendingOpen() {
        pendingOpenURL = nil
    }

    /// "Zapisz" — opens the export/save flow for the current video.
    /// Deliberately drops the pending file rather than opening it once the
    /// save completes: the person ends up back on the same video either
    /// way, saved or not.
    func saveThenCancelPendingOpen() {
        pendingOpenURL = nil
        presentExportPanel()
    }

    func presentAppendPanel() {
        let panel = NSOpenPanel()
        configureVideoPanel(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await append(url: url) }
    }

    /// Returns `true` the moment export actually starts (the person picked
    /// a destination and clicked Save), `false` if they cancelled the panel
    /// outright — export itself is still asynchronous either way (see
    /// `export(to:)`), so callers that need to know when it's *done*, not
    /// just started, watch `hasUnsavedChanges` flip to `false` instead.
    /// `@discardableResult` since most call sites (the export button, ⌘E)
    /// don't care; `ContentView`'s "close window with unsaved changes"
    /// flow is the one that does.
    @discardableResult
    func presentExportPanel() -> Bool {
        guard !segments.isEmpty else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        // Defaults to the *originally opened* video's own folder and name
        // (with "_movi" appended) rather than a generic "export.mov" in
        // whatever folder the save panel last remembered — saving back
        // next to the source, under a related name, is the common case.
        // `segments.first` rather than the file under the playhead: that's
        // the one video identity `open(url:)` actually establishes (append
        // adds more segments from *other* files, which shouldn't change
        // what "the" source video means for this purpose).
        if let sourceURL = segments.first?.sourceURL {
            panel.directoryURL = sourceURL.deletingLastPathComponent()
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = "\(baseName)_movi.mov"
        } else {
            panel.nameFieldStringValue = "export.mov"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        export(to: url)
        return true
    }

    private func configureVideoPanel(_ panel: NSOpenPanel) {
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
    }

    // MARK: Undo

    private func pushUndoSnapshot() {
        undoStack.append(segments)
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
    }
}
