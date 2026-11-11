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
        Self.registerCategories()
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
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        nonisolated(unsafe) let finish = completionHandler
        Task { @MainActor in
            await IntentBridge.store?.sync()
            finish(.newData)
        }
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

    /// The category on new-take pushes, which adds a Reply action. Reply
    /// opens the app straight into the recorder for that talk.
    static let newTakeCategory = "NEW_TAKE"
    static let replyAction = "REPLY"

    static func registerCategories() {
        let reply = UNNotificationAction(
            identifier: replyAction,
            title: "Reply with a take",
            options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "video.fill")
        )
        let category = UNNotificationCategory(
            identifier: newTakeCategory,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // These use completion handlers on purpose. The async versions hand
    // control back to UIKit from a background thread, and UIKit aborts when
    // that happens: that was the crash when a notification was tapped.

    /// In the foreground a banner is shown, unless you are already looking at
    /// the thread it is about.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let talk = (notification.request.content.userInfo["talkID"] as? String).flatMap(UUID.init(uuidString:))
        nonisolated(unsafe) let finish = completionHandler
        Task { @MainActor in
            let viewing = talk != nil && ThreadContext.shared.openTalk == talk
            finish(viewing ? [] : [.banner, .sound, .badge])
            await IntentBridge.store?.sync()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let talk = (response.notification.request.content.userInfo["talkID"] as? String)
            .flatMap(UUID.init(uuidString:))
        let wantsReply = response.actionIdentifier == Self.replyAction
        nonisolated(unsafe) let finish = completionHandler
        Task { @MainActor in
            // Tell the system straight away, on the main thread, then do the
            // work. Nothing here is allowed to delay or move the completion.
            finish()
            guard let talk else { return }
            // A talk this phone has not heard of yet has to be fetched first.
            if IntentBridge.store?.talk(id: talk) == nil { await IntentBridge.store?.sync() }
            IntentRouter.shared.openTalkID = talk
            if wantsReply { DraftRecorder.shared.open(for: talk) }
        }
    }
}
