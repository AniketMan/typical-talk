import AVKit
import SwiftUI

/// The message you are actually watching. Vertical, cinematic, with the glass
/// playback toolbar sitting over the media as one GlassEffectContainer.
struct HeroMessageCard: View {
    let message: Message
    let talkID: Talk.ID
    @Bindable var player: ThreadPlayer
    @Binding var showTranscript: Bool
    @Binding var autoplayOnLoad: Bool
    @Environment(AppStore.self) private var store

    /// Effective duration: the real asset when we have one, the stored length
    /// otherwise, so the scrubber is never lying.
    private var length: Double {
        player.duration > 0 ? player.duration : message.duration
    }

    private var activeChapter: Chapter? {
        message.chapters.last { $0.start <= player.currentTime }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                media
                    .overlay {
                        LinearGradient(
                            colors: [.black.opacity(0.55), .clear, .black.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)
                    }
                    .overlay(alignment: .top) { senderChip }

                toolbar
                    .padding(10)
            }
            // Sized from the viewport rather than a fixed ratio, so the glass
            // toolbar is always on screen on every phone size.
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical) { height, _ in
                min(max(height * 0.66, 380), 560)
            }
            .clipShape(RoundedRectangle(cornerRadius: Scale.Radius.hero, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Scale.Radius.hero, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            )

            if showTranscript {
                transcript
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: message.id) {
            player.load(message.localVideoURL)
            store.markWatched(messageID: message.id, in: talkID)
            // Pick up exactly where this take was left off.
            let resume = store.resumePosition(for: message.id)
            if resume > 0 { player.seek(to: resume) }
            // Play when the user asked for this take, or when they have
            // autoplay switched on.
            if player.hasMedia, !player.isPlaying, autoplayOnLoad || store.autoplayNewTakes {
                player.togglePlay()
            }
            autoplayOnLoad = false
        }
        // Keep the resume point current while it plays, so leaving at any
        // moment comes back to the right second.
        .onChange(of: player.currentTime) { _, now in
            guard player.isPlaying else { return }
            store.saveProgress(now, for: message.id, duration: length)
        }
        .onDisappear {
            store.saveProgress(player.currentTime, for: message.id, duration: length)
        }
    }

    @ViewBuilder
    private var media: some View {
        if let avPlayer = player.player {
            VideoPlayer(player: avPlayer)
                .disabled(true)
                // Tap the video to play or pause, the way every player works.
                .contentShape(.rect)
                .onTapGesture { player.togglePlay() }
        } else if message.isVoiceOnly {
            Palette.raised.overlay { WaveformPlaceholder() }
        } else {
            LinearGradient(
                colors: [Color.white.opacity(0.08), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.title2)
                    Text("This take is not stored on this device")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 30)
            }
        }
    }

    private var senderChip: some View {
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

            Text(timecode(length))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.clear, in: .capsule)
        }
        .padding(10)
    }

    // MARK: - Playback toolbar

    private var toolbar: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 10) {
                scrubber
                controls
            }
            .padding(12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Scale.Radius.card, style: .continuous))
        }
    }

    private var scrubber: some View {
        VStack(spacing: 5) {
            HStack {
                Text(timecode(player.currentTime))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                Spacer()
                if let activeChapter {
                    Text(activeChapter.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer()
                Text(timecode(length))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }

            // Track with chapter ticks. Dragging seeks; tapping a tick jumps.
            GeometryReader { geometry in
                let width = geometry.size.width
                let progress = length > 0 ? min(1, player.currentTime / length) : 0

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white).frame(width: width * progress)

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
                            player.seek(to: length * Double(max(0, min(1, value.location.x / width))))
                        }
                )
            }
            .frame(height: 14)
        }
    }

    private var controls: some View {
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
                    withAnimation(.snappy) { showTranscript.toggle() }
                } label: {
                    Image(systemName: showTranscript ? "captions.bubble.fill" : "captions.bubble")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)

                Button {
                    store.addBookmark(at: player.currentTime, messageID: message.id, in: talkID)
                } label: {
                    Image(systemName: message.bookmarkedAt.isEmpty ? "bookmark" : "bookmark.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .disabled(!player.hasMedia)
            }

            // Speed as a full width row of detents, so 0.75x through 2x all
            // stay legible.
            SpeedSlider(rate: Binding(
                get: { Double(player.rate) },
                set: { player.setRate(Float($0)) }
            ))
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Transcript", systemImage: "text.alignleft")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)

            if message.transcript.isEmpty {
                Text("No transcript for this take yet.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ForEach(message.transcript) { segment in
                    Button {
                        player.seek(to: segment.start)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(timecode(segment.start))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Palette.secondaryText)
                                .frame(width: 38, alignment: .leading)
                            Text(segment.text)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(isActive(segment) ? .white : .white.opacity(0.72))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
        .padding(.top, 10)
    }

    private func isActive(_ segment: TranscriptSegment) -> Bool {
        message.transcript.last { $0.start <= player.currentTime }?.id == segment.id
    }
}

/// 0.75x to 2x with detents. 1x is the neutral value, so the slider snaps back
/// to normal speed without hunting for it.
struct SpeedSlider: View {
    @Binding var rate: Double
    /// 1x is the neutral detent, kept centre-left so the thumb rests there.
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
                            if abs(rate - step) < 0.01 {
                                Capsule().fill(Palette.record)
                            }
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
