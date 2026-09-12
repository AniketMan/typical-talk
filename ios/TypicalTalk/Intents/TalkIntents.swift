import AppIntents
import GeoToolbox
import LinkPresentation
import SwiftUI

/// Where the app should go when an intent hands control back to the UI.
@MainActor
@Observable
final class IntentRouter {
    static let shared = IntentRouter()
    var openTalkID: Talk.ID?
    var openRecorderFor: Talk.ID?
    var searchQuery: String?
    var showArchive = false
}

/// "Send a take to Sofia." A plain intent rather than Apple's send-message
/// schema: that schema demands attachments, links, place descriptors, send
/// effects and scheduled delivery, none of which this app has. Siri still
/// reaches it through the shortcut phrases below.
struct SendTakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Send a Take"
    static let description = IntentDescription(
        "Opens the recorder aimed at a talk, ready to record and send.",
        categoryName: "Recording"
    )
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Talk") var talk: TalkEntity?
    @Parameter(title: "To") var recipients: [TalkPersonEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Send a take to \(\.$talk)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = try await IntentBridge.requireStore()

        let target: Talk?
        if let talk, let id = UUID(uuidString: talk.id) {
            target = store.talk(id: id)
        } else if let name = recipients?.first?.name {
            target = store.talks.first {
                $0.members.contains { $0.name.localizedCaseInsensitiveContains(name) }
            }
        } else {
            target = store.talks.first
        }

        guard let target else { throw TalkIntentError.noSuchTalk }
        // Recording is a physical act, so this opens the recorder pointed at
        // the right thread rather than pretending to have sent anything.
        IntentRouter.shared.openRecorderFor = target.id
        return .result()
    }
}

/// "Mark the Weekend Crew as watched."
struct MarkTakesWatchedIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Takes Watched"
    static let description = IntentDescription(
        "Marks every take in a talk as watched.",
        categoryName: "Playback"
    )

    @Parameter(title: "Talk") var talk: TalkEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$talk) as watched")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentBridge.requireStore()
        guard let id = UUID(uuidString: talk.id), let found = store.talk(id: id) else {
            throw TalkIntentError.noSuchTalk
        }
        store.markAllWatched(in: id)
        return .result(dialog: IntentDialog("Marked \(found.title) as watched."))
    }
}

/// "Play my new takes." Opens the thread with the oldest unwatched take and
/// starts it, which is the thing you actually want from a voice command.
struct PlayNewTakesIntent: AppIntent {
    static let title: LocalizedStringResource = "Play New Takes"
    static let description = IntentDescription(
        "Opens the talk with unwatched takes and starts playing.",
        categoryName: "Playback"
    )
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Talk") var talk: TalkEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Play new takes in \(\.$talk)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentBridge.requireStore()

        let target: Talk?
        if let talk, let id = UUID(uuidString: talk.id) {
            target = store.talk(id: id)
        } else {
            target = store.talks.first(where: \.hasUnread)
        }
        guard let target, target.hasUnread else { throw TalkIntentError.nothingToPlay }

        IntentRouter.shared.openTalkID = target.id
        let minutes = max(1, Int((target.unreadDuration / 60).rounded()))
        return .result(dialog: IntentDialog(
            "Playing \(target.unreadCount) new takes from \(target.title), about \(minutes) minutes."
        ))
    }
}

/// "Search my talks for the car." Runs against on-device transcripts.
struct SearchTalksIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Talks"
    static let description = IntentDescription(
        "Searches everything said in your talks, using transcripts stored on this device.",
        categoryName: "Archive"
    )
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Words", requestValueDialog: "What should I look for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search talks for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentBridge.requireStore()
        let matches = store.search(query)
        IntentRouter.shared.searchQuery = query
        IntentRouter.shared.showArchive = true

        guard let best = matches.first else {
            return .result(dialog: IntentDialog("Nothing in your talks mentions \(query)."))
        }
        return .result(dialog: IntentDialog(
            "\(matches.count) matches. \(best.message.author.name) said: \(best.segment.text)"
        ))
    }
}

/// "Catch me up." Reads back what is waiting, built from on-device transcripts.
struct CatchUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Catch Me Up"
    static let description = IntentDescription(
        "Summarizes the takes you have not watched yet, from transcripts on this device.",
        categoryName: "Playback"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try await IntentBridge.requireStore()
        let waiting = store.talks.filter(\.hasUnread)

        guard !waiting.isEmpty else {
            return .result(dialog: IntentDialog("You are all caught up."))
        }

        let total = waiting.reduce(0) { $0 + $1.unreadCount }
        let minutes = max(1, Int((waiting.reduce(0) { $0 + $1.unreadDuration } / 60).rounded()))
        var lines = ["\(total) new takes across \(waiting.count) talks, about \(minutes) minutes."]
        for talk in waiting.prefix(3) {
            if let said = talk.messages.first(where: { !$0.watched })?.summaryLine {
                lines.append("\(talk.title): \(said)")
            } else {
                lines.append("\(talk.title): \(talk.unreadCount) waiting.")
            }
        }
        return .result(dialog: IntentDialog(stringLiteral: lines.joined(separator: " ")))
    }
}

/// "Record a take."
struct RecordTakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Take"
    static let description = IntentDescription("Opens the recorder.", categoryName: "Recording")
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = try await IntentBridge.requireStore()
        IntentRouter.shared.openRecorderFor = store.talks.first?.id
        return .result()
    }
}

/// Phrases Siri accepts without the user opening the app first.
struct TypicalTalkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CatchUpIntent(),
            phrases: [
                "Catch me up on \(.applicationName)",
                "What is new in \(.applicationName)"
            ],
            shortTitle: "Catch Me Up",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: PlayNewTakesIntent(),
            phrases: [
                "Play my new takes in \(.applicationName)",
                "Play new \(.applicationName)"
            ],
            shortTitle: "Play New Takes",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: RecordTakeIntent(),
            phrases: [
                "Record a take in \(.applicationName)",
                "New take in \(.applicationName)"
            ],
            shortTitle: "Record a Take",
            systemImageName: "video.circle"
        )
        AppShortcut(
            intent: SearchTalksIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Find it in \(.applicationName)"
            ],
            shortTitle: "Search Talks",
            systemImageName: "magnifyingglass"
        )
    }
}
