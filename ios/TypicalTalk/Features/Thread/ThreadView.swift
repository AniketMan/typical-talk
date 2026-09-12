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
                        autoplayOnLoad: $autoplayOnLoad
                    )

                    if showTranscript {
                        TranscriptPane(message: current, player: player)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .safeAreaBar(edge: .bottom, spacing: 10) { bottomBar(talk) }
            } else {
                ContentUnavailableView("Talk not found", systemImage: "questionmark.circle")
            }
        }
        .background(Palette.canvas)
        .navigationTitle(talk?.title ?? "Talk")
        .navigationSubtitle(current.map { "\($0.author.name), \(relativeLabel($0.sentAt))" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy(duration: 0.28)) { showTranscript.toggle() }
                } label: {
                    Label("Transcript", systemImage: showTranscript ? "captions.bubble.fill" : "captions.bubble")
                }
            }
        }
        .fullScreenCover(isPresented: $showRecorder) {
            RecorderSheet(destination: talkID)
                .navigationTransition(.zoom(sourceID: "reply", in: replyMorph))
        }
        .task { showTranscript = store.alwaysShowCaptions }
        .task(id: talkID) { await store.ensureTranscripts(in: talkID) }
        .onDisappear {
            saveProgress()
            player.teardown()
        }
    }

    // MARK: - Switching takes

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
        VStack(spacing: 10) {
            if talk.messages.count > 1 { timeline(talk) }
            replyBar
        }
    }

    /// Every take in the thread, newest first. This is the only way to move
    /// between takes, so it is always visible.
    private func timeline(_ talk: Talk) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(talk.messages) { message in
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
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private var replyBar: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(["❤️", "😂", "👏"], id: \.self) { emoji in
                    Button(emoji) {
                        if let current {
                            store.toggleReaction(emoji, messageID: current.id, in: talkID)
                        }
                    }
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                }

                Button {
                    // Recording a reply must not lose your place.
                    saveProgress()
                    if player.isPlaying { player.togglePlay() }
                    showRecorder = true
                } label: {
                    Label("Reply", systemImage: "video.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Palette.record).interactive(), in: .capsule)
                .matchedTransitionSource(id: "reply", in: replyMorph)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
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
