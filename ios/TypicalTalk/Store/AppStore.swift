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
    var invitedContacts: Set<String> = []
    var skippedContacts: Set<String> = []
    var contactsSynced = false

    init() {
        let seeded = SampleData.talks()
        talks = seeded
        bookmarks = SampleData.bookmarks(for: seeded)
        highlights = SampleData.highlights
        notifications = SampleData.notifications()
    }

    var unreadNotificationCount: Int { notifications.count }

    func talk(id: Talk.ID) -> Talk? { talks.first { $0.id == id } }

    func binding(for id: Talk.ID) -> Int? { talks.firstIndex { $0.id == id } }

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
