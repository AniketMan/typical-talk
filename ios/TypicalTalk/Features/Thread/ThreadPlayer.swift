import AVFoundation
import Observation
import SwiftUI

/// Thin wrapper over AVPlayer so the glass toolbar has something honest to
/// drive. When a message has no local recording there is no player, and the
/// toolbar says so rather than pretending to scrub.
@MainActor
@Observable
final class ThreadPlayer {
    private(set) var player: AVPlayer?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    var rate: Float = 1.0

    private var observer: Any?
    private var loadedURL: URL?

    var hasMedia: Bool { player != nil }

    func load(_ url: URL?) {
        guard url != loadedURL else { return }
        teardown()
        loadedURL = url
        guard let url else { return }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player

        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                let total = item.duration.seconds
                if total.isFinite { self.duration = total }
            }
        }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
            player.playImmediately(atRate: rate)
        }
        isPlaying.toggle()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying { player?.rate = newRate }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
    }

    func teardown() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}
