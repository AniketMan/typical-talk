import Foundation
import Security
import WidgetKit

/// Keeps the home screen widget current.
///
/// The widget fetches who is waiting from the server itself, using a copy of
/// the session kept in a Keychain group both targets can read. This only
/// writes that copy and asks the widget to refresh when the unread count
/// changes.
enum WidgetSnapshot {
    static let service = "com.typicaltalk.widget"
    static let accessGroup = "5BF427L96N.com.typicaltalk.TypicalTalk.shared"

    struct Credentials: Codable, Equatable {
        var token: String
        var userID: String
        var apiBase: String
    }

    @MainActor private static var lastCredentials: Credentials?
    @MainActor private static var lastUnread: Int?

    @MainActor
    static func publish(_ talks: [Talk], token: String? = nil, userID: String? = nil) {
        if let token, let userID {
            let credentials = Credentials(token: token, userID: userID, apiBase: TalkAPI.base.absoluteString)
            if credentials != lastCredentials {
                write(credentials)
                lastCredentials = credentials
            }
        }
        let unread = talks.reduce(0) { $0 + $1.unreadCount }
        guard unread != lastUnread else { return }
        lastUnread = unread
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Sign out: the widget must not keep asking as someone who left.
    @MainActor
    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup
        ]
        SecItemDelete(query as CFDictionary)
        lastCredentials = nil
        lastUnread = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func write(_ credentials: Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup
        ]
        SecItemDelete(match as CFDictionary)
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
