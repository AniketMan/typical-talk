import AVKit
import SwiftUI

/// One row in the Talks list. Video is visually primary: a large 16:9 preview,
/// never a thumbnail, with the transcript line underneath.
/// One row in the Talks list. Deliberately compact so a long list stays
/// scannable: the big cinematic treatment belongs in the thread, not here.
/// A small thumbnail stands in for the newest take.
struct TalkCard: View {
    let talk: Talk

    var body: some View {
        HStack(spacing: 12) {
            Monogram(text: talk.initials, size: Scale.Avatar.medium)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(talk.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if talk.hasUnread {
                        Circle().fill(Palette.record).frame(width: 7, height: 7)
                    }
                    Spacer(minLength: 4)
                    if let latest = talk.latest {
                        Text(relativeLabel(latest.sentAt))
                            .font(.caption2)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }

                if let status = talk.statusLine {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(talk.hasUnread ? Palette.record : Palette.secondaryText)
                        .lineLimit(1)
                }

                if let latest = talk.latest {
                    Text(latest.summaryLine)
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }

            thumbnail
        }
        .contentCard(padding: 10, radius: Scale.Radius.card)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let latest = talk.latest {
            TakeThumbnail(message: latest, size: .medium)
        }
    }
}

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
