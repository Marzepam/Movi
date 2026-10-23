import AVFoundation
import SwiftUI

/// The pływający pasek (floating bar) docked near the bottom of the window,
/// styled after QuickTime Player's floating transport bar: a compact,
/// hairline-thin panel with genuine transparency (plain alpha blending —
/// see the note on the `.background` below). Icon row on top, time-flanked
/// progress bar below, with a separate row of thick per-segment selection
/// marks directly under the progress bar.
struct FloatingControlBar: View {
    @ObservedObject var viewModel: EditorViewModel
    var onOpen: () -> Void
    var onAppend: () -> Void
    var onExport: () -> Void

    /// Overall bar width — fixed (not stretched to the window). 432pt,
    /// i.e. 20% larger again than the previous 360pt size.
    private let barWidth: CGFloat = 432

    /// The bar's own rendered footprint: `barWidth` (432) plus its own
    /// 2×17pt horizontal padding = 466 wide; icon row (26pt tall — the
    /// tallest element in it) + 2×5pt row spacing + scrubber row
    /// (`controlRowHeight`, 17) + selection-marks row
    /// (`SelectionMarks.markHeight`, 8) + 2×10pt vertical padding = 81,
    /// rounded up to 90 for a little breathing room. Kept in sync by hand
    /// with the layout below (`body`, `.padding` calls) — `ContentView`
    /// uses this to set the window's minimum size, so the window can never
    /// be resized down far enough to clip the bar.
    static let footprintSize = CGSize(width: 466, height: 90)
    /// The window's minimum *width*, used wherever `ContentView` sets or
    /// enforces the window's minimum size: `footprintSize.width` plus 10%
    /// of it as breathing room on each side, so a narrow (e.g. portrait)
    /// video's window is never squeezed down to exactly the bar's own
    /// width — which would leave the bar touching both window edges
    /// instead of "floating" above the video with margin on each side.
    static var minWindowWidth: CGFloat { footprintSize.width * 1.2 }
    /// Width of each time label in row 2 — also used structurally in row 1
    /// so the volume slider's trailing edge lines up with the progress
    /// bar's trailing edge (i.e. where the scrubber itself ends, before the
    /// duration label).
    private let edgeWidth: CGFloat = 43
    private let rowSpacing: CGFloat = 8
    private let volumeWidth: CGFloat = 86
    private let iconSize: CGFloat = 26
    private let controlRowHeight: CGFloat = 17
    /// Gap between icons in row 1's inner icon group. Back up near the
    /// bar's original spacing (was tightened to 6 briefly, to fit the two
    /// new frame-step buttons alongside a still-present folder icon) now
    /// that the folder ("open file") icon has moved out to its own slot at
    /// the bar's outer-left edge, above the current-time label — one fewer
    /// icon in this inner group, plus the width it used to take up here,
    /// both go toward spreading the remaining icons out more.
    private let controlIconSpacing: CGFloat = 14

