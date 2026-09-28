import SwiftUI

@main
struct TypicalTalkApp: App {
    @State private var store = AppStore()
    @State private var account = AccountStore()
    @State private var inviteResult: String?

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
                Task { inviteResult = await account.redeem(inviteCode: code) }
            }
            .alert("Invite", isPresented: .constant(inviteResult != nil)) {
                Button("OK") { inviteResult = nil }
            } message: {
                Text(inviteResult ?? "")
            }
            .task { await account.refresh() }
            .environment(account)
            .environment(store)
                // Intents run outside the view tree and need the store.
                .task { IntentBridge.store = store }
                .preferredColorScheme(.dark)
                .tint(Palette.record)
        }
    }
}
