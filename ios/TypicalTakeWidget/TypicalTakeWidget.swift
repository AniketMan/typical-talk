import Security
import SwiftUI
import WidgetKit

/// Who is waiting on you: the conversations with takes you have not watched.
///
/// The app writes a small summary into the shared App Group whenever its
/// state changes; the widget only reads it. Nothing here touches the network.

struct WaitingSummary {
    struct Entry: Identifiable {
        var id: UUID
        var title: String
        var initials: String
        var unread: Int
        var latest: Date
    }
    var entries: [Entry]
    var totalUnread: Int
    var signedIn = true

    static let empty = WaitingSummary(entries: [], totalUnread: 0)
}

/// Reads the session the app shares, then asks the server what is unwatched.
enum WaitingSource {
    private struct Credentials: Codable { var token: String; var userID: String; var apiBase: String }
    private struct Response: Decodable {
        struct Member: Decodable { let id: String; let name: String }
        struct Take: Decodable {
            let authorID: String
            let sentAt: Double
            let expired: Bool
            let deleted: Bool?
            let watchedBy: [String]
        }
        struct TalkRow: Decodable {
            let id: String
            let title: String?
            let isGroup: Bool
            let members: [Member]
            let takes: [Take]
        }
        let talks: [TalkRow]
    }

    private static func credentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.typicaltalk.widget",
            kSecAttrAccessGroup as String: "5BF427L96N.com.typicaltalk.TypicalTalk.shared",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func load() async -> WaitingSummary {
        guard let credentials = credentials(), var url = URL(string: credentials.apiBase) else {
            var signedOut = WaitingSummary.empty
            signedOut.signedIn = false
            return signedOut
        }
        url.append(path: "/v1/talks")
        url.append(queryItems: [URLQueryItem(name: "since", value: "0")])
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return .empty }

        let me = credentials.userID.lowercased()
        var entries: [WaitingSummary.Entry] = []
        for talk in decoded.talks {
            let waiting = talk.takes.filter {
                $0.authorID.lowercased() != me && !$0.expired && $0.deleted != true
                    && !$0.watchedBy.map { $0.lowercased() }.contains(me)
            }
            guard !waiting.isEmpty, let id = UUID(uuidString: talk.id) else { continue }
            let others = talk.members.filter { $0.id.lowercased() != me }.map(\.name)
            let title = talk.isGroup ? (talk.title ?? others.prefix(2).joined(separator: " & ")) : (others.first ?? "Someone")
            let initials = title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
            let latest = Date(timeIntervalSince1970: (waiting.map(\.sentAt).max() ?? 0) / 1000)
            entries.append(.init(id: id, title: title, initials: initials, unread: waiting.count, latest: latest))
        }
        entries.sort { $0.latest > $1.latest }
        return WaitingSummary(entries: entries, totalUnread: entries.reduce(0) { $0 + $1.unread })
    }
}

struct WaitingEntry: TimelineEntry {
    let date: Date
    let summary: WaitingSummary
}

struct WaitingProvider: TimelineProvider {
    func placeholder(in context: Context) -> WaitingEntry {
        WaitingEntry(date: .now, summary: WaitingSummary(
            entries: [
                .init(id: UUID(), title: "Sofia", initials: "S", unread: 2, latest: .now),
                .init(id: UUID(), title: "Weekend Crew", initials: "WC", unread: 1, latest: .now)
            ],
            totalUnread: 3
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (WaitingEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        nonisolated(unsafe) let finish = completion
        Task { finish(WaitingEntry(date: .now, summary: await WaitingSource.load())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WaitingEntry>) -> Void) {
        // The app reloads the widget when the unread count changes; this
        // refresh catches takes that arrive while the app is closed.
        nonisolated(unsafe) let finish = completion
        Task {
            let entry = WaitingEntry(date: .now, summary: await WaitingSource.load())
            finish(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }
}

private let record = Color(red: 1.0, green: 0.325, blue: 0.435)

struct WaitingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WaitingEntry

    var body: some View {
        Group {
            if entry.summary.entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(record)
                    Spacer()
                    Text(entry.summary.signedIn ? "All caught up" : "Typical Take").font(.headline)
                    Text(entry.summary.signedIn ? "No takes waiting" : "Open the app to sign in")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if family == .systemSmall {
                small
            } else {
                list
            }
        }
        .containerBackground(for: .widget) { Color(red: 0.03, green: 0.035, blue: 0.047) }
    }

    private var small: some View {
        let first = entry.summary.entries[0]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "video.fill").foregroundStyle(record)
                Spacer()
                Text("\(entry.summary.totalUnread)")
                    .font(.title2.weight(.bold).monospacedDigit())
            }
            Spacer()
            Text(first.title).font(.headline).lineLimit(1)
            Text(entry.summary.entries.count > 1 ? "and \(entry.summary.entries.count - 1) more waiting" : "is waiting on you")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: "typicaltalk://talk/\(first.id.uuidString)"))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Waiting on you").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(entry.summary.totalUnread) new").font(.caption.weight(.semibold)).foregroundStyle(record)
            }
            ForEach(entry.summary.entries.prefix(family == .systemLarge ? 6 : 3)) { row in
                Link(destination: URL(string: "typicaltalk://talk/\(row.id.uuidString)")!) {
                    HStack(spacing: 10) {
                        Text(row.initials)
                            .font(.caption.weight(.bold))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.12), in: .circle)
                        Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text("\(row.unread)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(record, in: .capsule)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct WaitingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Waiting", provider: WaitingProvider()) { entry in
            WaitingView(entry: entry)
        }
        .configurationDisplayName("Waiting on you")
        .description("Who has sent you takes you have not watched yet.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct TypicalTakeWidgets: WidgetBundle {
    var body: some Widget {
        WaitingWidget()
    }
}
