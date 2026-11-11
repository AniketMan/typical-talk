import AVFoundation
import Observation

/// A take you are partway through recording.
///
/// Closing the recorder does not throw it away. It pauses, keeps what you
/// recorded so far, and waits above the tab bar so you can go and watch
/// something, then come back and carry on. Recording again adds to it;
/// sending joins the pieces into one take.
@MainActor
@Observable
final class DraftRecorder {
    static let shared = DraftRecorder()

    struct Segment: Codable, Identifiable, Equatable {
        var id = UUID()
        var fileName: String
        var duration: Double
    }

    /// One camera for the life of the app, so pausing and resuming do not
    /// rebuild the capture session each time.
    let camera = CameraController()

    private(set) var talkID: Talk.ID?
    private(set) var segments: [Segment] = []
    /// Fixed by the first segment: a take cannot switch between video and
    /// voice halfway through.
    private(set) var isVoiceOnly = false
    var isPresented = false

    /// Two minutes, across every segment.
    static let limit: Double = 120

    var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    var remaining: Double { max(0, Self.limit - duration) }
    var hasDraft: Bool { talkID != nil && !segments.isEmpty }

    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static let stateURL = directory.appendingPathComponent("draft.json")

    private struct Saved: Codable {
        var talkID: UUID
        var segments: [Segment]
        var isVoiceOnly: Bool
    }

    init() {
        camera.outputDirectory = Self.directory
        camera.onTake = { [weak self] take in self?.commit(take) }
        load()
    }

    // MARK: - Opening

    /// Opens the recorder for a talk. If a draft is already waiting, that is
    /// what opens: there is one draft at a time, and it is never lost by
    /// starting another.
    func open(for talkID: Talk.ID) {
        if !hasDraft { self.talkID = talkID }
        isPresented = true
    }

    func resume() {
        guard hasDraft else { return }
        isPresented = true
    }

    // MARK: - Recording

    func startSegment() {
        guard !camera.isRecording, remaining > 0.5 else { return }
        if segments.isEmpty { isVoiceOnly = camera.voiceOnly } else { camera.voiceOnly = isVoiceOnly }
        camera.maximumDuration = remaining
        camera.toggleRecording()
    }

    /// Ends the segment being recorded and keeps it.
    func pause() async {
        guard camera.isRecording else { return }
        _ = await camera.finishAndWait()
    }

    private func commit(_ take: CameraController.Take) {
        camera.clearTakes()
        // A tap-and-release that captured nothing is not worth keeping.
        guard take.duration > 0.3, take.url.deletingLastPathComponent().standardizedFileURL == Self.directory.standardizedFileURL else {
            try? FileManager.default.removeItem(at: take.url)
            return
        }
        segments.append(Segment(fileName: take.url.lastPathComponent, duration: take.duration))
        save()
    }

    #if DEBUG
    /// Debug only: a simulator has no camera, so tests feed segments in.
    func debugAddSegment(from source: URL, duration: Double, to talkID: Talk.ID) {
        self.talkID = talkID
        let name = "segment-\(UUID().uuidString).mov"
        try? FileManager.default.copyItem(at: source, to: Self.directory.appendingPathComponent(name))
        segments.append(Segment(fileName: name, duration: duration))
        save()
    }
    #endif

    /// The recorder went away, by swiping down or closing it. Whatever was
    /// being recorded is kept as a paused draft.
    func recorderClosed() async {
        await pause()
        camera.stop()
        if segments.isEmpty {
            talkID = nil
            save()
        }
    }

    func discard() {
        for segment in segments { try? FileManager.default.removeItem(at: url(of: segment)) }
        segments = []
        talkID = nil
        isVoiceOnly = false
        save()
    }

    // MARK: - Sending

    /// Joins the segments into one file. A single segment is used as it is.
    func assemble() async -> (url: URL, duration: Double)? {
        let urls = segments.map(url(of:)).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = urls.first else { return nil }
        if urls.count == 1 {
            let seconds = (try? await AVURLAsset(url: first).load(.duration).seconds) ?? duration
            return (first, seconds)
        }
        do {
            return try await Self.join(urls)
        } catch {
            return nil
        }
    }

    /// Called once the joined take has been handed to the store.
    func finishSent() {
        for segment in segments { try? FileManager.default.removeItem(at: url(of: segment)) }
        segments = []
        talkID = nil
        isVoiceOnly = false
        save()
    }

    private func url(of segment: Segment) -> URL {
        Self.directory.appendingPathComponent(segment.fileName)
    }

    /// Stitches segments end to end.
    ///
    /// When every segment was filmed the same way up and with the same
    /// camera, the pictures are copied without re-encoding. If you flipped
    /// cameras or turned the phone between segments, each one keeps its own
    /// orientation, which means rendering the result.
    private static func join(_ urls: [URL]) async throws -> (url: URL, duration: Double) {
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var pieces: [(start: CMTime, duration: CMTime, transform: CGAffineTransform, size: CGSize)] = []
        var hasVideo = false

        for url in urls {
            let asset = AVURLAsset(url: url)
            let length = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: length)
            if let video = try await asset.loadTracks(withMediaType: .video).first, let videoTrack {
                try videoTrack.insertTimeRange(range, of: video, at: cursor)
                let (transform, size) = try await video.load(.preferredTransform, .naturalSize)
                pieces.append((cursor, length, transform, size))
                hasVideo = true
            }
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack?.insertTimeRange(range, of: audio, at: cursor)
            }
            cursor = cursor + length
        }

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("joined-\(UUID().uuidString).mov")
        let uniform = Set(pieces.map { "\($0.transform)" }).count <= 1

        if !hasVideo, let videoTrack { composition.removeTrack(videoTrack) }

        if hasVideo, !uniform, let videoTrack, let first = pieces.first {
            let rendered = CGRect(origin: .zero, size: first.size).applying(first.transform)
            let video = AVMutableVideoComposition()
            video.renderSize = CGSize(width: abs(rendered.width), height: abs(rendered.height))
            video.frameDuration = CMTime(value: 1, timescale: 30)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            for piece in pieces { layer.setTransform(piece.transform, at: piece.start) }
            instruction.layerInstructions = [layer]
            video.instructions = [instruction]

            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw CocoaError(.fileWriteUnknown)
            }
            export.videoComposition = video
            try await export.export(to: output, as: .mov)
        } else {
            if let videoTrack, let first = pieces.first { videoTrack.preferredTransform = first.transform }
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try await export.export(to: output, as: .mov)
        }
        return (output, cursor.seconds)
    }

    // MARK: - Persistence

    private func save() {
        guard let talkID, !segments.isEmpty else {
            try? FileManager.default.removeItem(at: Self.stateURL)
            return
        }
        let saved = Saved(talkID: talkID, segments: segments, isVoiceOnly: isVoiceOnly)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        let present = saved.segments.filter { FileManager.default.fileExists(atPath: url(of: $0).path) }
        guard !present.isEmpty else { return }
        talkID = saved.talkID
        segments = present
        isVoiceOnly = saved.isVoiceOnly
    }

    /// Sign out: a draft belongs to the person who recorded it.
    func reset() {
        discard()
        isPresented = false
    }
}
