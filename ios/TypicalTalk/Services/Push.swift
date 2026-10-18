import SwiftUI
import UIKit
import UserNotifications

/// Registers this phone for push and keeps the server's copy of the device
/// token current.
@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()

    private(set) var deviceToken: String?
    weak var account: AccountStore?

    /// Whether this build was signed for Apple's sandbox or production push
    /// servers. TestFlight and App Store builds carry no embedded profile and
    /// use production; a build installed from Xcode carries one that says.
    static var environment: String {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "aps-environment</key>") else { return "production" }
        // The value follows the key, whatever whitespace the profile uses.
        return text[key.upperBound...].prefix(60).contains("development") ? "sandbox" : "production"
    }

    /// Asks for permission the first time, then registers with Apple.
    func enable() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    func didRegister(deviceToken data: Data) async {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        await upload()
    }

    /// Tells the server about the token. Safe to call whenever either half
    /// (the token, the session) turns up.
    func upload() async {
        guard let deviceToken, let session = account?.account?.sessionToken else { return }
        try? await TalkAPI.registerDevice(token: deviceToken, environment: Self.environment, token: session)
    }

    /// Stops pushes to this phone, for the toggle and for signing out.
    func unregister(sessionToken: String) async {
        if let deviceToken {
            try? await TalkAPI.unregisterDevice(token: deviceToken, token: sessionToken)
        }
    }

    func disable() async {
        if let session = account?.account?.sessionToken { await unregister(sessionToken: session) }
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    /// The number on the app icon: takes waiting to be watched.
    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }
}

/// UIKit's side of the app, which SwiftUI has no equivalent for: the push
/// token, a notification being tapped, and background transfers finishing.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await PushRegistrar.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Simulators and builds without the push entitlement land here. The
        // app works without push; it just learns about takes when opened.
    }

    /// A push with `content-available` wakes the app briefly: fetch the take
    /// now so it is already on the phone when the notification is opened.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await IntentBridge.store?.sync()
        return .newData
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // The system's handler is only ever called once, from the main queue.
        nonisolated(unsafe) let handler = completionHandler
        TransferManager.shared.setBackgroundCompletion { handler() }
    }

    // MARK: - Notifications

    /// In the foreground a banner is shown, unless you are already looking at
    /// the thread it is about.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let talk = (notification.request.content.userInfo["talkID"] as? String).flatMap(UUID.init(uuidString:))
        let viewing = await MainActor.run { talk != nil && ThreadContext.shared.openTalk == talk }
        await IntentBridge.store?.sync()
        return viewing ? [] : [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let id = (response.notification.request.content.userInfo["talkID"] as? String)
            .flatMap(UUID.init(uuidString:)) else { return }
        // A talk this phone has not heard of yet has to be fetched before it
        // can be opened.
        await IntentBridge.store?.sync()
        await MainActor.run { IntentRouter.shared.openTalkID = id }
    }
}
