import AVFoundation
import AVKit
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
    /// True while a finger is on the scrubber. The playback clock must not
    /// write the position then, or it drags the knob back to where the video
    /// still is: the bounce you saw.
    private(set) var isScrubbing = false
    private var resumeAfterScrub = false

    // MARK: Picture in Picture state

    /// The talk this player belongs to, so tapping the floating window can
    /// bring you back to it.
    var talkID: Talk.ID?
    private(set) var isPictureInPictureActive = false
    private(set) var canPictureInPicture = false
    private var pictureInPicture: AVPictureInPictureController?
    private var pictureInPictureDelegate: PictureInPictureDelegate?
    private var possibleObservation: NSKeyValueObservation?
    var rate: Float = 1.0

    private var observer: Any?
    private var loadedURL: URL?
    /// A resume point requested before the item was ready to honour it.
    private var pendingSeek: Double?
    /// Watches the item's readiness directly. The periodic time observer does
    /// not tick while paused, so it cannot be relied on to notice readiness.
    private var statusObservation: NSKeyValueObservation?
    /// Follows what the player is really doing. The system pauses playback
    /// itself (a call, leaving the app, headphones unplugged) and the play
    /// button has to agree with it afterwards.
    private var timeControlObservation: NSKeyValueObservation?

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
        timeControlObservation = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] engine, _ in
            let playing = engine.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, !self.isScrubbing, self.isPlaying != playing else { return }
                self.isPlaying = playing
            }
        }
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
        // Only when it changes: every write wakes everything watching it.
        if total.isFinite, total > 0, total != duration { duration = total }

        // Until the take has settled at its resume point, keep showing that
        // point instead of the player's pre-seek time of zero.
        guard isSettled, !isScrubbing else { return }
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
            AudioSession.preparePlayback()
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

    // MARK: - Picture in Picture

    /// Keeps the take playing in a floating window when you leave the
    /// thread or the app. It also starts by itself if you leave the app
    /// while a take is playing.
    func attachPictureInPicture(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              pictureInPicture == nil,
              let controller = AVPictureInPictureController(playerLayer: layer) else { return }
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        let delegate = PictureInPictureDelegate(owner: self)
        controller.delegate = delegate
        pictureInPicture = controller
        pictureInPictureDelegate = delegate
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.canPictureInPicture = possible }
        }
    }

    func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        if pictureInPicture.isPictureInPictureActive {
            pictureInPicture.stopPictureInPicture()
        } else {
            AudioSession.preparePlayback()
            if !isPlaying { togglePlay() }
            pictureInPicture.startPictureInPicture()
        }
    }

    fileprivate func pictureInPictureChanged(active: Bool) {
        isPictureInPictureActive = active
        // The thread was closed while the window floated. Once the window
        // goes, nothing needs this player any more.
        if !active, PictureInPictureKeeper.shared.kept === self {
            PictureInPictureKeeper.shared.kept = nil
            teardown()
        }
    }

    // MARK: - Scrubbing

    /// A finger went down on the scrubber: stop the clock driving the knob,
    /// and pause so the picture can follow the finger.
    func beginScrub() {
        guard let player, player.currentItem != nil else { return }
        isScrubbing = true
        resumeAfterScrub = isPlaying
        if isPlaying {
            player.pause()
            isPlaying = false
        }
    }

    /// While dragging: the knob goes exactly where the finger is, and the
    /// picture follows to the nearest frame it can reach quickly.
    func scrub(to seconds: Double) {
        guard let player else { return }
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .positiveInfinity,
            toleranceAfter: .positiveInfinity
        )
    }

    /// Finger up: land on the exact frame, then hand the knob back to the
    /// clock and carry on playing if it was playing.
    func endScrub() {
        guard let player, isScrubbing else { return }
        player.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isScrubbing = false
                if self.resumeAfterScrub {
                    self.resumeAfterScrub = false
                    AudioSession.preparePlayback()
                    self.player?.playImmediately(atRate: self.rate)
                    self.isPlaying = true
                }
            }
        }
    }

    private func reset() {
        isScrubbing = false
        resumeAfterScrub = false
        isSettled = false
        isPlaying = false
        currentTime = 0
        duration = 0
        pendingSeek = nil
    }

    /// Called when the thread closes, not between takes.
    func teardown() {
        possibleObservation = nil
        pictureInPicture?.delegate = nil
        pictureInPicture = nil
        pictureInPictureDelegate = nil
        isPictureInPictureActive = false
        statusObservation = nil
        timeControlObservation = nil
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        loadedURL = nil
        reset()
    }
}


/// The app's audio, set for what is happening.
///
/// The camera switches the session to record when the recorder opens and
/// leaves it there after it closes. Played back like that, a take can come out
/// of the earpiece, quietly, or not at all. Playback puts it back.
enum AudioSession {
    static func preparePlayback() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playback || session.mode != .moviePlayback else {
            try? session.setActive(true)
            return
        }
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}


/// Holds a thread's player while its take floats in Picture in Picture after
/// the thread itself has closed.
@MainActor
final class PictureInPictureKeeper {
    static let shared = PictureInPictureKeeper()
    var kept: ThreadPlayer?
}

/// AVKit's delegate, kept separate so ThreadPlayer can stay a plain
/// observable class.
private final class PictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    weak var owner: ThreadPlayer?

    init(owner: ThreadPlayer) { self.owner = owner }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        let owner = self.owner
        Task { @MainActor in owner?.pictureInPictureChanged(active: true) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        let owner = self.owner
        Task { @MainActor in owner?.pictureInPictureChanged(active: false) }
    }

    /// Tapping the window's return button takes you back to the thread.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        nonisolated(unsafe) let finish = completionHandler
        let owner = self.owner
        Task { @MainActor in
            if let talk = owner?.talkID, ThreadContext.shared.openTalk != talk {
                IntentRouter.shared.openTalkID = talk
            }
            finish(true)
        }
    }
}