    var body: some View {
        VStack(spacing: 5) {
            // Row 1: "open file" icon at the bar's outer-left edge,
            // directly above the current-time label in row 2 (rather than
            // grouped with the other icons) + editing/transport icons
            // (centered) + volume, pinned near the bar's outer-right edge
            // (`.padding(.trailing, rowSpacing)` below — deliberately not
            // aligned under the duration label the way it once was; see the
            // frame-step-buttons note in the README for why).
            HStack(spacing: rowSpacing) {
                controlButton(systemName: "folder", help: "Otwórz wideo (⌘O)", action: onOpen)
                    .frame(width: edgeWidth)

                Spacer(minLength: 4)

                HStack(spacing: controlIconSpacing) {
                    controlButton(systemName: "text.append", help: "Dołącz wideo na końcu (⌘⇧A)", action: onAppend)
                    controlButton(systemName: "scissors", help: "Podziel w miejscu playhead (S)", action: viewModel.splitAtPlayhead)
                    controlButton(systemName: "trash", help: "Usuń zaznaczony (żółty) segment — nic nie robi bez zaznaczenia (Delete)", action: viewModel.deleteActiveSegment)

                    // Frame-step buttons, flanking play/pause on both
                    // sides — for nudging the playhead one frame at a time
                    // to line up a precise cut. Mirrors the `[`/`]`-adjacent
                    // left/right-arrow-key stepping already wired up in
                    // `ContentView.installKeyMonitor()` (same ±1/30s step),
                    // just also reachable with the mouse. While playing, the
                    // *first* press only pauses — `viewModel.isPlaying` is
                    // still `true` when the tap lands, so
                    // `stepOrPauseFromButton` takes the pause branch instead
                    // of stepping (a single frame's difference is basically
                    // invisible on a video still in motion; pressing again
                    // once paused then actually steps). The keyboard arrow
                    // shortcuts are unaffected — they still step directly at
                    // any time, matching their existing established feel.
                    controlButton(systemName: "backward.frame.fill", help: "O klatkę wstecz (podczas odtwarzania najpierw zatrzymuje)", action: { viewModel.stepOrPauseFromButton(seconds: -1.0 / 30.0) })

                    Button(action: viewModel.togglePlayPause) {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: iconSize, height: iconSize)
                    }
                    .buttonStyle(.plain)
                    .help("Odtwórz / Pauza (Spacja)")

                    controlButton(systemName: "forward.frame.fill", help: "O klatkę do przodu (podczas odtwarzania najpierw zatrzymuje)", action: { viewModel.stepOrPauseFromButton(seconds: 1.0 / 30.0) })

                    controlButton(systemName: "square.and.arrow.up", help: "Eksportuj (⌘E)", action: onExport)
                }

                Spacer(minLength: 4)

                VolumeSlider(viewModel: viewModel)
                    .frame(width: volumeWidth, height: controlRowHeight)
            }
            .padding(.trailing, rowSpacing)

            // Row 2: current time — thin progress bar — total time. A plain
            // click or drag anywhere on the bar seeks; it never selects.
            HStack(spacing: rowSpacing) {
                Text(viewModel.currentTime.shaveFormatted)
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(width: edgeWidth, alignment: .leading)

                TimelineScrubber(viewModel: viewModel)
                    .frame(height: controlRowHeight)

                Text(viewModel.duration.shaveFormatted)
                    .font(.system(.caption2))
                    .foregroundStyle(.secondary)
                    .frame(width: edgeWidth, alignment: .trailing)
            }

            // Row 3: thick per-segment selection marks, directly beneath the
            // progress bar. Only these marks are clickable for selection —
            // the progress bar itself (row 2) is seek-only.
            HStack(spacing: rowSpacing) {
                Color.clear.frame(width: edgeWidth, height: SelectionMarks.markHeight)

                SelectionMarks(viewModel: viewModel)
                    .frame(height: SelectionMarks.markHeight)

                Color.clear.frame(width: edgeWidth, height: SelectionMarks.markHeight)
            }
        }
        .frame(width: barWidth)
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .background(
            // Plain alpha-blended fill rather than an `NSVisualEffectView`/
            // `.ultraThinMaterial` blur: those sample whatever is rendered
            // behind them in the window, and `AVPlayerView`'s video layer
            // can composite through a path that a live blur doesn't
            // correctly pick up — the bar then reads as a solid gray box
            // instead of "transparent" no matter which material is used.
            // A simple opacity fill has no such dependency: it's a
            // straightforward alpha blend over whatever's beneath, video
            // included, so the video always actually shows (dimmed)
            // through the bar. 0.4 rather than 0.3 — 10 percentage points
            // less transparent (more opaque) than before.
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.black.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
    }

    // `help` is `LocalizedStringKey`, not `String` — each call site below
    // passes a string *literal*, and only `LocalizedStringKey` makes that
    // literal get looked up in `Localizable.xcstrings` once it reaches
    // `.help(help)` inside this function. A plain `String` parameter would
    // still compile (`.help` also has a `StringProtocol`-generic overload),
    // but that overload treats its argument as already-resolved, verbatim
    // text — these tooltips would silently stay Polish in every language.
    private func controlButton(systemName: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .frame(width: iconSize, height: iconSize)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
    }
}

/// The hairline track look shared by both sliders in the bar: a thin
/// horizontal *line* (a `Capsule`, so it reads as a line with rounded caps
/// rather than a rectangular "bar") with a round "ball" knob riding on top
/// — matching QuickTime Player's transport controls, not a filled progress
/// bar.
private enum TrackMetrics {
    static let lineHeight: CGFloat = 2
    static let knobSize: CGFloat = 12
}

/// Slim volume slider with a tappable mute icon — same thin-line-plus-ball
/// styling as the timeline scrubber beneath it.
private struct VolumeSlider: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: 7) {
            Button(action: viewModel.toggleMute) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(viewModel.isMuted ? "Włącz dźwięk" : "Wycisz")

