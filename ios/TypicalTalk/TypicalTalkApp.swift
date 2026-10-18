import SwiftUI

@main
struct TypicalTalkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore
    @State private var account: AccountStore
    @State private var inviteResult: String?

    init() {
        // Wired here rather than in a view, because the system can launch the
        // app in the background to finish an upload or answer a push, and the
        // store has to be listening by then.
        let account = AccountStore()
        let store = AppStore()
        store.attach(account)
        PushRegistrar.shared.account = account
        IntentBridge.store = store
        _account = State(initialValue: account)
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if account.isSignedIn {
                    RootView()
                } else {
                    SignInView()
                }
            }
            .animation(.snappy(duration: 0.35), value: account.isSignedIn)
            .onOpenURL { url in
                guard url.scheme == "typicaltalk", url.host == "invite" else { return }
                let code = url.lastPathComponent
                Task {
                    inviteResult = await account.redeem(inviteCode: code)
                    await store.sync()
                }
            }
            .alert("Invite", isPresented: .constant(inviteResult != nil)) {
                Button("OK") { inviteResult = nil }
            } message: {
                Text(inviteResult ?? "")
            }
            .task { await account.refresh() }
            .onChange(of: account.isSignedIn) { _, signedIn in
                // Signing out, or an account deleted, leaves nothing behind
                // for the next person to sign in on this phone.
                if signedIn { store.attach(account) } else { store.reset() }
            }
            .onChange(of: account.account?.sessionToken) { _, token in
                // A session has just been made: fetch straight away rather
                // than waiting for the next poll, and tell push about it.
                guard token != nil else { return }
                Task {
                    await store.sync()
                    await PushRegistrar.shared.upload()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: Task { await store.sync() }
                case .background: store.saveNow()
                default: break
                }
            }
            .environment(account)
            .environment(store)
            .preferredColorScheme(.dark)
            .tint(Palette.record)
        }
    }
}
