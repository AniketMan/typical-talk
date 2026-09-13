import SwiftUI

struct TalksView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: Filter = .all
    @State private var showNotifications = false
    @State private var showFindFriends = false
    @State private var showNewTalk = false
    var startRecording: (Talk.ID) -> Void = { _ in }
    @State private var navigation = TalksNavigation.shared
    @State private var path: [Talk.ID] = []
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
                        showNewTalk = true
                    } label: {
                        Label("New Talk", systemImage: "plus")
                    }
                    .labelStyle(.iconOnly)
                }
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
                }
            }
            #if DEBUG
            // Debug only: open Find Friends at launch for screenshot checks.
            .task {
                if ProcessInfo.processInfo.arguments.contains("sheet:friends") {
                    showFindFriends = true
                }
            }
            #endif
            .onChange(of: navigation.open) { _, id in
                guard let id else { return }
                path = [id]
                navigation.open = nil
            }
            .sheet(isPresented: $showNewTalk) {
                NewTalkView { id in startRecording(id) }
                    .presentationBackground(Palette.canvas)
            }
            .sheet(isPresented: $showFindFriends) {
                // Its own stack: binding the Talks path here made the sheet and
                // the tab share navigation state.
                NavigationStack {
                    FindFriendsView()
                        .navigationTitle("Find Friends")
                        .navigationBarTitleDisplayMode(.inline)
                        .background(Palette.canvas)
                        .toolbar {
                            // There was no way out of this sheet. The zoom
                            // transition makes swipe-down unreliable, so it
                            // needs an explicit close.
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(role: .close) { showFindFriends = false }
                            }
                        }
                }
                .navigationTransition(.zoom(sourceID: "friends", in: morph))
                .presentationBackground(Palette.canvas)
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
