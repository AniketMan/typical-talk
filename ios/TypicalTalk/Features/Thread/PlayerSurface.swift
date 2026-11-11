import AVFoundation
import SwiftUI
import UIKit

/// A bare AVPlayerLayer, used instead of SwiftUI's VideoPlayer.
///
/// VideoPlayer wraps a whole AVPlayerViewController, which re-lays itself out
/// whenever its item changes. That, plus the first frame of a take drawing
/// before the resume seek lands, is what made loading a take twitch. This view
/// only draws frames, and ThreadView keeps it hidden until the player reports
/// the take is ready at the right position.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    /// Set on the thread's own surface only: Picture in Picture is attached to
    /// one layer, and it should be the one inline in the thread.
    var pictureInPicture: ThreadPlayer?

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        pictureInPicture?.attachPictureInPicture(to: view.playerLayer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
