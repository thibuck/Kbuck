import SwiftUI
import AuthenticationServices
import CryptoKit
import Supabase

struct LoginView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var currentNonce: String = ""
    @State private var authError: String?
    @State private var acceptedTerms: Bool = false
    @State private var showTerms: Bool = false
    @State private var hasOpenedTerms: Bool = false
    @AppStorage("hpdUserBanned") private var isUserBanned: Bool = false

    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // MARK: - Logo & Header
                VStack(spacing: 16) {
                    Image("icontx")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: Color.primary.opacity(0.15), radius: 20, x: 0, y: 10)

                    VStack(spacing: 8) {
                        Text("HPD AUCTION")
                            .font(.system(size: 32, weight: .heavy, design: .default))
                            .tracking(1.2)

                        Text("Public Records Aggregator")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .tracking(0.4)
                    }
                }
                .padding(.bottom, 48)

                // MARK: - Ban Notice
                if isUserBanned {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Account Suspended")
                                .font(.headline)
                                .foregroundStyle(.red)
                            Text("Please contact the administrator at abubick@bubickcompany.com")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.red.opacity(0.2), lineWidth: 1))
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // MARK: - Interactive Elements
                VStack(spacing: 24) {
                    // Terms Toggle
                    HStack(spacing: 12) {
                        Button {
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                acceptedTerms.toggle()
                            }
                        } label: {
                            Image(systemName: acceptedTerms ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(acceptedTerms ? Color.accentColor : (hasOpenedTerms ? Color.secondary : Color.secondary.opacity(0.4)))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasOpenedTerms)

                        HStack(spacing: 4) {
                            Text("I agree to the")
                                .foregroundStyle(.secondary)
                            Button("Terms & Conditions") {
                                hasOpenedTerms = true
                                showTerms = true
                            }
                            .foregroundStyle(Color.accentColor)
                            .fontWeight(.medium)
                        }
                        .font(.subheadline)
                    }

                    // Apple Auth
                    SignInWithAppleButton(
                        .signIn,
                        onRequest: { request in
                            let nonce = randomNonceString()
                            currentNonce = nonce
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = sha256(nonce)
                        },
                        onCompletion: { result in
                            switch result {
                            case .success(let authorization):
                                guard
                                    let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                                    let tokenData = credential.identityToken,
                                    let identityToken = String(data: tokenData, encoding: .utf8)
                                else {
                                    authError = "Apple identity token extraction failed."
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
                                    } catch {
                                        authError = error.localizedDescription
                                    }
                                }

                            case .failure(let error):
                                let asError = error as? ASAuthorizationError
                                if asError?.code != .canceled {
                                    authError = error.localizedDescription
                                }
                            }
                        }
                    )
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 32)
                    .disabled(!acceptedTerms || isUserBanned)
                    .opacity(acceptedTerms && !isUserBanned ? 1.0 : 0.4)
                    .allowsHitTesting(acceptedTerms && !isUserBanned)
                    .animation(.easeInOut(duration: 0.2), value: acceptedTerms)
                    .animation(.easeInOut(duration: 0.2), value: isUserBanned)
                }

                // MARK: - Error Handling
                if let err = authError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 16)
                        .transition(.opacity)
                }

#if DEBUG
                // ── TEMPORARY DEV BACKDOOR ───────────────
                Button("Login as Test User") {
                    Task {
                        do {
                            try await supabase.auth.signIn(
                                email: "test@kbuck.com",
                                password: "Kbuck123456"
                            )
                        } catch {
                            authError = error.localizedDescription
                        }
                    }
                }
                .tint(.red)
                .buttonStyle(.bordered)
                .padding(.top, 24)
#endif

                Spacer()

                Text("Bubick Company LLC v\(Bundle.main.appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $showTerms) {
            LegalTermsView()
        }
    }

    // MARK: - Nonce helpers

    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes) == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}

#Preview {
    LoginView()
}
