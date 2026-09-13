import SwiftUI

/// The app's bottom bar: the three tabs, with a draggable highlight like the
/// system tab bar.
///
/// While a thread is open the tabs give up a slot at the trailing end. The
/// reply button in that slot is drawn by the thread itself, not by this bar,
/// so it slides away with the thread as you swipe back rather than vanishing
/// only after the swipe has finished.
struct AppTabBar: View {
    @Binding var selection: AppTab
    var reservesReply: Bool

    static let height: CGFloat = 62
    static let spacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 16
    static let bottomPadding: CGFloat = 4

    private let tabs: [AppTab] = [.talks, .you, .archive]

    var body: some View {
        HStack(spacing: Self.spacing) {
            GlassSegmentPicker(items: tabs, selection: $selection, inset: 5) { tab, isSelected in
                VStack(spacing: 3) {
                    Image(systemName: symbol(for: tab))
                        .font(.system(size: 20, weight: .medium))
                    Text(title(for: tab))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.7))
                .accessibilityLabel(title(for: tab))
            }
            .frame(height: Self.height)
            .glassEffect(.regular.interactive(), in: .capsule)

            if reservesReply {
                // Empty slot; the open thread draws the button here.
                Color.clear
                    .frame(width: Self.height, height: Self.height)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .animation(.snappy(duration: 0.32), value: reservesReply)
    }

    private func title(for tab: AppTab) -> String {
        switch tab {
        case .talks: "Talks"
        case .you: "You"
        case .archive: "Archive"
        }
    }

    private func symbol(for tab: AppTab) -> String {
        switch tab {
        case .talks: "bubble.left.and.bubble.right"
        case .you: "person.crop.circle"
        case .archive: "magnifyingglass"
        }
    }
}

/// The red reply circle, sized to sit in the tab bar's row.
struct ReplyBarButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "video.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: AppTabBar.height, height: AppTabBar.height)
                .background(Palette.record, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record a reply")
    }
}
