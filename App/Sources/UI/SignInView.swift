import SwiftUI
import CoreImage.CIFilterBuiltins

/// Keeps track of the YouTube sign-in for the whole app.
@MainActor
final class AuthModel: ObservableObject {
    enum State: Equatable {
        case signedOut
        case fetchingCode
        case showingCode(code: String, url: String)
        case signedIn(name: String?)
        case failed(String)
    }

    @Published var state: State = .signedOut
    @Published var photo: URL?
    private var task: Task<Void, Never>?

    init() {
        if Keychain.load() != nil {
            state = .signedIn(name: nil)
            Task { await loadAccount() }
        }
    }

    func startSignIn() {
        task?.cancel()
        state = .fetchingCode
        task = Task {
            do {
                let client = try await YouTubeAuth.fetchClient()
                let code = try await YouTubeAuth.requestCode(client: client)
                state = .showingCode(code: code.userCode, url: code.verificationUrl ?? "https://www.google.com/device")
                let tokens = try await YouTubeAuth.waitForTokens(client: client, code: code)
                Keychain.save(tokens)
                state = .signedIn(name: nil)
                await loadAccount()
            } catch is CancellationError {
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func signOut() {
        task?.cancel()
        Keychain.delete()
        photo = nil
        state = .signedOut
    }

    private func loadAccount() async {
        guard var tokens = Keychain.load() else { return }
        do {
            let access = try await YouTubeAuth.accessToken(&tokens)
            let info = try await YouTubeAuth.accountInfo(accessToken: access)
            state = .signedIn(name: info.name)
            photo = info.photo
        } catch {
            // still signed in; the name just couldn't be fetched right now
        }
    }
}

/// The sign-in screen, in the TV mode's green on-screen-display style.
struct SignInView: View {
    @ObservedObject var auth: AuthModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                OSDText("SMARTER TV", size: 44)

                switch auth.state {
                case .signedOut:
                    OSDText("SIGN IN WITH YOUR YOUTUBE ACCOUNT", size: 18, dim: true)
                    OSDButton("SIGN IN") { auth.startSignIn() }

                case .fetchingCode:
                    OSDText("GETTING A CODE...", size: 20, dim: true)

                case .showingCode(let code, let url):
                    HStack(alignment: .center, spacing: 48) {
                        VStack(alignment: .leading, spacing: 18) {
                            OSDText("1. ON YOUR PHONE, GO TO", size: 18, dim: true)
                            OSDText(url.replacingOccurrences(of: "https://", with: "")
                                .replacingOccurrences(of: "www.", with: ""), size: 26)
                            OSDText("2. ENTER THIS CODE", size: 18, dim: true)
                            OSDText(code, size: 56)
                            OSDText("WAITING FOR YOU TO CONFIRM...", size: 16, dim: true)
                        }
                        if let qr = QRCode.image(for: url) {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 200, height: 200)
                                .padding(10)
                                .background(Color.osdGreen)
                        }
                    }
                    OSDButton("CANCEL") { auth.signOut() }

                case .signedIn(let name):
                    OSDText("SIGNED IN", size: 20, dim: true)
                    OSDText((name ?? "YOUR ACCOUNT").uppercased(), size: 32)
                    OSDButton("SIGN OUT") { auth.signOut() }

                case .failed(let message):
                    OSDText(message.uppercased(), size: 18)
                    OSDButton("TRY AGAIN") { auth.startSignIn() }
                }
            }
            .padding(40)
            Scanlines().ignoresSafeArea().allowsHitTesting(false)
        }
    }
}

// MARK: - TV-style building blocks

extension Color {
    static let osdGreen = Color(red: 120 / 255, green: 1, blue: 150 / 255)
}

/// Monospaced green text with red/blue colour fringes, like the TV mode's OSD.
struct OSDText: View {
    let text: String
    let size: CGFloat
    var dim = false

    init(_ text: String, size: CGFloat, dim: Bool = false) {
        self.text = text
        self.size = size
        self.dim = dim
    }

    var body: some View {
        let label = Text(text).font(.system(size: size, weight: .bold, design: .monospaced))
        ZStack {
            label.foregroundStyle(Color.red.opacity(0.55)).offset(x: -size * 0.06)
            label.foregroundStyle(Color.blue.opacity(0.55)).offset(x: size * 0.06)
            label.foregroundStyle(Color.osdGreen)
        }
        .opacity(dim ? 0.7 : 1)
        .multilineTextAlignment(.center)
    }
}

struct OSDButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            OSDText(title, size: 22)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .overlay(Rectangle().stroke(Color.osdGreen, lineWidth: 3))
        }
        .buttonStyle(.plain)
    }
}

/// Fine dark lines across the screen.
struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y + 2, width: size.width, height: 1)), with: .color(.black.opacity(0.35)))
                y += 3
            }
        }
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
