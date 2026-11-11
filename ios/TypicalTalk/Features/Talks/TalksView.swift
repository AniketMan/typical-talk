import SwiftUI

struct TalksView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: Filter = .all
    @State private var showNotifications = false
    @State private var navigation = TalksNavigation.shared
    @State private var path: [Talk.ID] = []
    @State private var pendingDelete: Talk?
    @State private var deleteError: String?
    @Namespace private var morph

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", unread = "Unread", active = "Active"
        var id: Self { self }
    }

    private var visibleTalks: [Talk] {
        switch filter {
        case .all: store.talks
        case .unread: store.talks.filter(\.hasUnread)
        case .active: store.talks.filter { $0.statusLine != nil }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // One segmented control, not two. The screen is named by
                // the navigation title, so no second heading either.
                Picker("Filter", selection: $filter.animation(.snappy(duration: 0.24))) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 9, trailing: 16))

                if visibleTalks.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(visibleTalks) { talk in
                        // The link sits behind the card so the list draws no
                        // disclosure arrow on it.
                        ZStack {
                            NavigationLink(value: talk.id) { EmptyView() }.opacity(0)
                            TalkCard(talk: talk)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = talk
                            } label: {
                                Label(talk.isGroup ? "Leave" : "Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .refreshable { await store.sync() }
            .background(Palette.canvas)
            .navigationTitle("Talks")
            .navigationSubtitle(store.lastSyncFailed ? "Offline, showing saved talks" : "")
            .navigationDestination(for: Talk.ID.self) { id in
                if store.talk(id: id) != nil {
                    ThreadView(talkID: id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNotifications = true
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                    .labelStyle(.iconOnly)
                    .overlay(alignment: .topTrailing) {
                        if store.unreadNotificationCount > 0 {
                            Circle()
                                .fill(Palette.record)
                                .frame(width: 7, height: 7)
                                .offset(x: 3, y: -1)
                        }
                    }
                }
            }
            .onChange(of: navigation.open) { _, id in
                guard let id else { return }
                path = [id]
                navigation.open = nil
            }
            .confirmationDialog(
                (pendingDelete?.isGroup ?? false) ? "Leave this group?" : "Delete this conversation?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { talk in
                Button(talk.isGroup ? "Leave" : "Delete", role: .destructive) {
                    Task { deleteError = await store.leave(talk.id) }
                }
            } message: { talk in
                Text(talk.isGroup
                     ? "You will stop getting takes from \(talk.title), and its takes are removed from your phone."
                     : "The takes in your talk with \(talk.title) are removed from your phone.")
            }
            .alert("Couldn't do that", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .sheet(isPresented: $showNotifications) {
                // A plain slide up. Zooming from the bell all the way down to a
                // bottom sheet travelled too far to read as a morph.
                NotificationsView()
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Palette.canvas)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !store.hasSynced && store.talks.isEmpty && !store.lastSyncFailed {
            ProgressView().padding(.top, 60)
        } else {
            ContentUnavailableView {
                Label("Nothing here yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(filter == .unread
                     ? "You are caught up. Every take has been watched."
                     : "Add a friend in the Friends tab, then start a talk with the plus button.")
            }
            .padding(.top, 40)
        }
    }
}