            GeometryReader { proxy in
                let width = proxy.size.width
                let level = viewModel.isMuted ? 0 : viewModel.volume
                let knobX = max(0, min(width, width * CGFloat(level)))

                ZStack(alignment: .leading) {
                    // The track: a thin horizontal line (rounded caps via
                    // `Capsule`), not a filled bar.
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(height: TrackMetrics.lineHeight)
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: max(TrackMetrics.lineHeight, knobX), height: TrackMetrics.lineHeight)
                    // The knob: a round ball riding on the line.
                    Circle()
                        .fill(Color.white)
                        .frame(width: TrackMetrics.knobSize, height: TrackMetrics.knobSize)
                        .shadow(radius: 1)
                        .offset(x: knobX - TrackMetrics.knobSize / 2)
                        .allowsHitTesting(false)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(max(value.location.x / width, 0), 1)
                            viewModel.isMuted = false
                            viewModel.volume = Double(fraction)
                        }
                )
            }
        }
    }

    private var volumeIcon: String {
        if viewModel.isMuted || viewModel.volume <= 0 { return "speaker.slash.fill" }
        if viewModel.volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}

/// The progress bar itself: a thin QuickTime-style line with a round ball
/// knob. A click or drag anywhere on it always moves the playhead — it
/// never selects a segment (selection lives entirely in `SelectionMarks`
/// below it).
private struct TimelineScrubber: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = viewModel.duration.seconds > 0
                ? viewModel.currentTime.seconds / viewModel.duration.seconds
                : 0
            let knobX = max(0, min(width, width * CGFloat(progress)))

            ZStack(alignment: .leading) {
                // The track: a thin horizontal line (rounded caps via
                // `Capsule`), not a filled progress bar.
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: TrackMetrics.lineHeight)

                // Played portion of the timeline — same thin line, brighter.
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: max(TrackMetrics.lineHeight, knobX), height: TrackMetrics.lineHeight)
                    .allowsHitTesting(false)

                // The knob: a round ball riding on the line.
                Circle()
                    .fill(Color.white)
                    .frame(width: TrackMetrics.knobSize, height: TrackMetrics.knobSize)
                    .shadow(radius: 1)
                    .offset(x: knobX - TrackMetrics.knobSize / 2)
                    .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                // No minimum distance: a plain click seeks immediately,
                // same as a drag. There's no selection logic here anymore
                // to disambiguate from, so nothing needs to distinguish a
                // tap from a drag.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        viewModel.isScrubbing = true
                        viewModel.scrub(toFraction: value.location.x / width)
                    }
                    .onEnded { value in
                        viewModel.scrub(toFraction: value.location.x / width)
                        viewModel.isScrubbing = false
                    }
            )
        }
    }
}

/// Thick per-segment selection marks, drawn in their own row directly
/// beneath the progress bar. Appears only once there's more than one
/// segment (i.e. after the first cut or the first appended clip). Clicking
/// a mark selects that segment (white → yellow) and never moves playback —
/// only the progress bar (above) can do that.
///
/// Laid out as a plain `HStack` of fixed-width rectangles — one per segment,
/// in timeline order — rather than a `ZStack` with manually computed
/// `.offset()` positions. The offset-based version could misattribute a
/// tap to the wrong segment (the container's own layout bounds don't
/// necessarily expand to cover content that's been pushed outside them via
/// offset, which can make hit-testing land on the wrong overlapping
/// rectangle). A native `HStack` flow lays each rectangle directly next to
/// the previous one, so its hit-testable area always exactly matches what's
/// drawn on screen, and always maps to the correct segment.
private struct SelectionMarks: View {
    @ObservedObject var viewModel: EditorViewModel

    static let markHeight: CGFloat = 8
    private static let gap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let spans = viewModel.segmentSpans()

            if spans.count > 1 {
                HStack(spacing: Self.gap) {
                    ForEach(spans) { span in
                        let w = max(0, totalWidth * CGFloat(span.endFraction - span.startFraction) - Self.gap)
                        let isSelected = span.id == viewModel.selectedSegmentID

                        Rectangle()
                            .fill(isSelected ? Color.yellow : Color.white.opacity(0.55))
                            .frame(width: w, height: Self.markHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectSegment(span.id)
                            }
                    }
                }
            }
        }
    }
}
