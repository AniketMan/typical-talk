import AVKit
import SwiftUI

/// The cinematic thread. Newest at the top, everywhere, per the locked
/// ordering decision. The first message is the hero with a full player; the
/// rest are compact rows that promote themselves when tapped.
struct ThreadView: View {
    let talkID: Talk.ID
    @Environment(AppStore.self) private var store
    @State private var player = ThreadPlayer()
    @State private var focused: Message.ID?
    @State private var showTranscript = false
    @State private var showRecorder = false
    /// Set when the user picked a take, so it starts playing once it loads.
    @State private var autoplayOnLoad = false
    @Namespace private var replyMorph

    private var talk: Talk? { store.talk(id: talkID) }

    private var hero: Message? {
        guard let talk else { return nil }
        if let focused, let match = talk.messages.first(where: { $0.id == focused }) { return match }
        return talk.latest
    }

    var body: some View {
        Group {
            if let talk {
                content(talk)
            } else {
                ContentUnavailableView("Talk not found", systemImage: "questionmark.circle")
            }
        }
        .background(Palette.canvas)
        .navigationTitle(talk?.title ?? "Talk")
        .navigationSubtitle(talk?.statusLine ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Mark all watched", systemImage: "checkmark.circle") {
                        store.markAllWatched(in: talkID)
                    }
                    Button(showTranscript ? "Hide transcript" : "Show transcript", systemImage: "text.alignleft") {
                        withAnimation(.snappy) { showTranscript.toggle() }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 10) { bottomBar }
        .fullScreenCover(isPresented: $showRecorder) {
            RecorderSheet(destination: talkID)
                .navigationTransition(.zoom(sourceID: "reply", in: replyMorph))
        }
        .task { showTranscript = store.alwaysShowCaptions }
        .onDisappear {
            saveCurrentProgress()
            player.teardown()
        }
    }

    private func content(_ talk: Talk) -> some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if talk.unreadCount > 0 {
                    CatchUpCard(talk: talk) { playBacklog(in: talk) }
                }

                if let hero {
                    HeroMessageCard(
                        message: hero,
                        talkID: talkID,
                        player: player,
                        showTranscript: $showTranscript,
                        autoplayOnLoad: $autoplayOnLoad
                    )
                    .id(hero.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                ForEach(talk.messages.filter { $0.id != hero?.id }) { message in
                    MessageRow(message: message) { play(message) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    /// Stores the current take's position before the player is reused.
    private func saveCurrentProgress() {
        guard let hero else { return }
        let length = player.duration > 0 ? player.duration : hero.duration
        store.saveProgress(player.currentTime, for: hero.id, duration: length)
    }

    /// Promotes a take to the player and starts it. Tapping a take should
    /// play it, which is the whole point of the thread.
    private func play(_ message: Message) {
        if message.id == focused || (focused == nil && message.id == talk?.latest?.id) {
            player.togglePlay()
            return
        }
        saveCurrentProgress()
        autoplayOnLoad = true
        withAnimation(.snappy(duration: 0.32)) { focused = message.id }
        store.markWatched(messageID: message.id, in: talkID)
    }

    /// Starts the backlog at its oldest unwatched take and rolls forward, so
    /// "Play all" actually plays rather than just clearing the badge.
    private func playBacklog(in talk: Talk) {
        guard let oldest = talk.messages.last(where: { !$0.watched && !$0.author.isYou }) else { return }
        play(oldest)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let talk, talk.messages.count > 1 { timeline(talk) }
            replyBar
        }
    }

    /// Every take in the thread, newest first, as a scrubbable strip. Tap one
    /// to play it without losing your place in the conversation.
    private func timeline(_ talk: Talk) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(talk.messages) { message in
                    Button { play(message) } label: {
                        TimelineChip(message: message, isPlaying: message.id == hero?.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    /// Quick reactions and the reply action, as separate glass pills floating
    /// clear of the tab bar. Never a single slab, and never glass on glass.
    private var replyBar: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(["❤️", "😂", "👏"], id: \.self) { emoji in
                    Button(emoji) {
                        if let hero {
                            store.toggleReaction(emoji, messageID: hero.id, in: talkID)
                        }
                    }
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                }

                Button {
                    // Recording a reply must not lose your place.
                    saveCurrentProgress()
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

/// Pinned at the top of a thread with a backlog. Generated on device from the
/// transcripts already sitting on the phone.
struct CatchUpCard: View {
    let talk: Talk
    var playAll: () -> Void

    private var minutes: Int { max(1, Int((talk.unreadDuration / 60).rounded())) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("CATCH UP")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Palette.secondaryText)
                Text("^[\(talk.unreadCount) new take](inflect: true), about ^[\(minutes) minute](inflect: true)")
                    .font(.subheadline.weight(.semibold))
                if let line = talk.messages.first(where: { !$0.watched })?.summaryLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button(action: playAll) {
                Label("Play all", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.glass)
        }
        .contentCard()
    }
}

/// A watched or secondary message. Compact by design: the hero is where the
/// video gets to be big.
struct MessageRow: View {
    let message: Message
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                TakeThumbnail(message: message, size: .large)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(message.author.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(relativeLabel(message.sentAt))
                            .font(.caption2)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    Text(message.summaryLine)
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(timecode(message.duration)) \(message.watched ? "watched" : "new")")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Palette.secondaryText)
                        ForEach(message.reactions, id: \.self) { Text($0).font(.caption2) }
                    }
                }
            }
            .contentCard(padding: 12, radius: Scale.Radius.card)
            .opacity(message.watched ? 0.72 : 1)
        }
        .buttonStyle(.plain)
    }
}

/// One take in the thread timeline, using the same thumbnail as everywhere
/// else so the strip and the rows read as the same objects.
struct TimelineChip: View {
    let message: Message
    let isPlaying: Bool

    var body: some View {
        TakeThumbnail(message: message, size: .small, isActive: isPlaying, showsDuration: false)
    }
}
