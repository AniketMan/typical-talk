import Foundation

struct Person: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var isYou: Bool = false

    var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    init(id: UUID = UUID(), name: String, isYou: Bool = false) {
        self.id = id
        self.name = name
        self.isYou = isYou
    }
}

/// One segment of an on-device transcript. `start` is seconds into the take,
/// which is what makes tapping a word seek the player.
struct TranscriptSegment: Identifiable, Hashable, Sendable {
    let id: UUID
    var start: Double
    var text: String

    init(id: UUID = UUID(), start: Double, text: String) {
        self.id = id
        self.start = start
        self.text = text
    }
}

/// An auto-chapter, segmented on device and drawn as a tick on the scrubber.
struct Chapter: Identifiable, Hashable, Sendable {
    let id: UUID
    var start: Double
    var title: String

    init(id: UUID = UUID(), start: Double, title: String) {
        self.id = id
        self.start = start
        self.title = title
    }
}

struct Message: Identifiable, Hashable, Sendable {
    let id: UUID
    var author: Person
    var sentAt: Date
    var duration: Double
    var isVoiceOnly: Bool = false
    var watched: Bool = false
    var bookmarkedAt: [Double] = []
    var reactions: [String] = []
    var transcript: [TranscriptSegment] = []
    var chapters: [Chapter] = []
    /// Set when the take was captured on this device in this session.
    var localVideoURL: URL?

    var summaryLine: String {
        transcript.first?.text ?? "No transcript yet"
    }

    init(
        id: UUID = UUID(),
        author: Person,
        sentAt: Date,
        duration: Double,
        isVoiceOnly: Bool = false,
        watched: Bool = false,
        bookmarkedAt: [Double] = [],
        reactions: [String] = [],
        transcript: [TranscriptSegment] = [],
        chapters: [Chapter] = [],
        localVideoURL: URL? = nil
    ) {
        self.id = id
        self.author = author
        self.sentAt = sentAt
        self.duration = duration
        self.isVoiceOnly = isVoiceOnly
        self.watched = watched
        self.bookmarkedAt = bookmarkedAt
        self.reactions = reactions
        self.transcript = transcript
        self.chapters = chapters
        self.localVideoURL = localVideoURL
    }
}

struct Talk: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var members: [Person]
    /// Newest first, everywhere (locked ordering decision).
    var messages: [Message]

    var isGroup: Bool { members.count > 2 }
    var latest: Message? { messages.first }
    var unreadCount: Int { messages.filter { !$0.watched && !$0.author.isYou }.count }
    var hasUnread: Bool { unreadCount > 0 }

    var initials: String {
        title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// Total unwatched runtime, used for the catch-up card.
    var unreadDuration: Double {
        messages.filter { !$0.watched && !$0.author.isYou }.map(\.duration).reduce(0, +)
    }

    init(id: UUID = UUID(), title: String, members: [Person], messages: [Message]) {
        self.id = id
        self.title = title
        self.members = members
        self.messages = messages
    }

    /// The quiet line under the title. Derived from what is actually true of
    /// this thread, so it can never claim someone is watching when no one is.
    var statusLine: String? {
        if let newest = messages.first, !newest.watched, !newest.author.isYou {
            let who = newest.author.name.split(separator: " ").first.map(String.init) ?? newest.author.name
            return unreadCount > 1
                ? "\(who) and others sent \(unreadCount) new takes"
                : "\(who) sent a new take"
        }
        if let mine = messages.first, mine.author.isYou {
            return mine.watched ? "Sent" : "Sending"
        }
        if let newest = messages.first {
            return "Watched \(relativeLabel(newest.sentAt).lowercased())"
        }
        return nil
    }
}

struct Bookmark: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var talkID: UUID
    var messageID: UUID
    var author: Person
    var at: Double
    var savedAt: Date

    init(id: UUID = UUID(), title: String, talkID: UUID, messageID: UUID, author: Person, at: Double, savedAt: Date) {
        self.id = id
        self.title = title
        self.talkID = talkID
        self.messageID = messageID
        self.author = author
        self.at = at
        self.savedAt = savedAt
    }
}

struct Highlight: Identifiable, Hashable, Sendable {
    let id: UUID
    var talkTitle: String
    var subtitle: String
    var points: [String]
    var duration: Double

    init(id: UUID = UUID(), talkTitle: String, subtitle: String, points: [String], duration: Double) {
        self.id = id
        self.talkTitle = talkTitle
        self.subtitle = subtitle
        self.points = points
        self.duration = duration
    }
}

enum NotificationKind: Sendable {
    case reaction, mention, watchReceipt
}

struct AppNotification: Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: NotificationKind
    var text: String
    var detail: String
    var at: Date

    var symbol: String {
        switch kind {
        case .reaction: "heart"
        case .mention: "at"
        case .watchReceipt: "checkmark.circle"
        }
    }

    init(id: UUID = UUID(), kind: NotificationKind, text: String, detail: String, at: Date) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.at = at
    }
}

/// A single result row in the transcript search.
struct TranscriptMatch: Identifiable, Hashable, Sendable {
    let id = UUID()
    var talk: Talk
    var message: Message
    var segment: TranscriptSegment
}
