import SwiftUI

@main
struct TypicalTalkApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                // Intents run outside the view tree and need the store.
                .task { IntentBridge.store = store }
                .preferredColorScheme(.dark)
                .tint(Palette.record)
        }
    }
}
