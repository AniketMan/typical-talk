import Foundation
import Observation

/// Single source of truth for the app. Everything is on device: there is no
/// network layer by design, and the power features cost nothing to give.
@MainActor
@Observable
final class AppStore {
    var talks: [Talk]
    var bookmarks: [Bookmark]
    var highlights: [Highlight]
    var notifications: [AppNotification]

    // Preferences surfaced in the You tab.
    var alwaysShowCaptions = true
    var autoplayNewTakes = false
    var notificationsEnabled = true

    /// Threads the user has invited people into during this session.
    /// Where the user got to in each take. Leaving a thread, recording a
    /// reply, or switching takes all come back to the same second.
    private var playbackPositions: [Message.ID: Double] = [:]

    var invitedContacts: Set<String> = []
    var skippedContacts: Set<String> = []
    var contactsSynced = false

    private(set) var isLoadingSeed = true

    init() {
        talks = []
        bookmarks = []
        highlights = []
        notifications = []
    }

    /// Loads the bundled conversations. Transcription is deliberately not
    /// done here: it runs on demand when a thread is opened, so a slow or
    /// failing speech model cannot hold up or take down launch.
    func loadSeed() async {
        guard talks.isEmpty else { return }
        talks = await SampleData.talks()
        isLoadingSeed = false
    }

    var unreadNotificationCount: Int { derivedNotifications.count }

    /// Highlights are built from transcripts already on the phone, never
    /// written in advance. A thread with nothing transcribed produces nothing.
    var derivedHighlights: [Highlight] {
        talks.compactMap { talk in
            let lines = talk.messages
                .filter { !$0.transcript.isEmpty }
                .prefix(4)
                .compactMap { $0.transcript.first?.text }
            guard lines.count >= 2 else { return nil }
            return Highlight(
                talkTitle: talk.title,
                subtitle: "^[\(talk.messages.count) take](inflect: true) on this device",
                points: Array(lines),
                duration: talk.messages.prefix(4).map(\.duration).reduce(0, +)
            )
        }
    }

    /// Notifications come from the model's own state: reactions that exist,
    /// and takes of yours that have been watched.
    var derivedNotifications: [AppNotification] {
        var result: [AppNotification] = []
        for talk in talks {
            for message in talk.messages where message.author.isYou {
                if !message.reactions.isEmpty {
                    result.append(AppNotification(
                        kind: .reaction,
                        text: "\(message.reactions.joined()) on your take",
                        detail: talk.title,
                        at: message.sentAt
                    ))
                }
                if message.watched {
                    result.append(AppNotification(
                        kind: .watchReceipt,
                        text: "Your take was watched",
                        detail: talk.title,
                        at: message.sentAt
                    ))
                }
            }
        }
        return result.sorted { $0.at > $1.at }
    }

    func talk(id: Talk.ID) -> Talk? { talks.first { $0.id == id } }

    func binding(for id: Talk.ID) -> Int? { talks.firstIndex { $0.id == id } }

    private var transcribing: Set<Message.ID> = []

    /// Transcribes one take on device, once. Safe to call repeatedly.
    func ensureTranscript(for messageID: Message.ID, in talkID: Talk.ID) async {
        guard let t = binding(for: talkID),
              let m = talks[t].messages.firstIndex(where: { $0.id == messageID }),
              talks[t].messages[m].transcript.isEmpty,
              let url = talks[t].messages[m].localVideoURL,
              transcribing.insert(messageID).inserted else { return }
        defer { transcribing.remove(messageID) }

        let duration = talks[t].messages[m].duration
        let segments = await Transcriber.segments(for: url)
        guard !segments.isEmpty else { return }

        // The store may have changed while that ran, so find the take again.
        guard let t2 = binding(for: talkID),
              let m2 = talks[t2].messages.firstIndex(where: { $0.id == messageID }) else { return }
        talks[t2].messages[m2].transcript = segments
        talks[t2].messages[m2].chapters = Self.chapters(from: segments, duration: duration)
    }

    /// Transcribes a whole thread, newest first, one at a time.
    func ensureTranscripts(in talkID: Talk.ID) async {
        guard let t = binding(for: talkID) else { return }
        for message in talks[t].messages {
            await ensureTranscript(for: message.id, in: talkID)
        }
    }

    // MARK: - Resume

