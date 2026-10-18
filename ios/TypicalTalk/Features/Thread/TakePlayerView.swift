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
        // Runs again when the file arrives, so a take that was still
        // downloading when it was selected starts as soon as it lands.
        .task(id: "\(message.id.uuidString)-\(message.fileName ?? "")") { await start() }
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
            PlayerSurface(player: avPlayer)
                .opacity(player.isSettled ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: player.isSettled)
                .allowsHitTesting(false)
        } else if message.fileName == nil {
            downloading
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

    /// The take is on the server and on its way here.
    private var downloading: some View {
        VStack(spacing: 12) {
            if let fraction = store.downloadProgress[message.id] {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Palette.record)
                    .frame(width: 140)
                Text("Downloading").font(.caption)
            } else {
                Image(systemName: "icloud.and.arrow.down").font(.title2)
                Text(store.lastSyncFailed ? "Waiting for a connection" : "Getting this take")
                    .font(.caption)
                Button("Try again") { store.retryDownload(message.id) }
                    .buttonStyle(.glass)
                    .font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(Palette.secondaryText)
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
                    // On: the whole button fills red and the icon turns white,
                    // rather than only the tiny symbol filling in.
                    Image(systemName: "captions.bubble")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(showTranscript ? .white : Palette.record)
                        .frame(width: 38, height: 38)
                        .background {
                            if showTranscript {
                                Circle().fill(Palette.record)
                            }
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(showTranscript ? .identity : .regular.interactive(), in: .circle)
                .animation(.snappy(duration: 0.2), value: showTranscript)
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

            // The system slider: a Liquid Glass knob that lifts as you drag
            // it, sized for a thumb, with chapters as tick marks.
            Slider(
                value: Binding(
                    get: { min(player.currentTime, max(length, 0.01)) },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(length, 0.01),
                label: { Text("Position") },
                ticks: {
                    SliderTickContentForEach(message.chapters.dropFirst().map(\.start), id: \.self) { start in
                        SliderTick(start)
                    }
                }
            )
            .disabled(!player.hasMedia)
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
        // Only a take that is on the phone can have been watched.
        if message.fileName != nil { store.markWatched(messageID: message.id, in: talkID) }

        if player.hasMedia, !player.isPlaying, autoplayOnLoad || store.autoplayNewTakes {
            player.togglePlay()
        }
        autoplayOnLoad = false
    }
}

/// 0.75x to 2x on the system segmented control, so sliding across it behaves
/// exactly like every other segmented control. 1x is the neutral value.
struct SpeedSlider: View {
    @Binding var rate: Double
    private let steps: [Double] = [0.75, 1.0, 1.5, 2.0]

    var body: some View {
        Picker("Playback speed", selection: Binding(
            get: { steps.min { abs($0 - rate) < abs($1 - rate) } ?? 1 },
            set: { rate = $0 }
        )) {
            ForEach(steps, id: \.self) { step in
                Text(step == 1 ? "1x" : "\(step.formatted(.number.precision(.fractionLength(0...2))))x")
                    .tag(step)
            }
        }
        .pickerStyle(.segmented)
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
