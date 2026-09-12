import Observation

/// Lets an intent open a specific thread once the Talks tab is showing.
@MainActor
@Observable
final class TalksNavigation {
    static let shared = TalksNavigation()
    var open: Talk.ID?
}