    func resumePosition(for messageID: Message.ID) -> Double {
        playbackPositions[messageID] ?? 0
    }

    /// Saves progress, unless the take is essentially finished, in which case
    /// it should start again from the top next time.
    func saveProgress(_ time: Double, for messageID: Message.ID, duration: Double) {
        guard time > 0.4, duration > 0 else {
            playbackPositions[messageID] = nil
            return
        }
        // Scaled to the clip: a ten second take should not count as finished
        // with a second and a half still to run.
        let endZone = min(1.5, max(0.4, duration * 0.06))
        if time >= duration - endZone {
            playbackPositions[messageID] = nil
        } else {
            playbackPositions[messageID] = time
        }
    }

    func clearProgress(for messageID: Message.ID) {
        playbackPositions[messageID] = nil
    }

    // MARK: - Mutations

    func markWatched(messageID: Message.ID, in talkID: Talk.ID) {
        guard let t = binding(for: talkID),
              let m = talks[t].messages.firstIndex(where: { $0.id == messageID }) else { return }
        talks[t].messages[m].watched = true
    }

    func markAllWatched(in talkID: Talk.ID) {
        guard let t = binding(for: talkID) else { return }
        for i in talks[t].messages.indices { talks[t].messages[i].watched = true }
    }

    func toggleReaction(_ emoji: String, messageID: Message.ID, in talkID: Talk.ID) {
        guard let t = binding(for: talkID),
              let m = talks[t].messages.firstIndex(where: { $0.id == messageID }) else { return }
        if let existing = talks[t].messages[m].reactions.firstIndex(of: emoji) {
            talks[t].messages[m].reactions.remove(at: existing)
        } else {
            talks[t].messages[m].reactions.append(emoji)
        }
    }

    /// Bookmarks a moment and files it in the Archive shelf in one step.
    func addBookmark(at time: Double, messageID: Message.ID, in talkID: Talk.ID) {
        guard let t = binding(for: talkID),
              let m = talks[t].messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard !talks[t].messages[m].bookmarkedAt.contains(where: { abs($0 - time) < 0.5 }) else { return }
        talks[t].messages[m].bookmarkedAt.append(time)

        let message = talks[t].messages[m]
        let label = message.transcript
            .last(where: { $0.start <= time })?
            .text ?? "Saved moment"
        bookmarks.insert(
            Bookmark(
                title: String(label.prefix(42)),
                talkID: talkID,
                messageID: messageID,
                author: message.author,
                at: time,
                savedAt: .now
            ),
            at: 0
        )
    }

    /// Files a freshly recorded take at the top of a thread.
    func send(take url: URL, duration: Double, transcript: [TranscriptSegment], voiceOnly: Bool, to talkID: Talk.ID) {
        guard let t = binding(for: talkID) else { return }
        let message = Message(
            author: SampleData.you,
            sentAt: .now,
            duration: duration,
            isVoiceOnly: voiceOnly,
            watched: true,
            transcript: transcript,
            chapters: Self.chapters(from: transcript, duration: duration),
            localVideoURL: url
        )
        talks[t].messages.insert(message, at: 0)
        // Newest thread floats to the top of the Talks list.
        let moved = talks.remove(at: t)
        talks.insert(moved, at: 0)
    }

    /// Cheap on-device segmentation: a chapter every time the speaker pauses
    /// for long enough that the next segment starts a new idea.
    static func chapters(from transcript: [TranscriptSegment], duration: Double) -> [Chapter] {
        guard !transcript.isEmpty else { return [] }
        var result: [Chapter] = [Chapter(start: 0, title: "Opening")]
        var lastCut = 0.0
        for segment in transcript.dropFirst() where segment.start - lastCut > 20 {
            result.append(Chapter(start: segment.start, title: String(segment.text.prefix(24))))
            lastCut = segment.start
        }
        return result
    }

    // MARK: - Search

    /// Full-text search across on-device transcripts. Case and diacritic
    /// insensitive so "cafe" finds "café".
    func search(_ query: String) -> [TranscriptMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var results: [TranscriptMatch] = []
        for talk in talks {
            for message in talk.messages {
                for segment in message.transcript
                where segment.text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    results.append(TranscriptMatch(talk: talk, message: message, segment: segment))
                }
            }
        }
        return results.sorted { $0.message.sentAt > $1.message.sentAt }
    }
}
