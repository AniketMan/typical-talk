import CoreSpotlight
import UniformTypeIdentifiers

/// Puts your conversations and what was said in them into Spotlight, so
/// searching from the home screen finds a take by its words.
///
/// The index lives on the phone, like the transcripts it is built from.
enum SpotlightIndex {
    private static let domain = "com.typicaltalk.takes"

    /// Rebuilds the whole index. Small enough to do in one go, and it means a
    /// deleted take or a left conversation simply stops being there.
    static func update(_ talks: [Talk]) {
        var items: [CSSearchableItem] = []
        for talk in talks {
            let people = talk.members.filter { !$0.isYou }.map(\.name)
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = talk.title
            attributes.contentDescription = talk.statusLine ?? people.joined(separator: ", ")
            attributes.keywords = people + ["take", "takes"]
            attributes.contentModificationDate = talk.lastActivity
            items.append(CSSearchableItem(uniqueIdentifier: "talk:\(talk.id.uuidString)", domainIdentifier: domain, attributeSet: attributes))

            for message in talk.messages where !message.transcript.isEmpty {
                let take = CSSearchableItemAttributeSet(contentType: .content)
                take.title = "\(message.author.isYou ? "You" : message.author.name) in \(talk.title)"
                take.contentDescription = message.transcript.map(\.text).joined(separator: " ")
                take.contentCreationDate = message.sentAt
                take.keywords = [message.author.name, talk.title]
                items.append(CSSearchableItem(
                    uniqueIdentifier: "take:\(talk.id.uuidString):\(message.id.uuidString)",
                    domainIdentifier: domain,
                    attributeSet: take
                ))
            }
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }

    static func clear() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }

    /// The conversation a Spotlight result points at.
    static func talkID(from identifier: String) -> Talk.ID? {
        let parts = identifier.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        return UUID(uuidString: String(parts[1]))
    }
}
