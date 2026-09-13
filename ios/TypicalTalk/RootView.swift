import SwiftUI

enum AppTab: Hashable {
    case talks, archive, you
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

            Tab("You", systemImage: "person.crop.circle", value: AppTab.you) {
                YouView()
            }

            Tab("Archive", systemImage: "magnifyingglass", value: AppTab.archive) {
                ArchiveView(query: $archiveQuery)
            }

            // The search role is the system's only detached trailing circle.
            Tab(value: AppTab.action, role: .search) {
                Color.clear
            } label: {
                Label {
                    Text(inThread ? "Reply" : "New Talk")
                } icon: {
                    Image(uiImage: Self.redSymbol(inThread ? "video.fill" : "plus"))
                }
            }
        }
        .tint(.white)
        .fullScreenCover(item: $recorderTarget) { target in
            RecorderSheet(destination: target.id)
        }
        .sheet(isPresented: $showNewTalk) {
            NewTalkView { id in recorderTarget = RecorderTarget(id: id) }
                .presentationBackground(Palette.canvas)
        }
        .background(Palette.canvas)
        .task {
            await store.loadSeed()
            #if DEBUG
            // Debug only: launch straight into the newest thread for
            // screenshot checks.
            if ProcessInfo.processInfo.arguments.contains("thread:first"),
               let first = store.talks.first {
                TalksNavigation.shared.open = first.id
            }
            #endif
        }
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
