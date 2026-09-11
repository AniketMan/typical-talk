import SwiftUI

/// Reactions, mentions and watch receipts in one place. The old Activity tab
/// did not earn a tab, so it folds into this bell.
struct NotificationsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.notifications.isEmpty {
                    ContentUnavailableView(
                        "Nothing new",
                        systemImage: "bell.slash",
                        description: Text("Reactions, mentions and watch receipts land here.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.notifications) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.footnote.weight(.semibold))
                                .frame(width: 30, height: 30)
                                .background(.white.opacity(0.08), in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text).font(.subheadline.weight(.semibold))
                                Text(item.detail)
                                    .font(.caption2)
                                    .foregroundStyle(Palette.secondaryText)
                            }
                            Spacer()
                            Text(relativeLabel(item.at))
                                .font(.caption2)
                                .foregroundStyle(Palette.secondaryText)
                        }
                        .listRowBackground(Palette.raised)
                    }
                    .onDelete { store.notifications.remove(atOffsets: $0) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        withAnimation(.snappy) { store.notifications.removeAll() }
                    }
                    .disabled(store.notifications.isEmpty)
                }
            }
        }
    }
}
