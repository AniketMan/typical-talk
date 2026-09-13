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

    /// How the take is framed. On an iPhone 17 front camera the square sensor
    /// lets the user pick this without turning the phone. Everywhere else it
    /// follows how the phone is actually being held.
    enum Framing: Equatable {
        case portrait, landscape

        var aspectRatio: AVCaptureDevice.AspectRatio {
            self == .portrait ? .ratio9x16 : .ratio16x9
        }
    }

    private(set) var authorization: Authorization = .undetermined
    private(set) var isRecording = false
    private(set) var elapsed: Double = 0
    private(set) var failure: String?
    /// True when the device has no usable camera. Video is impossible, but a
    /// voice-only Talk still is, so the sheet says so rather than pretending.
    private(set) var cameraUnavailable = false

    /// True only when the active camera has a square sensor that can reframe
    /// without the phone being rotated. iPhone 17 front camera today.
    private(set) var supportsDynamicFraming = false
    private(set) var framing: Framing = .portrait
    /// The angle the recorded file needs so it is horizon level, straight from
    /// the system rather than assumed.
    private(set) var captureRotationAngle: CGFloat = 90
    /// True when the sensor itself is giving us a square, so no cropping is
    /// needed and no part of the frame is lost.
    private(set) var recordsNativeSquare = false
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
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureAngleObservation: NSKeyValueObservation?
    private var previewAngleObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
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
        refreshDynamicFraming()
        preferNativeSquare()
        startRotationCoordinator()
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
                    Self.applySquareOutput(to: movieOutput)
                }
                session.commitConfiguration()
                continuation.resume()
            }
        }
    }

    /// The preview layer hands itself over so the rotation coordinator can
    /// keep the preview horizon level too.
    func attach(previewLayer layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        startRotationCoordinator()
    }

    /// Replaces the hardcoded rotation with the system's own answer, observed
    /// live so turning the phone mid-session is handled.
    private func startRotationCoordinator() {
        captureAngleObservation = nil
        previewAngleObservation = nil
        guard let device = videoInput?.device else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewAngle(coordinator.videoRotationAngleForHorizonLevelPreview)
        captureRotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture

        captureAngleObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in self?.captureRotationAngle = angle }
        }
        previewAngleObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in self?.applyPreviewAngle(angle) }
        }
    }

    private func applyPreviewAngle(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// Reads whether this camera can reframe without the phone turning, and
    /// seeds the current framing from the device.
    private func refreshDynamicFraming() {
        guard let device = videoInput?.device else {
            supportsDynamicFraming = false
            return
        }
        let supported = device.activeFormat.supportedDynamicAspectRatios
        supportsDynamicFraming = supported.contains(.ratio9x16) && supported.contains(.ratio16x9)
        guard supportsDynamicFraming else { return }
        framing = device.dynamicAspectRatio == .ratio16x9 ? .landscape : .portrait
    }

    /// A square sensor can deliver 1:1 directly, with the whole frame intact.
    /// Preferred over cropping whenever the hardware offers it.
    private func preferNativeSquare() {
        guard let device = videoInput?.device,
              device.activeFormat.supportedDynamicAspectRatios.contains(.ratio1x1) else {
            // Only some sensors are square. On an iPhone 17 the front camera
            // is and the rear one is not, so this has to be re-checked on
            // every flip and fall back to cropping when it comes up empty.
            recordsNativeSquare = false
            return
        }
        recordsNativeSquare = true
        device.setDynamicAspectRatio(.ratio1x1) { _, error in
            guard let error else { return }
            Task { @MainActor in
                self.recordsNativeSquare = false
                self.failure = "Could not use the square sensor: \(error.localizedDescription)"
            }
        }
    }

    /// Only meaningful on a square sensor. Asks the device to reframe; the
    /// phone does not move.
    func setFraming(_ next: Framing) {
        guard supportsDynamicFraming, next != framing, let device = videoInput?.device else { return }
        framing = next
        device.setDynamicAspectRatio(next.aspectRatio) { _, error in
            guard let error else { return }
            Task { @MainActor in
                self.failure = "Could not switch framing: \(error.localizedDescription)"
            }
        }
    }

    /// Records a 1080 by 1080 square.
    ///
    /// Measured beforehand, a take was 1080x1920 HEVC at 7.96 Mbps of video,
    /// about 1 MB per second.
    ///
    /// Two ways to get there, and they are not equivalent. Where the sensor
    /// shoots a native square, ask it for one: nothing is thrown away. Where
    /// it does not, cropping keeps the full 1080 width and discards 44 percent
    /// of the height, which on a selfie held at arm's length cuts off the top
    /// and bottom of the frame.
    static let squareSide = 1080
    static let videoBitRate = 4_500_000

    private static func applySquareOutput(to output: AVCaptureMovieFileOutput) {
        guard let connection = output.connection(with: .video) else { return }
        let available = output.supportedOutputSettingsKeys(for: connection)
        guard available.contains(AVVideoWidthKey), available.contains(AVVideoHeightKey) else { return }

        // The crop is the fallback. On a square sensor the source is already
        // 1:1, so this scales rather than discarding any of the frame.
        let codec: AVVideoCodecType = output.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: squareSide,
            AVVideoHeightKey: squareSide
        ]
        // Crop to fill rather than squash the picture into a square.
        if available.contains(AVVideoScalingModeKey) {
            settings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspectFill
        }
        if available.contains(AVVideoCompressionPropertiesKey) {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        }
        output.setOutputSettings(settings, for: connection)
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
        refreshDynamicFraming()
        preferNativeSquare()
        startRotationCoordinator()
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
            // Horizon level per the system, not a guess. This is what stops a
            // portrait take being written out as landscape.
            let angle = captureRotationAngle
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            // Match the system camera: the preview mirrors, the file does not.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
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
