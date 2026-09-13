import SwiftUI

/// The app's bottom bar: the three tabs and, while a thread is open, the reply
/// action, laid out in one row so they always share a baseline and a height.
///
/// This replaces the system tab bar. The reply button used to be a separate
/// overlay positioned by guesswork next to the system bar, which the system
/// bar knew nothing about, so the two never lined up. Here they are siblings
/// in the same stack, and the tabs give up width when the reply appears.
struct AppTabBar: View {
    @Binding var selection: AppTab
    var showsReply: Bool
    var reply: () -> Void

    static let height: CGFloat = 62

    private let items: [(tab: AppTab, title: String, symbol: String)] = [
        (.talks, "Talks", "bubble.left.and.bubble.right"),
        (.you, "You", "person.crop.circle"),
        (.archive, "Archive", "magnifyingglass")
    ]

    var body: some View {
        // Spacing 0: the pill and the reply button share a sampling region
        // but must never blend into each other.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 10) {
                tabs

                if showsReply {
                    Button(action: reply) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: Self.height, height: Self.height)
                            .background(Palette.record, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                    .accessibilityLabel("Record a reply")
                }
            }
            .padding(.horizontal, 16)
            .animation(.snappy(duration: 0.32), value: showsReply)
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                Button {
                    selection = item.tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 20, weight: .medium))
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(selection == item.tab ? 1 : 0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if selection == item.tab {
                            Capsule()
                                .fill(.white.opacity(0.14))
                                .padding(5)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(selection == item.tab ? [.isSelected] : [])
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.snappy(duration: 0.25), value: selection)
    }
}
