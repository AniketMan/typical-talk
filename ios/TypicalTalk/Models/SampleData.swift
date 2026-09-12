import Foundation

/// Seed content so every screen has something honest to show before the user
/// records anything. Copy matches the Stitch screens the demo was built from.
enum SampleData {
    static let you = Person(name: "You", isYou: true)
    static let maya = Person(name: "Maya Lin")
    static let marcus = Person(name: "Marcus Vance")
    static let elena = Person(name: "Elena Rostova")
    static let sarah = Person(name: "Sarah Lin")

    static func talks(now: Date = .now) -> [Talk] {
        let mayaTake = Message(
            author: maya,
            sentAt: now.addingTimeInterval(-4 * 60),
            duration: 48,
            transcript: [
                TranscriptSegment(start: 0, text: "Hey, quick one about Saturday."),
                TranscriptSegment(start: 8, text: "I just booked the rooftop terrace for 7:30."),
                TranscriptSegment(start: 19, text: "Everyone bring coats just in case it gets breezy."),
                TranscriptSegment(start: 31, text: "I will send the address once they confirm the deposit.")
            ],
            chapters: [
                Chapter(start: 0, title: "Opening"),
                Chapter(start: 12, title: "Venue"),
                Chapter(start: 27, title: "Saturday timing")
            ]
        )

        let marcusReply = Message(
            author: marcus,
            sentAt: now.addingTimeInterval(-14 * 60),
            duration: 34,
            transcript: [
                TranscriptSegment(start: 0, text: "Count me in for the terrace."),
                TranscriptSegment(start: 11, text: "Checking the cocktails menu now, I will report back."),
                TranscriptSegment(start: 24, text: "We should align the design sprint with the roadmap dates too.")
            ],
            chapters: [Chapter(start: 0, title: "Reply"), Chapter(start: 20, title: "Roadmap")]
        )

        let elenaWatched = Message(
            author: elena,
            sentAt: now.addingTimeInterval(-60 * 60),
            duration: 72,
            watched: true,
            reactions: ["❤️"],
            transcript: [
                TranscriptSegment(start: 0, text: "Tasting the matcha berry cake right now."),
                TranscriptSegment(start: 14, text: "It is incredible, we should order the big one."),
                TranscriptSegment(start: 38, text: "The outcome of the previous design sprint clarifies the roadmap.")
            ],
            chapters: [Chapter(start: 0, title: "Bakery"), Chapter(start: 34, title: "Work")]
        )

        let weekendCrew = Talk(
            title: "Weekend Crew",
            members: [you, maya, marcus, elena],
            messages: [mayaTake, marcusReply, elenaWatched]
        )

        let mayaSolo = Talk(
            title: "Maya Lin",
            members: [you, maya],
            messages: [
                Message(
                    author: maya,
                    sentAt: now.addingTimeInterval(-4 * 60),
                    duration: 102,
                    transcript: [
                        TranscriptSegment(start: 0, text: "I just booked the rooftop for 7:30."),
                        TranscriptSegment(start: 22, text: "Bring a coat, it might get breezy.")
                    ],
                    chapters: [Chapter(start: 0, title: "Booking")]
                )
            ]
        )

        let marcusSolo = Talk(
            title: "Marcus Vance",
            members: [you, marcus],
            messages: [
                Message(
                    author: marcus,
                    sentAt: now.addingTimeInterval(-26 * 3600),
                    duration: 54,
                    watched: true,
                    transcript: [
                        TranscriptSegment(start: 0, text: "Shared a quick update from the trail."),
                        TranscriptSegment(start: 20, text: "The view is worth the climb, honestly.")
                    ],
                    chapters: [Chapter(start: 0, title: "Trail")]
                )
            ]
        )

        return [mayaSolo, weekendCrew, marcusSolo]
    }

    static func bookmarks(for talks: [Talk], now: Date = .now) -> [Bookmark] {
        guard let crew = talks.first(where: { $0.isGroup }) else { return [] }
        let byAuthor: (Person) -> Message? = { person in
            crew.messages.first { $0.author == person }
        }
        var result: [Bookmark] = []
        if let m = byAuthor(elena) {
            result.append(Bookmark(title: "Birthday toast", talkID: crew.id, messageID: m.id, author: elena, at: 38, savedAt: now.addingTimeInterval(-2 * 86_400)))
        }
        if let m = byAuthor(marcus) {
            result.append(Bookmark(title: "Rooftop plans", talkID: crew.id, messageID: m.id, author: marcus, at: 11, savedAt: now.addingTimeInterval(-4 * 86_400)))
        }
        if let m = byAuthor(maya) {
            result.append(Bookmark(title: "Venue confirmed", talkID: crew.id, messageID: m.id, author: maya, at: 8, savedAt: now.addingTimeInterval(-7 * 86_400)))
        }
        return result
    }

    static let highlights: [Highlight] = [
        Highlight(
            talkTitle: "Weekend Crew",
            subtitle: "Key decisions across 3 video updates",
            points: [
                "Rooftop terrace booked for Saturday at 7:30.",
                "Everyone brings a coat, the terrace gets breezy.",
                "Address goes out once the deposit clears."
            ],
            duration: 220
        ),
        Highlight(
            talkTitle: "Maya Lin",
            subtitle: "Synthesized from the last two takes",
            points: [
                "Booking is confirmed and paid.",
                "Follow up on the cocktails menu before Friday."
            ],
            duration: 96
        )
    ]

    static func notifications(now: Date = .now) -> [AppNotification] {
        [
            AppNotification(kind: .reaction, text: "Maya reacted to your take", detail: "Weekend Crew", at: now.addingTimeInterval(-4 * 60)),
            AppNotification(kind: .mention, text: "Elena mentioned you", detail: "Weekend Crew", at: now.addingTimeInterval(-22 * 60)),
            AppNotification(kind: .watchReceipt, text: "Marcus watched your take", detail: "Seen yesterday at 18:40", at: now.addingTimeInterval(-26 * 3600))
        ]
    }

    static let suggestedContacts = ["Jordan Lee", "Priya Shah", "Devin Brooks"]
}
