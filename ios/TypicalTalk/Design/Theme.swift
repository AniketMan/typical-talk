import SwiftUI

/// The single tinted colour in the app. Per the locked Liquid Glass decision
/// (BRIEF A3), the record action is the only element allowed to carry a tint.
/// Everything else is monochrome on a dark, warm, cinematic ground.
enum Palette {
    static let record = Color(red: 1.0, green: 0.325, blue: 0.435)
    static let canvas = Color(red: 0.031, green: 0.035, blue: 0.047)
    static let raised = Color(red: 0.082, green: 0.086, blue: 0.106)
    static let hairline = Color.white.opacity(0.12)
    static let secondaryText = Color.white.opacity(0.58)
    static let unread = Color(red: 0.0, green: 0.478, blue: 1.0)
    static let presence = Color(red: 0.30, green: 0.87, blue: 0.62)
}

extension View {
    /// Flat content-tier card. Content is never glass; glass lives in the
    /// navigation layer only.
    func contentCard(padding: CGFloat = 14, radius: CGFloat = 22) -> some View {
        self
            .padding(padding)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            )
    }
}

/// A short mm:ss timecode. Used everywhere a duration is shown.
func timecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Relative wording for list rows: "4m ago", "Yesterday".
func relativeLabel(_ date: Date, now: Date = .now) -> String {
    let delta = now.timeIntervalSince(date)
    if delta < 60 { return "Just now" }
    if delta < 3600 { return "\(Int(delta / 60))m ago" }
    if delta < 86_400 { return "\(Int(delta / 3600))h ago" }
    if delta < 172_800 { return "Yesterday" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}
