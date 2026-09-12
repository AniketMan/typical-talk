import SwiftUI

enum AppTab: Hashable {
    case talks, archive, you
}

/// Wraps a thread id so the recorder can be presented with `sheet(item:)`,
/// which guarantees the destination exists before the sheet is built.
struct RecorderTarget: Identifiable {
    let id: Talk.ID
}

/// The four locked tab items: Talks, Record, Archive, You. Archive takes the
/// search role so the system floats it as its own reachable glass pill, and
/// Record is a pass-through that expands into the recorder rather than being a
/// destination of its own.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: AppTab = Self.initialTab

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
    @State private var archiveQuery = ""
    @State private var router = IntentRouter.shared
    @State private var path: [Talk.ID] = []
    @State private var recorderTarget: RecorderTarget?
    @Namespace private var recorderMorph

    var body: some View {
        TabView(selection: $selection) {
            Tab("Talks", systemImage: "bubble.left.and.bubble.right", value: AppTab.talks) {
                TalksView { id in recorderTarget = RecorderTarget(id: id) }
            }

            Tab("You", systemImage: "person.crop.circle", value: AppTab.you) {
                YouView()
            }

            Tab("Archive", systemImage: "magnifyingglass", value: AppTab.archive, role: .search) {
                ArchiveView(query: $archiveQuery)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(.white)
        .fullScreenCover(item: $recorderTarget) { target in
            RecorderSheet(destination: target.id)
        }
        .background(Palette.canvas)
        .task { await store.loadSeed() }
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
