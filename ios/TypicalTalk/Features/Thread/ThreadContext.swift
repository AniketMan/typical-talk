import Observation

/// Tracks which thread is open so the reply action can appear beside the tab
/// bar, and disappear when you leave.
@MainActor
@Observable
final class ThreadContext {
    static let shared = ThreadContext()
    var openTalk: Talk.ID?
    /// Bumped by the reply button so the open thread starts recording.
    private(set) var replyRequests = 0

    func requestReply() { replyRequests += 1 }
}
