import SwiftUI

/// Smarter TV: Smarter Tube's cable-TV mode, remade for the iPad.
@main
struct SmarterTVApp: App {
    @StateObject private var auth = AuthModel()

    var body: some Scene {
        WindowGroup {
            SignInView(auth: auth) // TV mode comes next; for now the app is its sign-in screen
                .persistentSystemOverlays(.hidden)
                .statusBarHidden(true)
                .preferredColorScheme(.dark)
        }
    }
}
