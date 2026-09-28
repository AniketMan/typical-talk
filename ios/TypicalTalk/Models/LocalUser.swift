import Foundation

/// You, as the author of your own takes.
///
/// This replaced the bundled sample conversations. Shipping those meant every
/// tester opened the app to someone else's recordings.
enum LocalUser {
    static let you = Person(name: "You", isYou: true)
}
