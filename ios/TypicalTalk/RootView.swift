import SwiftUI

enum AppTab: Hashable {
    case talks, archive, you
}

/// Wraps a thread id so the recorder can be presented with `sheet(item:)`,
/// which guarantees the destination exists before the sheet is built.
struct RecorderTarget: Identifiable {
    let id: Talk.ID
}

/// Three tabs: Talks, You, Archive. The system tab bar is hidden and replaced
/// by AppTabBar, so the reply action can sit in the same row as the tabs
/// while a thread is open.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: AppTab = Self.initialTab
    @State private var archiveQuery = ""
    @State private var router = IntentRouter.shared
    @State private var thread = ThreadContext.shared
    @State private var recorderTarget: RecorderTarget?

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
        TabView(selection: $selection) {
            Tab("Talks", systemImage: "bubble.left.and.bubble.right", value: AppTab.talks) {
                TalksView { id in recorderTarget = RecorderTarget(id: id) }
                    .modifier(tabBar)
            }

            Tab("You", systemImage: "person.crop.circle", value: AppTab.you) {
                YouView()
                    .modifier(tabBar)
            }

            Tab("Archive", systemImage: "magnifyingglass", value: AppTab.archive) {
                ArchiveView(query: $archiveQuery)
                    .modifier(tabBar)
            }
        }
        .tint(.white)
        .fullScreenCover(item: $recorderTarget) { target in
            RecorderSheet(destination: target.id)
        }
        .background(Palette.canvas)
        .task {
            await store.loadSeed()
            #if DEBUG
            // Debug only: launch straight into the newest thread so the bar can
            // be checked with the reply action showing.
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

    /// Applied to each tab's root, outside its NavigationStack, so pushed
    /// screens such as a thread inherit the bottom inset and stack their own
    /// bars above this one instead of underneath it.
    private var tabBar: AppTabBarModifier {
        AppTabBarModifier(selection: $selection, reservesReply: thread.openTalk != nil)
    }
}

struct AppTabBarModifier: ViewModifier {
    @Binding var selection: AppTab
    var reservesReply: Bool

    func body(content: Content) -> some View {
        content
            .toolbarVisibility(.hidden, for: .tabBar)
            .safeAreaBar(edge: .bottom) {
                AppTabBar(selection: $selection, reservesReply: reservesReply)
                    .padding(.bottom, AppTabBar.bottomPadding)
            }
    }
}
