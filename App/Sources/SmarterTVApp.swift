import SwiftUI

/// Smarter Tube for the iPad: SmartTube's layout, plus its cable-TV mode.
@main
struct SmarterTVApp: App {
    @StateObject private var auth = AuthModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if case .signedIn = auth.state {
                    MainView(auth: auth)
                } else {
                    SignInView(auth: auth)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
