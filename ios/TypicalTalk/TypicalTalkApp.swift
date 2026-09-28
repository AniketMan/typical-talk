import SwiftUI

@main
struct TypicalTalkApp: App {
    @State private var store = AppStore()
    @State private var account = AccountStore()

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
