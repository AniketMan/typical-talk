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
    /// Set when you stopped partway: shows a progress ring so it reads as
    /// "resume" and not "play".
    var resumeFraction: Double?

    enum Size {
        case small, medium, large
        /// The row of takes along the bottom of a thread, sized for a thumb.
        case strip

        var side: CGFloat {
            switch self {
            case .small: 46
            case .strip: 64
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
            if let resumeFraction {
                ResumeRing(fraction: resumeFraction, size: size == .strip ? 46 : 28)
            } else {
                Image(systemName: message.isVoiceOnly ? "waveform" : "play.fill")
                    .font(size == .strip ? .footnote : .caption2)
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 2)
            }
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
        .overlay {
            // Still on its way to the phone, or from it.
            if message.fileName == nil && message.delivery == .sent {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            if message.author.isYou, message.delivery == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, Palette.record)
                    .padding(3)
            } else if message.author.isYou, message.delivery == .sending {
                ProgressView().controlSize(.mini).tint(.white).padding(4)
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
        .task(id: "\(message.id.uuidString)-\(message.fileName ?? "")") {
            if let url = message.localVideoURL {
                poster = await VideoPoster.firstFrame(of: url)
            }
        }
        .accessibilityLabel("\(message.author.name), \(timecode(message.duration))\(resumeFraction != nil ? ", resumes where you left off" : (message.watched ? ", watched" : ", new"))")
    }
}


/// A play triangle inside a ring that fills as far as you got, so a take you
/// stopped partway does not look like one you have not started.
struct ResumeRing: View {
    let fraction: Double
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.45))
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: size * 0.1)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Palette.record, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(size * 0.05)
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.38))
                .foregroundStyle(.white)
                .offset(x: size * 0.02)
        }
        .frame(width: size, height: size)
    }
}
