import Observation

/// Tracks which thread is open so the reply action can appear beside the tab
/// bar, and disappear when you leave.
@MainActor
@Observable
final class ThreadContext {
    static let shared = ThreadContext()
    var openTalk: Talk.ID?
    /// True while a take is playing. Heavy background work (transcription)
    /// waits for this to be false, because it competes with playback for the
    /// same processors.
    var isPlaying = false
    /// Bumped by the reply button so the open thread starts recording.
    private(set) var replyRequests = 0

    func requestReply() { replyRequests += 1 }
}
