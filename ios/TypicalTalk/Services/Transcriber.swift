import AVFoundation
import Foundation
import Speech
import OSLog

/// On-device transcription of a finished take, using the iOS 26 Speech
/// analyser. Nothing leaves the phone, which is the whole reason the power
/// features are free.
enum Transcriber {
    private static let log = Logger(subsystem: "com.typicaltalk", category: "transcribe")

    /// Transcribes the audio track of a recorded file into timed segments.
    /// Returns an empty array rather than throwing when the model or the
    /// permission is unavailable, so sending a take never blocks on speech.
    static func segments(for url: URL) async -> [TranscriptSegment] {
        guard SpeechTranscriber.isAvailable else {
            log.error("TT: SpeechTranscriber unavailable on this device")
            return []
        }
        guard await requestAuthorization() else {
            log.error("TT: speech permission refused")
            return []
        }

        let locale = Locale.current
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            log.error("TT: no supported locale matching \(locale.identifier)")
            return []
        }

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
            log.notice("TT: transcribed \(segments.count) segments")
            return segments.sorted { $0.start < $1.start }
        } catch {
            log.error("TT: failed: \(error.localizedDescription)")
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
