import AppIntents
import Foundation
import GeoToolbox
import LinkPresentation

/// Shared access to the store for intents, which run outside the view tree.
@MainActor
enum IntentBridge {
    static var store: AppStore?

    static func requireStore() async throws -> AppStore {
        guard let store else { throw TalkIntentError.notReady }
        if store.talks.isEmpty { await store.loadSeed() }
        return store
    }
}

enum TalkIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady, noSuchTalk, nothingToPlay

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Typical Talk is still starting up."
        case .noSuchTalk: "I could not find that talk."
        case .nothingToPlay: "There is nothing new to play there."
        }
    }
}

/// A person in a conversation, matched to Apple's messaging schema so Siri and
/// Apple Intelligence recognise who is being referred to.
struct TalkPersonEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Person"

    let id: String
    @Property(title: "Name") var name: String

    init(_ source: Person) {
        id = source.id.uuidString
        name = source.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = TalkPersonQuery()
}

struct TalkPersonQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TalkPersonEntity] {
        try await allPeople().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TalkPersonEntity] {
        try await allPeople()
    }

    @MainActor
    private func allPeople() async throws -> [TalkPersonEntity] {
        let store = try await IntentBridge.requireStore()
        var seen = Set<UUID>()
        return store.talks.flatMap(\.members).compactMap { person in
            guard !person.isYou, seen.insert(person.id).inserted else { return nil }
            return TalkPersonEntity(person)
        }
    }
}

/// How a thread can be described, for requests like "unread talks".
enum TalkAttribute: String, AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Talk Attribute"

    case unread
    case read

    static let caseDisplayRepresentations: [TalkAttribute: DisplayRepresentation] = [
        .unread: "Unread",
        .read: "Watched"
    ]
}

/// A single take. This is a plain AppEntity rather than Apple's message
/// schema: that schema is built around iMessage concepts (tapbacks, send
/// effects, link previews, place descriptors) that a video take has no notion
/// of, and stubbing them out would describe the app inaccurately.
struct TakeEntity: AppEntity {
    let id: String
    @Property(title: "Transcript") var body: String?
    @Property(title: "From") var author: TalkPersonEntity
    @Property(title: "Sent") var date: Date
    @Property(title: "Watched") var isRead: Bool
    @Property(title: "Reaction") var reaction: String?
    @Property(title: "Kind") var messageType: TakeKind
    @Property(title: "Talk") var conversation: TalkEntity

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Take"

    init(_ message: Message, in talk: Talk) {
        id = message.id.uuidString
        conversation = TalkEntity(talk)
        body = message.summaryLine
        author = TalkPersonEntity(message.author)
        date = message.sentAt
        isRead = message.watched
        reaction = message.reactions.first
        messageType = message.isVoiceOnly ? .audio : .video
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(author.name)",
            subtitle: "\(body ?? "Video take")"
        )
    }

    static let defaultQuery = TakeQuery()
}

/// Whether a take is video or voice only.
enum TakeKind: String, AppEnum {
    case video
    case audio

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Take Kind"
    static let caseDisplayRepresentations: [TakeKind: DisplayRepresentation] = [
        .video: "Video take",
        .audio: "Voice take"
    ]
}

struct TakeQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(matching string: String) async throws -> [TakeEntity] {
        let store = try await IntentBridge.requireStore()
        return store.search(string).map { TakeEntity($0.message, in: $0.talk) }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [TakeEntity] {
        let store = try await IntentBridge.requireStore()
        return store.talks.flatMap { talk in
            talk.messages
                .filter { identifiers.contains($0.id.uuidString) }
                .map { TakeEntity($0, in: talk) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [TakeEntity] {
        let store = try await IntentBridge.requireStore()
        return store.talks.compactMap { talk in
            talk.latest.map { TakeEntity($0, in: talk) }
        }
    }
}

/// A thread, conforming to Apple's conversation schema so "open my talk with
/// Sofia" resolves without the user learning our wording.
struct TalkEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Talk"

    let id: String
    @Property(title: "Name") var conversationName: String?
    @Property(title: "Display name") var displayName: String
    @Property(title: "People") var recipients: [TalkPersonEntity]
    @Property(title: "Last active") var dateLastActive: Date?
    @Property(title: "Watched") var isRead: Bool
    @Property(title: "Latest") var previewText: String
    @Property(title: "Attributes") var attributes: Set<TalkAttribute>

    init(_ talk: Talk) {
        id = talk.id.uuidString
        conversationName = talk.title
        displayName = talk.title
        recipients = talk.members.filter { !$0.isYou }.map(TalkPersonEntity.init)
        dateLastActive = talk.latest?.sentAt
        isRead = !talk.hasUnread
        previewText = talk.latest?.summaryLine ?? talk.statusLine ?? ""
        attributes = talk.hasUnread ? [.unread] : [.read]
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(conversationName ?? "Talk")",
            subtitle: "\(previewText ?? "")"
        )
    }

    static let defaultQuery = TalkQuery()
}

struct TalkQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TalkEntity] {
        let store = try await IntentBridge.requireStore()
        return store.talks
            .filter { identifiers.contains($0.id.uuidString) }
            .map(TalkEntity.init)
    }

    /// Matches the thread name or any member's name, so "the crew" and
    /// "Sofia" both land.
    @MainActor
    func entities(matching string: String) async throws -> [TalkEntity] {
        let store = try await IntentBridge.requireStore()
        return store.talks.filter { talk in
            talk.title.localizedCaseInsensitiveContains(string)
                || talk.members.contains { $0.name.localizedCaseInsensitiveContains(string) }
        }.map(TalkEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [TalkEntity] {
        let store = try await IntentBridge.requireStore()
        return store.talks.map(TalkEntity.init)
    }
}
