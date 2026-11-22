import SwiftUI

/// Smarter TV: Smarter Tube's cable-TV mode, remade for the iPad.
@main
struct SmarterTVApp: App {
    @StateObject private var auth = AuthModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if case .signedIn = auth.state {
                    TVModeView(auth: auth) // signed in: the set switches straight on
                } else {
                    SignInView(auth: auth)
                }
            }
            .persistentSystemOverlays(.hidden)
            .statusBarHidden(true)
            .preferredColorScheme(.dark)
        }
    }
}
