import SwiftUI
import AuthenticationServices
import CryptoKit
import Supabase

struct LoginView: View {
    @Environment(\.colorScheme) private var colorScheme

    // Raw nonce bridged between onRequest and onCompletion.
    // Both callbacks are dispatched on the main actor, so @State is safe.
    @State private var currentNonce: String = ""
    @State private var authError: String?
    @State private var acceptedTerms: Bool = false
    @State private var showTerms: Bool = false
    @AppStorage("hpdUserBanned") private var isUserBanned: Bool = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image("otro")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20))

            Text("HDP AUCTION")
                .font(.largeTitle.bold())

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    acceptedTerms.toggle()
                } label: {
                    Image(systemName: acceptedTerms ? "checkmark.square.fill" : "square")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Text("I have read and agree to the")
                    .font(.footnote)

                Button("Terms & Conditions") {
                    showTerms = true
                }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            .padding(.horizontal, 40)

            SignInWithAppleButton(
                .signIn,
                onRequest: { request in
                    let nonce    = randomNonceString()
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = sha256(nonce)   // hashed nonce sent to Apple
                },
                onCompletion: { result in
                    switch result {
                    case .success(let authorization):
                        guard
                            let credential    = authorization.credential as? ASAuthorizationAppleIDCredential,
                            let tokenData     = credential.identityToken,
                            let identityToken = String(data: tokenData, encoding: .utf8)
                        else {
                            authError = "No se pudo extraer el identity token de Apple."
                            return
                        }
                        let nonce = currentNonce
                        Task {
                            do {
                                try await supabase.auth.signInWithIdToken(
                                    credentials: OpenIDConnectCredentials(
                                        provider: .apple,
                                        idToken: identityToken,
                                        nonce: nonce
                                    )
                                )
                                // ContentView's authStateChanges stream picks up .signedIn
                                // and switches to HPDView automatically — no extra state needed here.
                            } catch {
                                authError = error.localizedDescription
                                print("🔴 Supabase Sign-In error: \(error.localizedDescription)")
                            }
                        }

                    case .failure(let error):
                        // ASAuthorizationError.canceled (code 1001) means the user dismissed the sheet.
                        let asError = error as? ASAuthorizationError
                        if asError?.code != .canceled {
                            authError = error.localizedDescription
                        }
                        print("🔴 Apple Sign-In error: \(error.localizedDescription)")
                    }
                }
            )
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .padding(.horizontal, 40)
            .disabled(!acceptedTerms || isUserBanned)
            .opacity(acceptedTerms && !isUserBanned ? 1.0 : 0.5)
            .allowsHitTesting(acceptedTerms && !isUserBanned)

            if isUserBanned {
                VStack(spacing: 6) {
                    Image(systemName: "nosign").font(.title).foregroundStyle(.red)
                    Text("Account Suspended").font(.headline).foregroundStyle(.red)
                    Text("Please contact the administrator at\nabubick@bubickcompany.com")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 40)
            }

            if let err = authError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

#if DEBUG
            // ── TEMPORARY DEV BACKDOOR — remove before release ───────────────
            Button("Login as Test User") {
                Task {
                    do {
                        try await supabase.auth.signIn(
                            email: "test@kbuck.com",
                            password: "Kbuck123456"
                        )
                        print("🟢 TEST LOGIN SUCCESS")
                    } catch {
                        print("🔴 TEST LOGIN ERROR: \(error.localizedDescription)")
                        print("🔴 FULL ERROR: \(String(describing: error))")
                    }
                }
            }
            .tint(.red)
            .buttonStyle(.bordered)
            // ─────────────────────────────────────────────────────────────────
#endif

            Spacer().frame(height: 48)
        }
        .sheet(isPresented: $showTerms) {
            LegalTermsView()
        }
    }

    // MARK: - Nonce helpers

    /// Generates a cryptographically random nonce string (URL-safe charset).
    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes) == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed")
        }
        let charset: [Character] = Array(
            "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._"
        )
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    /// Returns the lowercase hex-encoded SHA-256 hash of a string.
    private func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}

#Preview {
    LoginView()
}
