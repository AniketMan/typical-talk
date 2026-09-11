import AVKit
import SwiftUI

/// One row in the Talks list. Video is visually primary: a large 16:9 preview,
/// never a thumbnail, with the transcript line underneath.
struct TalkCard: View {
    let talk: Talk

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            head
            preview
            if let latest = talk.latest {
                Text(latest.summaryLine)
                    .font(.subheadline)
                    .foregroundStyle(latest.watched ? Palette.secondaryText : .white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .contentCard()
    }

    private var head: some View {
        HStack(spacing: 12) {
            Monogram(text: talk.initials, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(talk.title)
                        .font(.headline)
                    if talk.hasUnread {
                        Circle().fill(Palette.unread).frame(width: 8, height: 8)
                    }
                }
                if let presence = talk.presenceLine {
                    HStack(spacing: 6) {
                        Circle().fill(Palette.presence).frame(width: 6, height: 6)
                        Text(presence)
                            .font(.caption2)
                            .foregroundStyle(Palette.presence)
                    }
                } else if let latest = talk.latest, latest.watched {
                    Text("Seen \(relativeLabel(latest.sentAt).lowercased())")
                        .font(.caption2)
                        .foregroundStyle(Palette.secondaryText)
                }
            }

            Spacer(minLength: 6)

            if let latest = talk.latest {
                Text(relativeLabel(latest.sentAt))
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            if let latest = talk.latest, let url = latest.localVideoURL {
                VideoPoster(url: url)
            } else {
                LinearGradient(
                    colors: [Color.white.opacity(0.07), Color.black.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(alignment: .topLeading) {
                    Image(systemName: talk.latest?.isVoiceOnly == true ? "waveform" : "video")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                        .padding(12)
                }
            }

            // Clear glass over media, with a dimming scrim so the glyph stays
            // legible. This is the only place clear glass is allowed.
            Image(systemName: "play.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(.black.opacity(0.28), in: .circle)
                .glassEffect(.clear, in: .circle)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let latest = talk.latest {
                Text(timecode(latest.duration))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: .capsule)
                    .padding(10)
            }
        }
        .overlay(alignment: .bottom) { chapterTrack }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.5)
        )
    }

    /// Chapter segments drawn straight onto the preview, so the shape of the
    /// message is readable before you open it.
    @ViewBuilder
    private var chapterTrack: some View {
        if let latest = talk.latest, !latest.chapters.isEmpty {
            HStack(spacing: 2) {
                ForEach(latest.chapters) { chapter in
                    Capsule()
                        .fill(.white.opacity(latest.watched ? 0.85 : 0.35))
                        .frame(height: 3)
                        .accessibilityLabel(chapter.title)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }
}

/// Initials disc. Stands in for a profile photo until the user sets one.
struct Monogram: View {
    let text: String
    var size: CGFloat = 44

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(.white.opacity(0.86))
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: .circle
            )
            .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 0.5))
    }
}

/// A still first frame of a locally recorded take, used as the list preview.
struct VideoPoster: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
        }
        .task(id: url) { image = await Self.firstFrame(of: url) }
    }

    static func firstFrame(of url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
