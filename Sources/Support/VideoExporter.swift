import AVFoundation
import CoreGraphics

/// Pure AVFoundation helpers that turn a `[TimelineSegment]` timeline into a
/// playable / exportable composition, and export it losslessly where
/// possible. Has no dependency on SwiftUI or app state, so it's used
/// identically for live preview and for the final export.
enum VideoExporter {

    enum ExportError: LocalizedError {
        case sessionCreationFailed
        case cancelled

        var errorDescription: String? {
            switch self {
            case .sessionCreationFailed:
                return String(localized: "Nie udało się utworzyć sesji eksportu dla tej kombinacji plików.", comment: "Error when AVAssetExportSession itself can't be created")
            case .cancelled:
                return String(localized: "Eksport został anulowany.", comment: "Error description for a user-cancelled export")
            }
        }
    }

    /// A composition plus, when the source segments don't all share the same
    /// frame size/rate, a video composition that reconciles them.
    struct CompositionResult {
        let composition: AVMutableComposition
        /// Non-nil only when segments differ in (orientation-corrected)
        /// frame size and/or frame rate. It uses the *first* segment's frame
        /// as the canonical render size/rate and fits every other segment
        /// into it — aspect ratio preserved, centered, letterboxed/
        /// pillarboxed as needed. Attaching a video composition forces
        /// re-encoding on export (passthrough can't apply per-segment
        /// transforms), so we only build one when sources actually differ.
        let videoComposition: AVMutableVideoComposition?
        /// The (orientation-corrected) frame size of the *first* segment —
        /// the same "canonical" size `videoComposition` fits everything
        /// else into, whether or not a video composition was actually
        /// needed. Used to size the window to the video's own aspect ratio
        /// so playback fills it edge-to-edge with no letterbox/pillarbox
        /// bars. Nil only when there are no video segments at all.
        let renderSize: CGSize?
    }

    /// Builds a composition that concatenates every segment's source time
    /// range, in order, into a single video + audio timeline. No frames are
    /// re-encoded here — this is just an edit list (plus, when needed, the
    /// per-segment fit transforms described in `CompositionResult`).
    static func buildComposition(segments: [TimelineSegment]) async throws -> CompositionResult {
        let composition = AVMutableComposition()
        guard !segments.isEmpty,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return CompositionResult(composition: composition, videoComposition: nil, renderSize: nil)
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        struct Placement {
            let timeRange: CMTimeRange
            let naturalSize: CGSize
            let orient: CGAffineTransform
            let orientedSize: CGSize
            let frameRate: Float
        }

        var placements: [Placement] = []
        var cursor = CMTime.zero
        var appliedTrackTransform = false

        for segment in segments {
            let asset = AVURLAsset(url: segment.sourceURL)

            if let sourceVideo = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(segment.sourceRange, of: sourceVideo, at: cursor)

                let naturalSize = try await sourceVideo.load(.naturalSize)
                let orient = try await sourceVideo.load(.preferredTransform)
                let nominalRate = try await sourceVideo.load(.nominalFrameRate)
                let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(orient)
                let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))

                placements.append(Placement(
                    timeRange: CMTimeRange(start: cursor, duration: segment.duration),
                    naturalSize: naturalSize,
                    orient: orient,
                    orientedSize: orientedSize,
                    frameRate: nominalRate > 0 ? nominalRate : 30
                ))

