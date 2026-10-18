import SwiftUI

enum AppTab: Hashable {
    case talks, friends, archive, you
    /// The detached circle at the end of the tab bar. It is never a
    /// destination: selecting it performs an action and the selection stays
    /// where it was.
    case action
}

/// Wraps a thread id so the recorder can be presented with `sheet(item:)`,
/// which guarantees the destination exists before the sheet is built.
struct RecorderTarget: Identifiable {
    let id: Talk.ID
}

/// Three tabs on the system tab bar, Talks, You and Archive, plus a detached
/// circle at the trailing end, the way Music shows search.
///
/// This is Apple's real TabView, not a replica, so press-and-slide selection
/// and the swipe back behave exactly as the system does. The circle never
/// disappears, which the HIG asks of tab bar items; instead it changes job:
/// on Talks it starts a new talk, and inside a thread it records a reply.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: AppTab = Self.initialTab
    @State private var archiveQuery = ""
    @State private var router = IntentRouter.shared
    @State private var recorderTarget: RecorderTarget?
    @State private var thread = ThreadContext.shared
    @State private var showNewTalk = false

    private var inThread: Bool { thread.openTalk != nil }

    /// Selecting the circle runs its action instead of switching tabs.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selection },
            set: { next in
                guard next == .action else {
                    selection = next
                    return
                }
                if inThread {
                    ThreadContext.shared.requestReply()
                } else {
                    showNewTalk = true
                }
            }
        )
    }

    /// Red symbols baked as original images, because tab labels ignore
    /// foregroundStyle and would otherwise repaint them with the app tint.
    private static func redSymbol(_ name: String) -> UIImage {
        let tint = UIColor(red: 1.0, green: 0.325, blue: 0.435, alpha: 1.0)
        let config = UIImage.SymbolConfiguration(weight: .semibold)
        guard let symbol = UIImage(systemName: name, withConfiguration: config) else { return UIImage() }
        return symbol.withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    /// Lets a debug build launch straight into a tab, for screenshot checks.
    private static var initialTab: AppTab {
        #if DEBUG
        switch ProcessInfo.processInfo.arguments.last(where: { $0.hasPrefix("tab:") }) {
        case "tab:archive": return .archive
        case "tab:you": return .you
        case "tab:friends": return .friends
        default: return .talks
        }
        #else
        return .talks
        #endif
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Talks", systemImage: "bubble.left.and.bubble.right", value: AppTab.talks) {
                TalksView()
            }

            Tab("Friends", systemImage: "person.2", value: AppTab.friends) {
                NavigationStack {
                    FindFriendsView()
                        .navigationTitle("Friends")
                        .background(Palette.canvas)
                }
            }

            Tab("You", systemImage: "person.crop.circle", value: AppTab.you) {
                YouView()
            }

            Tab("Archive", systemImage: "magnifyingglass", value: AppTab.archive) {
                ArchiveView(query: $archiveQuery)
            }

            // iOS 27 draws a prominent tab as its own circle beside the bar.
            // On iOS 26 that role does not exist, so the same action sits in
            // the bar as an ordinary item: it still changes job and still
            // never disappears.
            if #available(iOS 27.0, *) {
                Tab(
                    inThread ? "Reply" : "New Talk",
                    systemImage: inThread ? "video.fill" : "plus",
                    value: AppTab.action,
                    role: .prominent
                ) {
                    Color.clear
                }
            } else {
                Tab(
                    inThread ? "Reply" : "New Talk",
                    systemImage: inThread ? "video.fill" : "plus",
                    value: AppTab.action
                ) {
                    Color.clear
                }
            }
        }
        .tint(Palette.record)
        .fullScreenCover(item: $recorderTarget) { target in
            RecorderSheet(destination: target.id)
        }
        .sheet(isPresented: $showNewTalk) {
            NewTalkView { id in recorderTarget = RecorderTarget(id: id) }
                .presentationBackground(Palette.canvas)
        }
        .background(Palette.canvas)
        .task {
            // Ask for push in its own task: the permission prompt waits for an
            // answer, and syncing must not.
            if store.notificationsEnabled { await PushRegistrar.shared.enable() }
        }
        .task {
            // Keep the phone current: now, and every twenty seconds while the
            // app is open. Pushes cover the rest.
            while !Task.isCancelled {
                await store.sync()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        #if DEBUG
        .task {
            // Debug only: launch straight into the newest thread for
            // screenshot checks, and send a given video as a take, because a
            // simulator has no camera to record one.
            let environment = ProcessInfo.processInfo.environment
            try? await Task.sleep(for: .seconds(2))
            if let path = environment["TT_DEBUG_SEND"], let first = store.talks.first {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("debug-\(UUID().uuidString).mov")
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
                store.send(take: copy, duration: 10, transcript: [], voiceOnly: false, to: first.id)
            }
            // Debug only: run the safety and group actions without tapping.
            let me = store.me
            let others = store.talks.flatMap(\.members).filter { $0.id != me.id }
            switch environment["TT_DEBUG_ACTION"] {
            case "group":
                let result = await store.createGroup(with: Array(Set(others)), title: "Test Crew")
                print("TT_DEBUG group:", result.0 as Any, result.1 as Any)
            case "report":
                if let talk = store.talks.first(where: { $0.messages.contains { !$0.author.isYou } }),
                   let message = talk.messages.first(where: { !$0.author.isYou }) {
                    print("TT_DEBUG report:", await store.report(message, in: talk.id, reason: .spam, details: nil) as Any)
                }
            case "block":
                if let person = others.first { print("TT_DEBUG block:", await store.block(person) as Any) }
            case "newtalk":
                showNewTalk = true
            default: break
            }
            if ProcessInfo.processInfo.arguments.contains("thread:first"), let first = store.talks.first {
                TalksNavigation.shared.open = first.id
            }
        }
        #endif
        // Siri and Shortcuts drive the app through the router.
        .onChange(of: router.showArchive) { _, show in
            guard show else { return }
            archiveQuery = router.searchQuery ?? ""
            selection = .archive
            router.showArchive = false
        }
        .onChange(of: router.openRecorderFor) { _, target in
            guard let target else { return }
            recorderTarget = RecorderTarget(id: target)
            router.openRecorderFor = nil
        }
        .onChange(of: router.openTalkID) { _, id in
            guard let id else { return }
            selection = .talks
            TalksNavigation.shared.open = id
            router.openTalkID = nil
        }
    }
}
