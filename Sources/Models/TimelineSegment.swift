import AVFoundation
import Foundation

/// A single contiguous piece of the editing timeline.
///
/// The timeline itself never copies or re-encodes any media — it is just an
/// ordered list of `TimelineSegment`s, each of which references a time range
/// *within one source video file*. Splitting, deleting, and trimming all
/// operate purely on this lightweight list; the actual `AVMutableComposition`
/// used for preview/export is rebuilt from it on demand
/// (see `VideoExporter.buildComposition`).
struct TimelineSegment: Identifiable, Equatable {
    let id: UUID

    /// The source video file this segment's media comes from.
    let sourceURL: URL

    /// The time range *within the source asset* that this segment covers.
    var sourceRange: CMTimeRange

    init(id: UUID = UUID(), sourceURL: URL, sourceRange: CMTimeRange) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceRange = sourceRange
    }

    /// Convenience: this segment's length on the timeline.
    var duration: CMTime {
        sourceRange.duration
    }

    static func == (lhs: TimelineSegment, rhs: TimelineSegment) -> Bool {
        lhs.id == rhs.id
    }
}
