import AVKit
import SwiftUI

/// One thread, one player. The take you selected fills the screen, its
/// transcript sits under it, and the strip along the bottom switches between
/// takes. Nothing else is stacked in the way, so tapping a take in the strip
/// visibly changes what is playing.
struct ThreadView: View {
    let talkID: Talk.ID
    @Environment(AppStore.self) private var store
    @State private var player = ThreadPlayer()
    @State private var selected: Message.ID?
    @State private var showTranscript = false
    @State private var showRecorder = false
    @State private var autoplayOnLoad = false
    @State private var showReport = false
    @State private var showBlock = false
    @State private var showLeave = false
    @State private var showAddPeople = false
    @State private var actionError: String?
    @Environment(\.dismiss) private var dismiss
    @Namespace private var replyMorph

    private var talk: Talk? { store.talk(id: talkID) }

    /// The take currently in the player. Defaults to the newest.
    private var current: Message? {
        guard let talk else { return nil }
        if let selected, let match = talk.messages.first(where: { $0.id == selected }) { return match }
        return talk.latest
    }

    var body: some View {
        Group {
            if let talk, let current {
                VStack(spacing: 0) {
                    TakePlayerView(
                        message: current,
                        talkID: talkID,
                        player: player,
                        autoplayOnLoad: $autoplayOnLoad,
                        showTranscript: $showTranscript
                    )

                    if showTranscript {
                        TranscriptPane(message: current, player: player)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                }
                // Above the system tab bar, inside this screen, so the strip
                // and the reply button slide away with the thread.
                .safeAreaBar(edge: .bottom, spacing: 8) { bottomBar(talk) }
            } else {
                ContentUnavailableView("Talk not found", systemImage: "questionmark.circle")
            }
        }
        .background(Palette.canvas)
        .navigationTitle(talk?.title ?? "Talk")
        .navigationSubtitle(current.map { "\($0.author.name), \(relativeLabel($0.sentAt))" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { threadMenu }
        .confirmationDialog("Report this take", isPresented: $showReport, titleVisibility: .visible) {
            ForEach(TalkAPI.ReportReason.allCases) { reason in
                Button(reason.label) { report(reason) }
            }
        } message: {
            Text("It is removed from your phone and sent to us to review.")
        }
        .confirmationDialog(
            "Block \(current?.author.name ?? "this person")?",
            isPresented: $showBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { blockAuthor() }
        } message: {
            Text("They cannot find you or send you takes, and their takes disappear from your phone.")
        }
        .confirmationDialog(
            (talk?.isGroup ?? false) ? "Leave this group?" : "Delete this conversation?",
            isPresented: $showLeave,
            titleVisibility: .visible
        ) {
            Button((talk?.isGroup ?? false) ? "Leave" : "Delete", role: .destructive) { leaveTalk() }
        } message: {
            Text("The takes in it are removed from your phone.")
        }
        .alert("Couldn't do that", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .sheet(isPresented: $showAddPeople) {
            AddPeopleView(talkID: talkID)
                .presentationDetents([.medium, .large])
                .presentationBackground(Palette.canvas)
        }
        .fullScreenCover(isPresented: $showRecorder) {
            RecorderSheet(destination: talkID)
        }
        .task { showTranscript = store.alwaysShowCaptions }
        .onAppear { ThreadContext.shared.openTalk = talkID }
        // The tab bar's circle becomes Reply while this thread is open.
        .onChange(of: ThreadContext.shared.replyRequests) { _, _ in beginReply() }
        .task(id: talkID) { await store.ensureTranscripts(in: talkID) }
        .onDisappear {
            saveProgress()
            player.teardown()
            if ThreadContext.shared.openTalk == talkID { ThreadContext.shared.openTalk = nil }
        }
    }

    // MARK: - Menu

    @ToolbarContentBuilder
    private var threadMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let talk, talk.isGroup {
                    Button("Add people", systemImage: "person.badge.plus") { showAddPeople = true }
                }
                if let current, !current.author.isYou {
                    Button("Report this take", systemImage: "flag") { showReport = true }
                    Button("Block \(current.author.name)", systemImage: "hand.raised", role: .destructive) {
                        showBlock = true
                    }
                }
                Button(
                    (talk?.isGroup ?? false) ? "Leave group" : "Delete conversation",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    role: .destructive
                ) { showLeave = true }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    private func report(_ reason: TalkAPI.ReportReason) {
        guard let current else { return }
        player.teardown()
        Task {
            if let problem = await store.report(current, in: talkID, reason: reason, details: nil) {
                actionError = problem
            }
        }
    }

    private func blockAuthor() {
        guard let person = current?.author, !person.isYou else { return }
        player.teardown()
        Task {
            if let problem = await store.block(person) {
                actionError = problem
            } else if store.talk(id: talkID) == nil {
                dismiss()
            }
        }
    }

    private func leaveTalk() {
        player.teardown()
        Task {
            if let problem = await store.leave(talkID) {
                actionError = problem
            } else {
                dismiss()
            }
        }
    }

    // MARK: - Switching takes

    /// Pauses, saves your place, and opens the recorder.
    private func beginReply() {
        saveProgress()
        if player.isPlaying { player.togglePlay() }
        showRecorder = true
    }

    /// Stores where the current take got to, before the player is reused.
    private func saveProgress() {
        guard let current else { return }
        let length = player.duration > 0 ? player.duration : current.duration
        store.saveProgress(player.currentTime, for: current.id, duration: length)
    }

    /// Tapping the take already playing toggles it. Tapping a different one
    /// switches the player to it and picks up where that take was left off.
    private func select(_ message: Message) {
        if message.id == current?.id {
            player.togglePlay()
            return
        }
        saveProgress()
        autoplayOnLoad = true
        selected = message.id
        // Only a take that is on the phone can have been watched.
        if message.fileName != nil { store.markWatched(messageID: message.id, in: talkID) }
    }

    // MARK: - Bottom bar

    private func bottomBar(_ talk: Talk) -> some View {
        VStack(spacing: 8) {
            deliveryBanner(talk)
            timeline(talk)
        }
        .padding(.bottom, 6)
    }

    /// Shown while one of your takes is on its way, or if it could not go.
    @ViewBuilder
    private func deliveryBanner(_ talk: Talk) -> some View {
        if let stuck = talk.messages.first(where: { $0.author.isYou && $0.delivery != .sent }) {
            HStack(spacing: 10) {
                if stuck.delivery == .sending {
                    ProgressView(value: store.uploadProgress[stuck.id] ?? 0)
                        .progressViewStyle(.linear)
                        .tint(Palette.record)
                        .frame(width: 80)
                    Text("Sending\((store.uploadProgress[stuck.id] ?? 0) > 0 ? " \(Int((store.uploadProgress[stuck.id] ?? 0) * 100))%" : "")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.secondaryText)
                    Spacer(minLength: 0)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.record)
                    Text(store.failureNotes[stuck.id] ?? "Your take was not sent.")
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Retry") { store.retry(stuck.id, in: talkID) }
                        .buttonStyle(.glass)
                    Button("Delete", role: .destructive) { store.discard(stuck.id, in: talkID) }
                        .buttonStyle(.glass)
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .transition(.opacity)
        }
    }

    /// Every take in the thread, oldest on the left so the newest sits on the
    /// right where the conversation has got to. Scrolls itself to whatever is
    /// playing, so a long thread never opens scrolled into the past.
    private func timeline(_ talk: Talk) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(talk.messages.reversed()) { message in
                        Button { select(message) } label: {
                            VStack(spacing: 4) {
                                TakeThumbnail(
                                    message: message,
                                    size: .small,
                                    isActive: message.id == current?.id,
                                    showsDuration: false
                                )
                                Text(message.author.isYou ? "You" : message.author.name)
                                    .font(.system(size: 10))
                                    .foregroundStyle(
                                        message.id == current?.id ? .white : Palette.secondaryText
                                    )
                                    .lineLimit(1)
                            }
                            .frame(width: 54)
                        }
                        .buttonStyle(.plain)
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            // Start at the newest end on first draw, so opening a thread does
            // not show the oldest takes and then slide across.
            .defaultScrollAnchor(.trailing, for: .initialOffset)
            .frame(maxWidth: .infinity)
            .onAppear { scroll(proxy, to: current?.id) }
            .onChange(of: current?.id) { _, id in scroll(proxy, to: id, animated: true) }
            .onChange(of: talk.messages.count) { _, _ in
                scroll(proxy, to: talk.latest?.id, animated: true)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: Message.ID?, animated: Bool = false) {
        guard let id else { return }
        if animated {
            withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

}

/// The transcript of the take being watched, and only that take. Tapping a
/// line seeks the player to it.
struct TranscriptPane: View {
    let message: Message
    @Bindable var player: ThreadPlayer

    private var activeID: TranscriptSegment.ID? {
        message.transcript.last { $0.start <= player.currentTime }?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if message.transcript.isEmpty {
                        Label("Transcribing on device", systemImage: "waveform")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(message.transcript) { segment in
                            Button { player.seek(to: segment.start) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Text(timecode(segment.start))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Palette.secondaryText)
                                        .frame(width: 36, alignment: .leading)
                                    Text(segment.text)
                                        .font(.subheadline)
                                        .multilineTextAlignment(.leading)
                                        .foregroundStyle(
                                            segment.id == activeID ? .white : .white.opacity(0.6)
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                            .id(segment.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(maxHeight: 190)
            .background(Palette.raised)
            .onChange(of: activeID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}



/// Pick people you already talk to and add them to a group.
struct AddPeopleView: View {
    let talkID: Talk.ID
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var candidates: [Person] {
        let inGroup = Set(store.talk(id: talkID)?.members.map(\.id) ?? [])
        var seen = Set<UUID>()
        return store.talks.flatMap(\.members)
            .filter { !$0.isYou && !inGroup.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No one to add",
                        systemImage: "person.2",
                        description: Text("Everyone you talk to is already in this group.")
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(candidates) { person in
                    Button {
                        if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Monogram(text: person.initials, size: Scale.Avatar.medium)
                            Text(person.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: selected.contains(person.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(person.id) ? Palette.record : Palette.secondaryText)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Palette.raised)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(Palette.record)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Add people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        Task {
                            isWorking = true
                            defer { isWorking = false }
                            let people = candidates.filter { selected.contains($0.id) }
                            errorMessage = await store.addPeople(people, to: talkID)
                            if errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(selected.isEmpty || isWorking)
                }
            }
        }
    }
}
