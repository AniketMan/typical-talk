import SwiftUI

@main
struct TypicalTalkApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(Palette.record)
        }
    }
}
