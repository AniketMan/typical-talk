import Foundation

struct Person: Identifiable, Hashable, Sendable, Codable {
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
struct TranscriptSegment: Identifiable, Hashable, Sendable, Codable {
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
struct Chapter: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var start: Double
    var title: String

    init(id: UUID = UUID(), start: Double, title: String) {
        self.id = id
        self.start = start
        self.title = title
    }
}

/// Where one of your own takes has got to on its way to the other person.
enum Delivery: String, Hashable, Sendable, Codable {
    /// On the server. Takes that arrive from other people are always this.
    case sent
    /// Still uploading, or waiting for a connection to upload.
    case sending
    /// The server or the network refused it. Can be retried.
    case failed
}

struct Message: Identifiable, Hashable, Sendable, Codable {
    /// The same id on every phone and on the server, so a take is never
    /// duplicated by syncing it back.
    let id: UUID
    var author: Person
    var sentAt: Date
    var duration: Double
    var isVoiceOnly: Bool = false
    /// Whether you have watched it. Your own takes count as watched.
    var watched: Bool = false
    /// People who have watched it, which is what a receipt is. Only the
    /// sender is told, so this is empty on takes from other people.
    var watchedBy: [UUID] = []
    var delivery: Delivery = .sent
    var bookmarkedAt: [Double] = []
    var reactions: [String] = []
    var transcript: [TranscriptSegment] = []
    var chapters: [Chapter] = []
    /// The file in the takes folder, by name. A name rather than a URL,
    /// because the app's container path can change between launches.
    var fileName: String?

    /// Where the video is on this device, once it has been recorded here or
    /// downloaded.
    var localVideoURL: URL? { fileName.map(TakeFiles.url(for:)) }

    /// Nil until this take has actually been transcribed, so callers can omit
    /// the line instead of printing a placeholder on every row.
    var summaryLine: String? {
        transcript.first?.text
    }

    init(
        id: UUID = UUID(),
        author: Person,
        sentAt: Date,
        duration: Double,
        isVoiceOnly: Bool = false,
        watched: Bool = false,
        watchedBy: [UUID] = [],
        delivery: Delivery = .sent,
        bookmarkedAt: [Double] = [],
        reactions: [String] = [],
        transcript: [TranscriptSegment] = [],
        chapters: [Chapter] = [],
        fileName: String? = nil
    ) {
        self.id = id
        self.author = author
        self.sentAt = sentAt
        self.duration = duration
        self.isVoiceOnly = isVoiceOnly
        self.watched = watched
        self.watchedBy = watchedBy
        self.delivery = delivery
        self.bookmarkedAt = bookmarkedAt
        self.reactions = reactions
        self.transcript = transcript
        self.chapters = chapters
        self.fileName = fileName
    }
}

struct Talk: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var title: String
    var members: [Person]
    /// Newest first, everywhere (locked ordering decision).
    var messages: [Message]
    /// Set by the server for talks made as a group, so a group that has
    /// shrunk to two people is still a group.
    var isGroupTalk: Bool = false
    var createdAt: Date = .now

    var isGroup: Bool { isGroupTalk || members.count > 2 }
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

    init(
        id: UUID = UUID(),
        title: String,
        members: [Person],
        messages: [Message],
        isGroupTalk: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.members = members
        self.messages = messages
        self.isGroupTalk = isGroupTalk
        self.createdAt = createdAt
    }

    /// When the thread last had anything happen in it.
    var lastActivity: Date { latest?.sentAt ?? createdAt }

    /// The quiet line under the title. Derived from what is actually true of
    /// this thread, so it can never claim someone is watching when no one is.
    var statusLine: String? {
        if let newest = messages.first, !newest.watched, !newest.author.isYou {
            let who = newest.author.name.split(separator: " ").first.map(String.init) ?? newest.author.name
            guard unreadCount > 1 else { return "\(who) sent a new take" }
            let unreadAuthors = Set(
                messages.filter { !$0.watched && !$0.author.isYou }.map(\.author.id)
            )
            return unreadAuthors.count > 1
                ? "\(who) and others sent \(unreadCount) new takes"
                : "\(who) sent \(unreadCount) new takes"
        }
        if let mine = messages.first, mine.author.isYou {
            switch mine.delivery {
            case .sending: return "Sending"
            case .failed: return "Not sent"
            case .sent: return mine.watchedBy.isEmpty ? "Delivered" : "Watched"
            }
        }
        if let newest = messages.first {
            return "Watched \(relativeLabel(newest.sentAt).lowercased())"
        }
        return nil
    }
}

struct Bookmark: Identifiable, Hashable, Sendable, Codable {
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
