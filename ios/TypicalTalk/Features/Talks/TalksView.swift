import SwiftUI

struct TalksView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: Filter = .all
    @State private var showNotifications = false
    @State private var showFindFriends = false
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
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    // One segmented control, not two. The screen is named by
                    // the navigation title, so no second heading either.
                    Picker("Filter", selection: $filter.animation(.snappy(duration: 0.24))) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 4)

                    if visibleTalks.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleTalks) { talk in
                            NavigationLink(value: talk.id) {
                                TalkCard(talk: talk)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(Palette.canvas)
            .navigationTitle("Talks")
            .navigationDestination(for: Talk.ID.self) { id in
                if store.talk(id: id) != nil {
                    ThreadView(talkID: id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFindFriends = true
                    } label: {
                        Label("Find Friends", systemImage: "person.badge.plus")
                    }
                    .labelStyle(.iconOnly)
                    .matchedTransitionSource(id: "friends", in: morph)
                }
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
                    .matchedTransitionSource(id: "notifications", in: morph)
                }
            }
            .sheet(isPresented: $showFindFriends) {
                NavigationStack {
                    FindFriendsView()
                        .navigationTitle("Find Friends")
                        .navigationBarTitleDisplayMode(.inline)
                        .background(Palette.canvas)
                }
                .navigationTransition(.zoom(sourceID: "friends", in: morph))
                .presentationBackground(Palette.canvas)
            }
            .sheet(isPresented: $showNotifications) {
                NotificationsView()
                    .navigationTransition(.zoom(sourceID: "notifications", in: morph))
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Palette.canvas)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text(filter == .unread
                 ? "You are caught up. Every take has been watched."
                 : "No one is recording right now.")
        }
        .padding(.top, 40)
    }
}
