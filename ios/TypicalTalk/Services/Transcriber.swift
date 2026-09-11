import AVFoundation
import Foundation
import Speech

/// On-device transcription of a finished take, using the iOS 26 Speech
/// analyser. Nothing leaves the phone, which is the whole reason the power
/// features are free.
enum Transcriber {
    /// Transcribes the audio track of a recorded file into timed segments.
    /// Returns an empty array rather than throwing when the model or the
    /// permission is unavailable, so sending a take never blocks on speech.
    static func segments(for url: URL) async -> [TranscriptSegment] {
        guard SpeechTranscriber.isAvailable else { return [] }
        guard await requestAuthorization() else { return [] }

        let locale = Locale.current
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return [] }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        do {
            try await ensureModel(for: transcriber)
            let file = try AVAudioFile(forReading: url)
            let analyzer = try await SpeechAnalyzer(
                inputAudioFile: file,
                modules: [transcriber],
                finishAfterFile: true
            )
            _ = try await analyzer.analyzeSequence(from: file)

            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(start: result.range.start.seconds, text: text))
            }
            return segments.sorted { $0.start < $1.start }
        } catch {
            return []
        }
    }

    /// Downloads the language model the first time it is needed, and holds a
    /// reservation so it stays installed.
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
