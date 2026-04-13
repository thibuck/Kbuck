import SwiftUI
import WebKit

struct StatVinBrowserView: View {
    let initialURL: URL
    let onResolvedURL: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentURL: URL?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                StatVinWebView(
                    initialURL: initialURL,
                    currentURL: $currentURL,
                    isLoading: $isLoading,
                    onResolvedURL: onResolvedURL
                )
                .ignoresSafeArea()

                if isLoading {
                    ProgressView("Loading stat.vin...")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                }
            }
            .navigationTitle("stat.vin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let currentURL {
                            UIApplication.shared.open(currentURL)
                        } else {
                            UIApplication.shared.open(initialURL)
                        }
                    } label: {
                        Image(systemName: "safari")
                    }
                }
            }
        }
    }
}

private struct StatVinWebView: UIViewRepresentable {
    let initialURL: URL
    @Binding var currentURL: URL?
    @Binding var isLoading: Bool
    let onResolvedURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(currentURL: $currentURL, isLoading: $isLoading, onResolvedURL: onResolvedURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var currentURL: URL?
        @Binding private var isLoading: Bool
        private let onResolvedURL: (URL) -> Void
        private var lastResolvedURLString: String?
        private var resolutionTask: Task<Void, Never>?

        init(
            currentURL: Binding<URL?>,
            isLoading: Binding<Bool>,
            onResolvedURL: @escaping (URL) -> Void
        ) {
            _currentURL = currentURL
            _isLoading = isLoading
            self.onResolvedURL = onResolvedURL
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            resolutionTask?.cancel()
            isLoading = true
            currentURL = webView.url
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            currentURL = webView.url
            scheduleResolutionCheck(for: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            resolutionTask?.cancel()
            isLoading = false
            currentURL = webView.url
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            resolutionTask?.cancel()
            isLoading = false
            currentURL = webView.url
        }

        private func scheduleResolutionCheck(for webView: WKWebView) {
            resolutionTask?.cancel()
            resolutionTask = Task { [weak webView] in
                // stat.vin may finish one navigation and then redirect again after captcha/JS.
                // Wait for the URL to settle before classifying to avoid false "No pics".
                for attempt in 0..<8 {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: attempt == 0 ? 1_000_000_000 : 750_000_000)
                    guard let webView else { return }
                    guard !webView.isLoading else { continue }

                    let resolvedURL = await resolvedURL(from: webView)
                    await MainActor.run {
                        self.currentURL = resolvedURL
                    }

                    if resolveIfKnown(resolvedURL) {
                        return
                    }
                }
            }
        }

        private func resolvedURL(from webView: WKWebView) async -> URL {
            if let locationString = try? await webView.evaluateJavaScript("window.location.href") as? String,
               let locationURL = URL(string: locationString) {
                return locationURL
            }
            return webView.url ?? URL(string: "https://stat.vin")!
        }

        @discardableResult
        private func resolveIfKnown(_ url: URL) -> Bool {
            let rawURL = url.absoluteString
            let lowercasedURL = rawURL.lowercased()
            guard lowercasedURL.contains("stat.vin/cars/") || lowercasedURL.contains("stat.vin/vin-decoding/") else {
                return false
            }
            guard lastResolvedURLString != rawURL else { return false }
            lastResolvedURLString = rawURL
            onResolvedURL(url)
            return true
        }
    }
}
