import SwiftUI

/// Smarter TV: Smarter Tube's cable-TV mode, remade for the iPad.
@main
struct SmarterTVApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .persistentSystemOverlays(.hidden)
                .statusBarHidden(true)
        }
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("SMARTER TV")
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.47, green: 1.0, blue: 0.59))
        }
    }
}
