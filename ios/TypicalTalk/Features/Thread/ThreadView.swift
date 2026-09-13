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

                    bottomBar(talk).padding(.top, 8)
                }
                // Pushed screens do not inherit the tab bar's inset, so the
                // strip reserves the bar's height itself.
                .padding(.bottom, AppTabBar.height + 12)
            } else {
                ContentUnavailableView("Talk not found", systemImage: "questionmark.circle")
            }
        }
        .background(Palette.canvas)
        // Belongs to this screen and sits exactly in the tab bar's row, so it
        // slides off with the thread as you swipe back instead of vanishing
        // once the swipe has finished.
        .overlay(alignment: .bottomTrailing) {
            ReplyBarButton { beginReply() }
                .matchedTransitionSource(id: "reply", in: replyMorph)
                .padding(.trailing, AppTabBar.horizontalPadding)
                .padding(.bottom, AppTabBar.bottomPadding)
        }
        .navigationTitle(talk?.title ?? "Talk")
        .navigationSubtitle(current.map { "\($0.author.name), \(relativeLabel($0.sentAt))" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showRecorder) {
            RecorderSheet(destination: talkID)
                .navigationTransition(.zoom(sourceID: "reply", in: replyMorph))
        }
        .task { showTranscript = store.alwaysShowCaptions }
        .onAppear { ThreadContext.shared.openTalk = talkID }
        .task(id: talkID) { await store.ensureTranscripts(in: talkID) }
        .onDisappear {
            saveProgress()
            player.teardown()
            if ThreadContext.shared.openTalk == talkID { ThreadContext.shared.openTalk = nil }
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
        store.markWatched(messageID: message.id, in: talkID)
    }

    // MARK: - Bottom bar

    private func bottomBar(_ talk: Talk) -> some View {
        timeline(talk).padding(.bottom, 6)
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
