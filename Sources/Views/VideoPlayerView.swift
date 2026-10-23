import AVKit
import SwiftUI

/// Thin wrapper around `AVPlayerView` with its own chrome disabled — all
/// transport controls live in `FloatingControlBar` instead, matching the
/// "big video + floating bar" look of the original Shave Video app.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
