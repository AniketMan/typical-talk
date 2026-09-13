import SwiftUI

/// A row of segments with a highlight you can drag between them, the way the
/// system tab bar behaves in iOS 26: press and slide, the highlight follows
/// your finger and lifts slightly, and it settles on the nearest segment when
/// you let go. A plain tap selects directly.
///
/// Used by the tab bar and the playback speed control, which previously were
/// rows of buttons with a static highlight and could only be tapped.
struct GlassSegmentPicker<Item: Hashable, Label: View>: View {
    let items: [Item]
    @Binding var selection: Item
    var highlight: AnyShapeStyle = AnyShapeStyle(.white.opacity(0.16))
    var inset: CGFloat = 4
    @ViewBuilder var label: (_ item: Item, _ isSelected: Bool) -> Label

    /// Centre of the highlight while a finger is sliding it; nil at rest.
    @State private var dragX: CGFloat?
    @State private var pressed = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let segment = width / CGFloat(max(items.count, 1))
            let restingIndex = CGFloat(items.firstIndex(of: selection) ?? 0)
            let centre = dragX ?? (restingIndex * segment + segment / 2)
            let hovered = index(at: centre, segment: segment)

            ZStack {
                Capsule()
                    .fill(highlight)
                    .frame(width: max(0, segment - inset * 2), height: max(0, height - inset * 2))
                    .scaleEffect(pressed ? 1.08 : 1)
                    .position(x: centre, y: height / 2)

                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element) { offset, item in
                        label(item, offset == hovered)
                            .frame(width: segment, height: height)
                            .contentShape(.rect)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(item == selection ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { selection = item }
                    }
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressed {
                            withAnimation(.snappy(duration: 0.18)) { pressed = true }
                        }
                        // Only start sliding once the finger has actually
                        // moved, so a tap does not jolt the highlight.
                        guard dragX != nil || abs(value.translation.width) > 6 else { return }
                        dragX = min(max(value.location.x, segment / 2), width - segment / 2)
                    }
                    .onEnded { value in
                        let landed = index(at: min(max(value.location.x, 0), width - 1), segment: segment)
                        withAnimation(.snappy(duration: 0.3, extraBounce: 0.12)) {
                            dragX = nil
                            pressed = false
                            selection = items[landed]
                        }
                    }
            )
        }
    }

    private func index(at x: CGFloat, segment: CGFloat) -> Int {
        guard segment > 0, !items.isEmpty else { return 0 }
        return min(max(Int(x / segment), 0), items.count - 1)
    }
}
