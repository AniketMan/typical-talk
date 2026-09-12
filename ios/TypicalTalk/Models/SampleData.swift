import AVFoundation
import Foundation

/// The seeded conversations, built from the video files bundled in `Seed/`.
/// Transcripts are deliberately empty here: the app transcribes these on
/// device at first launch, which is the same path a take you record takes.
enum SampleData {
    static let you = Person(name: "You", isYou: true)
    static let bob = Person(name: "Bob")
    static let freya = Person(name: "Freya")
    static let lindsey = Person(name: "Lindsey")
    static let marcus = Person(name: "Marcus")
    static let jake = Person(name: "Jake")
    static let priya = Person(name: "Priya")
    static let sofia = Person(name: "Sofia")

    /// A bundled seed clip. Missing files are skipped rather than faked.
    private static func clip(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mp4")
    }

    private static func message(
        _ file: String,
        from author: Person,
        minutesAgo: Double,
        watched: Bool = false,
        reactions: [String] = []
    ) async -> Message? {
        guard let url = clip(file) else { return nil }
        let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return Message(
            author: author,
            sentAt: Date.now.addingTimeInterval(-minutesAgo * 60),
            duration: duration > 0 ? duration : 10,
            watched: watched,
            reactions: reactions,
            localVideoURL: url
        )
    }

    static func talks() async -> [Talk] {
        var result: [Talk] = []

        // Group thread: Jake, Marcus and Priya.
        let group = [
            await message("group-priya", from: priya, minutesAgo: 6),
            await message("group-marcus", from: marcus, minutesAgo: 24),
            await message("group-jake", from: jake, minutesAgo: 51, watched: true, reactions: ["😂"])
        ].compactMap { $0 }
        if !group.isEmpty {
            result.append(Talk(title: "Weekend Crew", members: [you, jake, marcus, priya], messages: group))
        }

        // One to one with Sofia, the only thread you have replied in.
        let sofiaThread = [
            await message("sofia-2", from: sofia, minutesAgo: 14),
            await message("sofia-me", from: you, minutesAgo: 40, watched: true),
            await message("sofia-1", from: sofia, minutesAgo: 95, watched: true, reactions: ["❤️"])
        ].compactMap { $0 }
        if !sofiaThread.isEmpty {
            result.append(Talk(title: "Sofia", members: [you, sofia], messages: sofiaThread))
        }

        // Threads where someone sent a take and you have not replied yet.
        let unanswered: [(Person, [String], [Double])] = [
            (bob, ["bob-2", "bob-1"], [33, 210]),
            (freya, ["freya-1"], [120]),
            (lindsey, ["lindsey-1"], [320]),
            (marcus, ["marcus-1"], [1_500])
        ]
        for (person, files, ages) in unanswered {
            var messages: [Message] = []
            for (file, age) in zip(files, ages) {
                if let m = await message(file, from: person, minutesAgo: age) { messages.append(m) }
            }
            guard !messages.isEmpty else { continue }
            result.append(Talk(title: person.name, members: [you, person], messages: messages))
        }

        return result.sorted { ($0.latest?.sentAt ?? .distantPast) > ($1.latest?.sentAt ?? .distantPast) }
    }

    /// Nothing is bookmarked until the user bookmarks something.
    static func bookmarks(for talks: [Talk]) -> [Bookmark] { [] }

    static let suggestedContacts = ["Jordan Lee", "Priya Shah", "Devin Brooks"]
}
