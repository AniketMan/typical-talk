import AVKit
import SwiftUI

/// The take you are watching. Nothing is drawn over the video: tap it to play
/// or pause, and the scrubber, speed and bookmark sit underneath where there
/// is room for them. The sender and time live in the navigation subtitle.
struct TakePlayerView: View {
    let message: Message
    let talkID: Talk.ID
    @Bindable var player: ThreadPlayer
    @Binding var autoplayOnLoad: Bool
    @Binding var showTranscript: Bool
    @Environment(AppStore.self) private var store

    /// A brief glyph after a tap, so the tap is acknowledged without leaving
    /// anything sitting on top of the picture.
    @State private var tapFeedback: String?
    @State private var feedbackTask: Task<Void, Never>?

    private var length: Double {
        player.duration > 0 ? player.duration : message.duration
    }

    private var activeChapter: Chapter? {
        message.chapters.last { $0.start <= player.currentTime }
    }

    var body: some View {
        VStack(spacing: 0) {
            video
            controls
        }
        .task(id: message.id) { await start() }
        .onChange(of: player.currentTime) { _, now in
            guard player.isPlaying else { return }
            store.saveProgress(now, for: message.id, duration: length)
        }
        .onDisappear { feedbackTask?.cancel() }
    }

    // MARK: - Video

    private var video: some View {
        ZStack {
            Color.black
            media
            if let tapFeedback {
                Image(systemName: tapFeedback)
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .padding(22)
                    .background(.black.opacity(0.35), in: .circle)
                    .transition(.opacity.combined(with: .scale(scale: 1.25)))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onTapGesture { togglePlayback() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    @ViewBuilder
    private var media: some View {
        if let avPlayer = player.player {
            // Aspect fit, so the take is always shown at its real shape.
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

    // MARK: - Controls, underneath

    private var controls: some View {
        VStack(spacing: 10) {
            scrubber
            HStack(spacing: 10) {
                SpeedSlider(rate: Binding(
                    get: { Double(player.rate) },
                    set: { player.setRate(Float($0)) }
                ))

                Button {
                    withAnimation(.snappy(duration: 0.28)) { showTranscript.toggle() }
                } label: {
                    Image(systemName: showTranscript ? "captions.bubble.fill" : "captions.bubble")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(showTranscript ? "Hide transcript" : "Show transcript")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            HStack {
                Text(timecode(player.currentTime))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                Spacer()
                if let activeChapter {
                    Text(activeChapter.title)
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                    Spacer()
                }
                Text(timecode(length))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Palette.secondaryText)
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                let progress = length > 0 ? min(1, player.currentTime / length) : 0

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(Palette.record).frame(width: width * progress)

                    ForEach(message.chapters.dropFirst()) { chapter in
                        Capsule()
                            .fill(Palette.canvas.opacity(0.7))
                            .frame(width: 2)
                            .offset(x: width * (length > 0 ? chapter.start / length : 0))
                    }

                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(radius: 2)
                        .offset(x: max(0, width * progress - 7))
                }
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.hasMedia, width > 0 else { return }
                            player.seek(to: length * Double(max(0, min(1, value.location.x / width))))
                        }
                )
            }
            .frame(height: 16)
        }
    }

    // MARK: - Behaviour

    private func togglePlayback() {
        guard player.hasMedia else { return }
        player.togglePlay()
        show(player.isPlaying ? "play.fill" : "pause.fill")
    }

    private func show(_ symbol: String) {
        feedbackTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { tapFeedback = symbol }
        feedbackTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { tapFeedback = nil }
        }
    }

    private func start() async {
        // The resume point goes through load() because seeking a player whose
        // item is not ready yet is silently dropped.
        player.load(message.localVideoURL, resumingAt: store.resumePosition(for: message.id))
        store.markWatched(messageID: message.id, in: talkID)

        if player.hasMedia, !player.isPlaying, autoplayOnLoad || store.autoplayNewTakes {
            player.togglePlay()
        }
        autoplayOnLoad = false
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
                        .padding(.vertical, 8)
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
