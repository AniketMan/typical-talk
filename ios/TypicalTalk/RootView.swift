import SwiftUI

enum AppTab: Hashable {
    case talks, record, archive, you
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
    @State private var showRecorder = false
    @State private var archiveQuery = ""
    @Namespace private var recorderMorph

    /// Tapping Record never changes the selected tab. It expands the tinted
    /// action into the recorder, which is the point of the morph.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selection },
            set: { next in
                if next == .record {
                    showRecorder = true
                } else {
                    selection = next
                }
            }
        )
    }

    /// An SF Symbol rendered once in the record tint and marked as original,
    /// so the tab bar does not repaint it with the app tint.
    private static let tintedRecordSymbol: UIImage = {
        let tint = UIColor(red: 1.0, green: 0.325, blue: 0.435, alpha: 1.0)
        guard let symbol = UIImage(systemName: "video.fill") else { return UIImage() }
        return symbol.withTintColor(tint, renderingMode: .alwaysOriginal)
    }()

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Talks", systemImage: "bubble.left.and.bubble.right", value: AppTab.talks) {
                TalksView()
            }

            // The only tinted element in the app. The symbol is baked with
            // the tint because tab labels ignore foregroundStyle.
            Tab(value: AppTab.record) {
                Color.clear
            } label: {
                Label {
                    Text("Record")
                } icon: {
                    Image(uiImage: Self.tintedRecordSymbol)
                }
            }

            Tab("You", systemImage: "person.crop.circle", value: AppTab.you) {
                YouView()
            }

            Tab("Archive", systemImage: "magnifyingglass", value: AppTab.archive, role: .search) {
                ArchiveView(query: $archiveQuery)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Palette.record)
        // Anchors the zoom so the recorder grows out of the Record item
        // instead of popping in from nowhere.
        .overlay(alignment: .bottom) {
            Color.clear
                .frame(width: 64, height: 46)
                .allowsHitTesting(false)
                .padding(.bottom, 6)
                .matchedTransitionSource(id: "recorder", in: recorderMorph)
        }
        .fullScreenCover(isPresented: $showRecorder) {
            RecorderSheet()
                .navigationTransition(.zoom(sourceID: "recorder", in: recorderMorph))
        }
        .background(Palette.canvas)
    }
}
