@preconcurrency import AVFoundation
import Observation
import UIKit

/// Wraps the capture session for the recorder sheet. Convenience beats
/// fidelity here: one tap starts, one tap stops, and the session stays warm
/// while the sheet is open.
@MainActor
@Observable
final class CameraController: NSObject {
    enum Authorization: Equatable {
        case undetermined, granted, denied
    }

    enum Facing: Equatable { case front, back }

    private(set) var authorization: Authorization = .undetermined
    private(set) var isRecording = false
    private(set) var elapsed: Double = 0
    private(set) var failure: String?
    /// True when the device has no usable camera. Video is impossible, but a
    /// voice-only Talk still is, so the sheet says so rather than pretending.
    private(set) var cameraUnavailable = false
    var facing: Facing = .front
    var voiceOnly = false

    /// Takes recorded in this sheet, newest last so the filmstrip reads left
    /// to right.
    private(set) var takes: [Take] = []

    struct Take: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var duration: Double
        var voiceOnly: Bool
    }

    /// The session and its output are touched from the capture queue as well
    /// as the main actor, and AVFoundation serialises that itself.
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "com.typicaltalk.capture")
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var configured = false
    private var timer: Timer?
    /// The output confirms the start asynchronously, so a take that never
    /// really begins is caught by a watchdog rather than spinning forever.
    private var didStart = false
    private var watchdog: Task<Void, Never>?
    private var startedAt: Date?
    private var finishContinuation: CheckedContinuation<Take?, Never>?

    /// The two minute cap from the recorder HUD.
    let maximumDuration: Double = 120

    // MARK: - Permission and setup

    func prepare() async {
        let camera = await Self.authorize(.video)
        let mic = await Self.authorize(.audio)
        authorization = (camera && mic) ? .granted : .denied
        guard authorization == .granted else { return }
        await configureIfNeeded()
        if videoInput == nil {
            cameraUnavailable = true
            voiceOnly = true
        }
        start()
    }

    private static func authorize(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    private func configureIfNeeded() async {
        guard !configured else { return }
        configured = true
        let videoDevice = Self.device(for: facing)
        let audioDevice = AVCaptureDevice.default(for: .audio)
        let video = videoDevice.flatMap { try? AVCaptureDeviceInput(device: $0) }
        let audio = audioDevice.flatMap { try? AVCaptureDeviceInput(device: $0) }
        videoInput = video
        audioInput = audio

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [session, movieOutput] in
                session.beginConfiguration()
                session.sessionPreset = .high
                if let video, session.canAddInput(video) { session.addInput(video) }
                if let audio, session.canAddInput(audio) { session.addInput(audio) }
                if session.canAddOutput(movieOutput) {
                    session.addOutput(movieOutput)
                    if let connection = movieOutput.connection(with: .video),
                       connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                }
                session.commitConfiguration()
                continuation.resume()
            }
        }
    }

    private static func device(for facing: Facing) -> AVCaptureDevice? {
        AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: facing == .front ? .front : .back
        )
    }

    func start() {
        guard authorization == .granted else { return }
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        if isRecording { movieOutput.stopRecording() }
        timer?.invalidate()
        timer = nil
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Flip

    func flip() {
        facing = facing == .front ? .back : .front
        guard let device = Self.device(for: facing),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let old = videoInput
        videoInput = input
        queue.async { [session] in
            session.beginConfiguration()
            if let old { session.removeInput(old) }
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            _ = finishRecording()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        guard authorization == .granted, !movieOutput.isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("take-\(UUID().uuidString).mov")
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            connection.isVideoMirrored = facing == .front && connection.isVideoMirroringSupported
        }
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        didStart = false
        startWatchdog()
        elapsed = 0
        startedAt = .now
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date.now.timeIntervalSince(startedAt)
        if elapsed >= maximumDuration { finishRecording() }
    }

    @discardableResult
    private func finishRecording() -> Bool {
        guard isRecording else { return false }
        guard didStart, movieOutput.isRecording else {
            // Never actually began, so there is no file and no delegate call.
            resetRecordingState()
            return false
        }
        movieOutput.stopRecording()
        timer?.invalidate()
        timer = nil
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        return true
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.isRecording, !self.didStart else { return }
            self.failure = "The recorder could not start. Check that a camera and microphone are available."
            self.resetRecordingState()
        }
    }

    private func resetRecordingState() {
        watchdog?.cancel()
        watchdog = nil
        didStart = false
        timer?.invalidate()
        timer = nil
        isRecording = false
        startedAt = nil
        elapsed = 0
        finishContinuation?.resume(returning: nil)
        finishContinuation = nil
    }

    /// Stops the current take and waits for the file to be written, so the
    /// caller can transcribe it immediately.
    func finishAndWait() async -> Take? {
        guard isRecording, didStart, movieOutput.isRecording else {
            resetRecordingState()
            return takes.last
        }
        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
            _ = finishRecording()
        }
    }

    func delete(_ take: Take) {
        takes.removeAll { $0.id == take.id }
        try? FileManager.default.removeItem(at: take.url)
    }

    func discardAll() {
        for take in takes { try? FileManager.default.removeItem(at: take.url) }
        takes.removeAll()
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor in
            self.didStart = true
            self.watchdog?.cancel()
            self.watchdog = nil
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        let message = error.map { "Recording stopped: \($0.localizedDescription)" }
        Task { @MainActor in
            self.watchdog?.cancel()
            self.watchdog = nil
            self.didStart = false
            self.isRecording = false
            self.startedAt = nil
            let duration = self.elapsed
            self.elapsed = 0

            guard message == nil else {
                self.failure = message
                self.finishContinuation?.resume(returning: nil)
                self.finishContinuation = nil
                return
            }
            let take = Take(url: outputFileURL, duration: duration, voiceOnly: self.voiceOnly)
            self.takes.append(take)
            self.finishContinuation?.resume(returning: take)
            self.finishContinuation = nil
        }
    }
}
