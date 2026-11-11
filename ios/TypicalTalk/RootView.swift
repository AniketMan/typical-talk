import SwiftUI

enum AppTab: Hashable {
    case talks, friends, archive, you
    /// The detached circle at the end of the tab bar. It is never a
    /// destination: selecting it performs an action and the selection stays
    /// where it was.
    case action
}

/// Three tabs on the system tab bar, Talks, You and Archive, plus a detached
/// circle at the trailing end, the way Music shows search.
///
/// This is Apple's real TabView, not a replica, so press-and-slide selection
/// and the swipe back behave exactly as the system does. The circle never
/// disappears, which the HIG asks of tab bar items; instead it changes job:
/// on Talks it starts a new talk, and inside a thread it records a reply.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: AppTab = Self.initialTab
    @State private var archiveQuery = ""
    @State private var router = IntentRouter.shared
    @State private var draft = DraftRecorder.shared
    @State private var thread = ThreadContext.shared
    @State private var showNewTalk = false

    private var inThread: Bool { thread.openTalk != nil }

    private var actionTitle: String { draft.hasDraft ? "Resume" : (inThread ? "Reply" : "New Take") }
    private var actionSymbol: String { draft.hasDraft ? "record.circle" : (inThread ? "video.fill" : "plus") }

    /// Selecting the circle runs its action instead of switching tabs.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selection },
            set: { next in
                guard next == .action else {
                    selection = next
                    return
                }
                // A draft waiting means this button carries on recording it.
                if draft.hasDraft {
                    draft.resume()
                } else if inThread {
                    ThreadContext.shared.requestReply()
                } else {
                    showNewTalk = true
                }
            }
        )
    }

    /// Red symbols baked as original images, because tab labels ignore
    /// foregroundStyle and would otherwise repaint them with the app tint.
    private static func redSymbol(_ name: String) -> UIImage {
        let tint = UIColor(red: 1.0, green: 0.325, blue: 0.435, alpha: 1.0)
        let config = UIImage.SymbolConfiguration(weight: .semibold)
        guard let symbol = UIImage(systemName: name, withConfiguration: config) else { return UIImage() }
        return symbol.withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    /// Lets a debug build launch straight into a tab, for screenshot checks.
    private static var initialTab: AppTab {
        #if DEBUG
        switch ProcessInfo.processInfo.arguments.last(where: { $0.hasPrefix("tab:") }) {
        case "tab:archive": return .archive
        case "tab:you": return .you
        case "tab:friends": return .friends
        default: return .talks
        }
        #else
        return .talks
        #endif
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Takes", systemImage: "bubble.left.and.bubble.right", value: AppTab.talks) {
                TalksView()
            }

            Tab("Friends", systemImage: "person.2", value: AppTab.friends) {
                NavigationStack {
                    FindFriendsView()
                        .navigationTitle("Friends")
                        .background(Palette.canvas)
                }
            }

            Tab("You", systemImage: "person.crop.circle", value: AppTab.you) {
                YouView()
            }

            Tab("Archive", systemImage: "magnifyingglass", value: AppTab.archive) {
                ArchiveView(query: $archiveQuery)
            }

            // iOS 27 draws a prominent tab as its own circle beside the bar.
            // On iOS 26 that role does not exist, so the same action sits in
            // the bar as an ordinary item: it still changes job and still
            // never disappears.
            if #available(iOS 27.0, *) {
                Tab(actionTitle, systemImage: actionSymbol, value: AppTab.action, role: .prominent) {
                    Color.clear
                }
            } else {
                Tab(actionTitle, systemImage: actionSymbol, value: AppTab.action) {
                    Color.clear
                }
            }
        }
        .tint(Palette.record)
        // One recorder for the whole app. A sheet, so it can be swiped down;
        // doing that pauses it into a draft rather than losing it.
        .sheet(isPresented: Binding(get: { draft.isPresented }, set: { draft.isPresented = $0 })) {
            RecorderSheet()
                .presentationBackground(Palette.canvas)
        }
        .sheet(isPresented: $showNewTalk) {
            NewTalkView { id in
                // Let New Talk finish leaving before the recorder arrives.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    draft.open(for: id)
                }
            }
            .presentationBackground(Palette.canvas)
        }
        .modifier(DraftAccessory(draft: draft))
        .background(Palette.canvas)
        .task {
            // Ask for push in its own task: the permission prompt waits for an
            // answer, and syncing must not.
            #if DEBUG
            // Against a local test server there is nothing to push from, and
            // the permission alert would block what is being tested.
            if ProcessInfo.processInfo.environment["TT_API_BASE"] != nil { return }
            #endif
            if store.notificationsEnabled { await PushRegistrar.shared.enable() }
        }
        .task {
            // Keep the phone current: now, and every twenty seconds while the
            // app is open. Pushes cover the rest.
            while !Task.isCancelled {
                await store.sync()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        #if DEBUG
        .task {
            // Debug only: launch straight into the newest thread for
            // screenshot checks, and send a given video as a take, because a
            // simulator has no camera to record one.
            let environment = ProcessInfo.processInfo.environment
            try? await Task.sleep(for: .seconds(2))
            if let path = environment["TT_DEBUG_SEND"], let first = store.talks.first {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("debug-\(UUID().uuidString).mov")
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
                store.send(take: copy, duration: 10, transcript: [], voiceOnly: false, to: first.id)
            }
            // Debug only: run the safety and group actions without tapping.
            let me = store.me
            let others = store.talks.flatMap(\.members).filter { $0.id != me.id }
            if environment["TT_DEBUG_CAPTIONS"] == "1" { store.alwaysShowCaptions = true }
            if let fraction = environment["TT_DEBUG_RESUME"].flatMap(Double.init),
               let talk = store.talks.first(where: { $0.title.contains(environment["TT_DEBUG_OPEN"] ?? "") }) {
                for message in talk.messages { store.saveProgress(message.duration * fraction, for: message.id, duration: message.duration) }
            }
            switch environment["TT_DEBUG_ACTION"] {
            case "group":
                let result = await store.createGroup(with: Array(Set(others)), title: "Test Crew")
                print("TT_DEBUG group:", result.0 as Any, result.1 as Any)
            case "report":
                if let talk = store.talks.first(where: { $0.messages.contains { !$0.author.isYou } }),
                   let message = talk.messages.first(where: { !$0.author.isYou }) {
                    print("TT_DEBUG report:", await store.report(message, in: talk.id, reason: .spam, details: nil) as Any)
                }
            case "block":
                if let person = others.first { print("TT_DEBUG block:", await store.block(person) as Any) }
            case "draft", "draftsend":
                // Two segments with a pause between, then close the recorder.
                guard let talk = store.talks.first else { break }
                for clip in (environment["TT_DEBUG_CLIPS"] ?? "").split(separator: ",") {
                    draft.debugAddSegment(from: URL(fileURLWithPath: String(clip)), duration: 10, to: talk.id)
                }
                try? await Task.sleep(for: .seconds(1))
                print("TT_DEBUG draft: segments", draft.segments.count, "seconds", draft.duration, "hasDraft", draft.hasDraft)
                if environment["TT_DEBUG_ACTION"] == "draftsend", let joined = await draft.assemble() {
                    print("TT_DEBUG joined:", joined.duration)
                    store.send(take: joined.url, duration: joined.duration, transcript: [], voiceOnly: draft.isVoiceOnly, to: talk.id)
                    draft.finishSent()
                    print("TT_DEBUG sent, hasDraft", draft.hasDraft)
                }
            case "newtalk":
                showNewTalk = true
            default: break
            }
            if let name = environment["TT_DEBUG_OPEN"], let match = store.talks.first(where: { $0.title.contains(name) }) {
                TalksNavigation.shared.open = match.id
            }
            if ProcessInfo.processInfo.arguments.contains("thread:first"), let first = store.talks.first {
                TalksNavigation.shared.open = first.id
            }
        }
        #endif
        // Siri and Shortcuts drive the app through the router.
        .onChange(of: router.showArchive) { _, show in
            guard show else { return }
            archiveQuery = router.searchQuery ?? ""
            selection = .archive
            router.showArchive = false
        }
        .onChange(of: router.openRecorderFor) { _, target in
            guard let target else { return }
            draft.open(for: target)
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


/// The paused draft, shown above the tab bar the way Music shows what is
/// playing. On iOS 26.1 and later it is the system's own tab bar accessory;
/// on 26.0, which lacks a way to hide that accessory, it floats in the same
/// place.
struct DraftAccessory: ViewModifier {
    let draft: DraftRecorder

    private var showing: Bool { draft.hasDraft && !draft.isPresented }

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: showing) { DraftPill(draft: draft) }
        } else {
            content.overlay(alignment: .bottom) {
                if showing {
                    DraftPill(draft: draft)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 92)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

struct DraftPill: View {
    let draft: DraftRecorder
    @Environment(AppStore.self) private var store
    @State private var confirmDiscard = false

    private var who: String {
        draft.talkID.flatMap { store.talk(id: $0)?.title } ?? "your talk"
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Palette.record)
                .frame(width: 10, height: 10)
                .phaseAnimator([1.0, 0.35]) { dot, opacity in dot.opacity(opacity) } animation: { _ in
                    .easeInOut(duration: 0.9)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text("Draft to \(who)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(timecode(draft.duration)) recorded. Tap to carry on.")
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 8)
            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(Palette.record)
        }
        .padding(.horizontal, 14)
        .contentShape(.rect)
        .onTapGesture { draft.resume() }
        .contextMenu {
            Button("Carry on recording", systemImage: "record.circle") { draft.resume() }
            Button("Throw away draft", systemImage: "trash", role: .destructive) { confirmDiscard = true }
        }
        .confirmationDialog("Throw away this draft?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Throw away", role: .destructive) { draft.discard() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Draft to \(who), \(timecode(draft.duration)) recorded")
        .accessibilityHint("Opens the recorder to carry on")
        .accessibilityAddTraits(.isButton)
    }
}
