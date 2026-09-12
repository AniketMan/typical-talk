import AVKit
import SwiftUI

/// The take you are watching. Controls sit over the video and get out of the
/// way while it plays, the way every video player does. Tap the video to bring
/// them back.
struct TakePlayerView: View {
    let message: Message
    let talkID: Talk.ID
    @Bindable var player: ThreadPlayer
    @Binding var autoplayOnLoad: Bool
    @Environment(AppStore.self) private var store

    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?

    private var length: Double {
        player.duration > 0 ? player.duration : message.duration
    }

    private var activeChapter: Chapter? {
        message.chapters.last { $0.start <= player.currentTime }
    }

    var body: some View {
        ZStack {
            Color.black
            media
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { controls }
        .contentShape(.rect)
        .onTapGesture { toggleChrome() }
        .task(id: message.id) { await start() }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { scheduleHide() } else { reveal() }
        }
        .onChange(of: player.currentTime) { _, now in
            guard player.isPlaying else { return }
            store.saveProgress(now, for: message.id, duration: length)
        }
        .onDisappear {
            hideTask?.cancel()
            store.saveProgress(player.currentTime, for: message.id, duration: length)
        }
    }

    @ViewBuilder
    private var media: some View {
        if let avPlayer = player.player {
            VideoPlayer(player: avPlayer)
                .disabled(true)
        } else if message.isVoiceOnly {
            WaveformPlaceholder()
        } else {
            VStack(spacing: 10) {
                Image(systemName: "video.slash").font(.title2)
                Text("This take is not stored on this device")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Palette.secondaryText)
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Monogram(text: message.author.initials, size: Scale.Avatar.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.author.name).font(.caption.weight(.semibold))
                    Text(relativeLabel(message.sentAt))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassEffect(.clear, in: .capsule)

            Spacer()

            if let activeChapter {
                Text(activeChapter.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.clear, in: .capsule)
            }
        }
        .padding(12)
        .opacity(chromeVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        .allowsHitTesting(chromeVisible)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 10) {
                scrubber
                transport
            }
            .padding(12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Scale.Radius.card, style: .continuous))
            .padding(12)
        }
        .opacity(chromeVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        .allowsHitTesting(chromeVisible)
    }

    private var scrubber: some View {
        VStack(spacing: 5) {
            HStack {
                Text(timecode(player.currentTime))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                Spacer()
                Text(timecode(length))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                let progress = length > 0 ? min(1, player.currentTime / length) : 0

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(Palette.record).frame(width: width * progress)

                    ForEach(message.chapters.dropFirst()) { chapter in
                        Capsule()
                            .fill(.black.opacity(0.55))
                            .frame(width: 2)
                            .offset(x: width * (length > 0 ? chapter.start / length : 0))
                    }

                    Circle()
                        .fill(.white)
                        .frame(width: 13, height: 13)
                        .shadow(radius: 2)
                        .offset(x: max(0, width * progress - 6.5))
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.hasMedia, width > 0 else { return }
                            reveal()
                            player.seek(to: length * Double(max(0, min(1, value.location.x / width))))
                        }
                        .onEnded { _ in if player.isPlaying { scheduleHide() } }
                )
            }
            .frame(height: 14)
        }
    }

    private var transport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .disabled(!player.hasMedia)

                Spacer()

                Button {
                    store.addBookmark(at: player.currentTime, messageID: message.id, in: talkID)
                    reveal()
                } label: {
                    Image(systemName: message.bookmarkedAt.isEmpty ? "bookmark" : "bookmark.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .disabled(!player.hasMedia)
            }

            SpeedSlider(rate: Binding(
                get: { Double(player.rate) },
                set: { player.setRate(Float($0)); reveal() }
            ))
        }
    }

    // MARK: - Behaviour

    private func start() async {
        player.load(message.localVideoURL)
        store.markWatched(messageID: message.id, in: talkID)

        // Pick up exactly where this take was left off.
        let resume = store.resumePosition(for: message.id)
        if resume > 0 { player.seek(to: resume) }

        if player.hasMedia, !player.isPlaying, autoplayOnLoad || store.autoplayNewTakes {
            player.togglePlay()
        }
        autoplayOnLoad = false
        reveal()
    }

    private func toggleChrome() {
        if chromeVisible && player.isPlaying {
            withAnimation { chromeVisible = false }
            hideTask?.cancel()
        } else {
            reveal()
        }
    }

    /// Shows the controls, and starts the countdown again if it is playing.
    private func reveal() {
        withAnimation { chromeVisible = true }
        if player.isPlaying { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, player.isPlaying else { return }
            withAnimation { chromeVisible = false }
        }
    }
}

/// 0.75x to 2x with detents. 1x is the neutral value.
struct SpeedSlider: View {
    @Binding var rate: Double
    private let steps: [Double] = [0.75, 1.0, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(steps, id: \.self) { step in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { rate = step }
                } label: {
                    Text(step == 1.0 ? "1x" : "\(step.formatted(.number.precision(.fractionLength(0...2))))x")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(abs(rate - step) < 0.01 ? .white : .white.opacity(0.72))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if abs(rate - step) < 0.01 { Capsule().fill(Palette.record) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.1), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback speed")
        .accessibilityValue("\(rate.formatted())x")
    }
}

/// Stand-in art for a voice-only Talk.
struct WaveformPlaceholder: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<24, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: 3, height: 14 + CGFloat((index * 37) % 52))
            }
        }
    }
}
