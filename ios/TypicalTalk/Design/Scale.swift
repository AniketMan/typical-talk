import SwiftUI

/// The two scales every surface draws from. Before this existed the app had
/// seven avatar sizes and eight corner radii, which is why the same screen
/// felt slightly different depending on how you arrived at it.
enum Scale {
    /// Avatars are circles and only ever represent a person.
    enum Avatar {
        static let small: CGFloat = 28
        static let medium: CGFloat = 40
        static let large: CGFloat = 56
        static let profile: CGFloat = 64
    }

    /// Corner radii, smallest nested inside largest.
    enum Radius {
        static let thumbnail: CGFloat = 12
        static let control: CGFloat = 16
        static let card: CGFloat = 20
        static let hero: CGFloat = 28
    }

    /// The smallest type the app will draw. Anything below this is unreadable
    /// on a phone held at arm's length.
    static let minimumCaption: CGFloat = 11
}

/// A take, drawn the same way everywhere: a square still frame, never a
/// circle, because a circle reads as a person and this is a video.
struct TakeThumbnail: View {
    let message: Message
    var size: Size = .medium
    var isActive: Bool = false
    var showsDuration: Bool = true

    enum Size {
        case small, medium, large

        var side: CGFloat {
            switch self {
            case .small: 46
            case .medium: 56
            case .large: 72
            }
        }
    }

    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            if let poster {
                Image(uiImage: poster).resizable().scaledToFill()
            } else {
                Palette.canvas
            }
            Image(systemName: message.isVoiceOnly ? "waveform" : "play.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.92))
                .shadow(radius: 2)
        }
        .frame(width: size.side, height: size.side)
        .clipShape(RoundedRectangle(cornerRadius: Scale.Radius.thumbnail, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Scale.Radius.thumbnail, style: .continuous)
                .strokeBorder(isActive ? Palette.record : Palette.hairline,
                              lineWidth: isActive ? 2 : 0.5)
        )
        .overlay(alignment: .bottomTrailing) {
            if showsDuration, size != .small {
                Text(timecode(message.duration))
                    .font(.system(size: Scale.minimumCaption).monospacedDigit())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.7), in: .capsule)
                    .padding(3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !message.watched && !message.author.isYou {
                Circle()
                    .fill(Palette.record)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Palette.canvas, lineWidth: 1.5))
                    .padding(3)
            }
        }
        .task(id: message.id) {
            if let url = message.localVideoURL {
                poster = await VideoPoster.firstFrame(of: url)
            }
        }
        .accessibilityLabel("\(message.author.name), \(timecode(message.duration))\(message.watched ? ", watched" : ", new")")
    }
}