                // Keeps the plain (no-video-composition) path below showing
                // the first clip upright, same as before — used only when
                // every segment already matches, so this single transform
                // is all that's needed in that case.
                if !appliedTrackTransform {
                    videoTrack.preferredTransform = orient
                    appliedTrackTransform = true
                }
            }

            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack?.insertTimeRange(segment.sourceRange, of: sourceAudio, at: cursor)
            }

            cursor = cursor + segment.duration
        }

        guard let first = placements.first else {
            return CompositionResult(composition: composition, videoComposition: nil, renderSize: nil)
        }

        let renderSize = first.orientedSize
        let renderRate = first.frameRate

        let mismatched = placements.contains {
            !sizesClose($0.orientedSize, renderSize) || !ratesClose($0.frameRate, renderRate)
        }
        guard mismatched, renderSize.width > 0, renderSize.height > 0 else {
            // Everything already matches the first clip — no need to force
            // re-encoding just to reconcile formats that already agree.
            return CompositionResult(composition: composition, videoComposition: nil, renderSize: renderSize)
        }

        // Sources differ in size and/or frame rate: use the first segment's
        // frame as the canonical one and fit every segment (including the
        // first, trivially) into it.
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(seconds: 1.0 / Double(renderRate), preferredTimescale: 600)
        videoComposition.instructions = placements.map { placement in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = placement.timeRange
            // Explicit rather than relying on the (undocumented) default,
            // so the letterbox/pillarbox bars around a smaller-dimension
            // fragment are guaranteed solid black.
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            let transform = fitTransform(naturalSize: placement.naturalSize, orient: placement.orient, into: renderSize)
            layerInstruction.setTransform(transform, at: placement.timeRange.start)
            instruction.layerInstructions = [layerInstruction]
            return instruction
        }

        return CompositionResult(composition: composition, videoComposition: videoComposition, renderSize: renderSize)
    }

    /// Transform that takes a segment's raw sample buffers (`naturalSize`,
    /// pre-orientation) and maps them into `renderSize`: first oriented
    /// upright via `orient` (each segment's own `preferredTransform` — this
    /// is also what makes mixed-orientation sources display correctly, since
    /// a per-segment layer instruction — unlike the single track-wide
    /// transform used in the no-video-composition path — can honor each
    /// clip's own orientation), then scaled to fit (aspect ratio preserved,
    /// no cropping) and centered, leaving letterbox/pillarbox bars where
    /// the aspect ratios don't match.
    private static func fitTransform(naturalSize: CGSize, orient: CGAffineTransform, into renderSize: CGSize) -> CGAffineTransform {
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(orient)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        guard orientedSize.width > 0, orientedSize.height > 0, renderSize.width > 0, renderSize.height > 0 else {
            return orient
        }

        let scale = min(renderSize.width / orientedSize.width, renderSize.height / orientedSize.height)
        let offsetX = (renderSize.width - orientedSize.width * scale) / 2
        let offsetY = (renderSize.height - orientedSize.height * scale) / 2

        return orient
            .concatenating(CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
    }

    private static func sizesClose(_ a: CGSize, _ b: CGSize, tolerance: CGFloat = 1) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private static func ratesClose(_ a: Float, _ b: Float, tolerance: Float = 0.05) -> Bool {
        abs(a - b) <= tolerance
    }

    /// Exports a composition. When `videoComposition` is nil (all segments
    /// already share one frame size/rate) this tries a passthrough (re-mux,
    /// no re-encode) session first for a lossless result, falling back to a
    /// re-encoding preset only if the source material isn't
    /// passthrough-compatible. When `videoComposition` is non-nil (segments
    /// were fitted into the first clip's frame — see `buildComposition`),
    /// passthrough is skipped entirely since it can't apply per-segment
    /// transforms; that combination always re-encodes.
    ///
    /// The progress poller stops deterministically via `defer` the instant
    /// the export finishes, and cancelling the enclosing `Task` calls
    /// `session.cancelExport()` immediately via `withTaskCancellationHandler`
    /// instead of leaving the session running with nothing listening to it.
    static func export(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition?,
        to url: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        let session: AVAssetExportSession?
        if videoComposition != nil {
            session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        } else {
            session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
                ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        }
        guard let session else { throw ExportError.sessionCreationFailed }

        // AVAssetExportSession refuses to overwrite an existing file.
        try? FileManager.default.removeItem(at: url)

        session.outputURL = url
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = videoComposition

        let progressTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let value = Double(session.progress)
                await MainActor.run { progress(value) }
            }
        }
        defer { progressTask.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously {
                    continuation.resume()
                }
            }
        } onCancel: {
            session.cancelExport()
        }

        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            throw ExportError.cancelled
        default:
            throw session.error ?? ExportError.sessionCreationFailed
        }
    }
}
