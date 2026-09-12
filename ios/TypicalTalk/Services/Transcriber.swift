import AVFoundation
import Foundation
import OSLog
import Speech

/// On-device transcription of a finished take, using the iOS 26 Speech
/// analyser. Nothing leaves the phone, which is why the power features are
/// free. Every failure path returns an empty transcript rather than throwing,
/// so sending or seeding a take never depends on speech succeeding.
enum Transcriber {
    private static let log = Logger(subsystem: "com.typicaltalk", category: "transcribe")

    static func segments(for url: URL) async -> [TranscriptSegment] {
        guard SpeechTranscriber.isAvailable else {
            log.error("TT: SpeechTranscriber unavailable on this device")
            return []
        }
        guard await requestAuthorization() else {
            log.error("TT: speech permission refused")
            return []
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            log.error("TT: no supported locale for \(Locale.current.identifier)")
            return []
        }

        // AVAudioFile cannot read a movie file, so pull the audio out first.
        // Passing the .mp4 straight in is what crashed on device.
        guard let audioURL = await audioTrack(of: url) else {
            log.error("TT: no readable audio in \(url.lastPathComponent)")
            return []
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        do {
            try await ensureModel(for: transcriber)

            let file = try AVAudioFile(forReading: audioURL)
            // The analyser is fed exactly once, by its initialiser. Also
            // calling analyzeSequence traps.
            let analyzer = try await SpeechAnalyzer(
                inputAudioFile: file,
                modules: [transcriber],
                finishAfterFile: true
            )

            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(start: result.range.start.seconds, text: text))
            }
            try? await analyzer.finalizeAndFinishThroughEndOfInput()

            log.notice("TT: \(segments.count) segments from \(url.lastPathComponent)")
            return segments.sorted { $0.start < $1.start }
        } catch {
            log.error("TT: failed on \(url.lastPathComponent): \(error.localizedDescription)")
            return []
        }
    }

    /// Exports just the audio into a temporary m4a the analyser can read.
    private static func audioTrack(of url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              !tracks.isEmpty else { return nil }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else { return nil }

        do {
            try await export.export(to: output, as: .m4a)
            return output
        } catch {
            log.error("TT: audio export failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Downloads the language model the first time it is needed, and reserves
    /// the locale so it stays installed.
    private static func ensureModel(for transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        for locale in transcriber.selectedLocales {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
    }

    private static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }
}
