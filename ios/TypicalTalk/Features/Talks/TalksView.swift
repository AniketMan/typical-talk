import SwiftUI

struct TalksView: View {
    @Environment(AppStore.self) private var store
    @State private var view: Segment = .talks
    @State private var filter: Filter = .all
    @State private var showNotifications = false
    @Namespace private var notificationsMorph

    enum Segment: String, CaseIterable, Identifiable {
        case talks = "Talks", friends = "Find friends"
        var id: Self { self }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", unread = "Unread", active = "Active"
        var id: Self { self }
    }

    private var visibleTalks: [Talk] {
        switch filter {
        case .all: store.talks
        case .unread: store.talks.filter(\.hasUnread)
        case .active: store.talks.filter { $0.presenceLine != nil }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch view {
                case .talks: talksList
                case .friends: FindFriendsView()
                }
            }
            .background(Palette.canvas)
            .navigationTitle(view == .talks ? "Talks" : "Find friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $view.animation(.snappy(duration: 0.28))) {
                        ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNotifications = true
                    } label: {
                        Label("Notifications", systemImage: "bell")
                            .overlay(alignment: .topTrailing) {
                                if store.unreadNotificationCount > 0 {
                                    Circle()
                                        .fill(Palette.unread)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 4, y: -2)
                                }
                            }
                    }
                    .matchedTransitionSource(id: "notifications", in: notificationsMorph)
                }
            }
            .sheet(isPresented: $showNotifications) {
                NotificationsView()
                    .navigationTransition(.zoom(sourceID: "notifications", in: notificationsMorph))
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Palette.canvas)
            }
        }
    }

    private var talksList: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                header

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
        .navigationDestination(for: Talk.ID.self) { id in
            if let talk = store.talk(id: id) {
                ThreadView(talkID: talk.id)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent")
                    .font(.largeTitle.weight(.bold))
                Spacer()
                Text("^[\(store.talks.count) thread](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }

            Picker("Filter", selection: $filter.animation(.snappy(duration: 0.24))) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.top, 6)
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
