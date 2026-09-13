import AVFoundation
import Observation
import SwiftUI

/// Wraps a single AVPlayer for the life of a thread. Switching takes replaces
/// the player's item rather than building a new player, so AVKit never tears
/// down and rebuilds its view. That rebuild is what made the outgoing take
/// flash up large when you changed takes.
@MainActor
@Observable
final class ThreadPlayer {
    private(set) var player: AVPlayer?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// True once the current take is ready and any resume seek has landed.
    /// Until then the video stays hidden, so the first frame is never shown
    /// before jumping to where you left off.
    private(set) var isSettled = false
    var rate: Float = 1.0

    private var observer: Any?
    private var loadedURL: URL?
    /// A resume point requested before the item was ready to honour it.
    private var pendingSeek: Double?
    /// Watches the item's readiness directly. The periodic time observer does
    /// not tick while paused, so it cannot be relied on to notice readiness.
    private var statusObservation: NSKeyValueObservation?

    var hasMedia: Bool { player?.currentItem != nil }

    func load(_ url: URL?, resumingAt resume: Double = 0) {
        guard url != loadedURL else { return }
        loadedURL = url

        guard let url else {
            player?.replaceCurrentItem(with: nil)
            reset()
            return
        }

        let engine = existingPlayer()
        engine.pause()
        isPlaying = false
        isSettled = false
        // Show the resume point immediately rather than 0, so the scrubber
        // does not start at the beginning and jump once the item is ready.
        currentTime = resume
        duration = 0
        pendingSeek = resume > 0 ? resume : nil
        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in self?.itemBecameReady(item) }
        }
        engine.replaceCurrentItem(with: item)
        engine.rate = 0
    }

    /// Creates the player once, then reuses it for every take in the thread.
    private func existingPlayer() -> AVPlayer {
        if let player { return player }
        let engine = AVPlayer()
        engine.actionAtItemEnd = .pause
        player = engine
        observer = engine.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        return engine
    }

    private func tick(_ seconds: Double) {
        guard let item = player?.currentItem else { return }
        let total = item.duration.seconds
        if total.isFinite, total > 0 { duration = total }

        // Until the take has settled at its resume point, keep showing that
        // point instead of the player's pre-seek time of zero.
        guard isSettled else { return }
        currentTime = seconds

        // The player stops itself at the end; reflect that in the UI.
        if isPlaying, duration > 0, seconds >= duration - 0.05 {
            isPlaying = false
        }
    }

    /// Seeks to the resume point if there is one, then reveals the video.
    private func itemBecameReady(_ item: AVPlayerItem) {
        guard item === player?.currentItem, !isSettled else { return }
        let total = item.duration.seconds
        if total.isFinite, total > 0 { duration = total }

        guard let target = pendingSeek else {
            isSettled = true
            return
        }
        pendingSeek = nil
        player?.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in self?.isSettled = true }
        }
        currentTime = target
    }

    func togglePlay() {
        guard let player, player.currentItem != nil else { return }
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
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = target
    }

    private func reset() {
        isSettled = false
        isPlaying = false
        currentTime = 0
        duration = 0
        pendingSeek = nil
    }

    /// Called when the thread closes, not between takes.
    func teardown() {
        statusObservation = nil
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        loadedURL = nil
        reset()
    }
}
