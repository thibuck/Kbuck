import SwiftUI
import WebKit

struct StatVinBrowserView: View {
    let initialURL: URL
    let onResolvedLookup: (StatVinLookupResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentURL: URL?
    @State private var isLoading = true
    @State private var hasResolved = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                StatVinWebView(
                    initialURL: initialURL,
                    currentURL: $currentURL,
                    isLoading: $isLoading,
                    onResolvedLookup: onResolvedLookup,
                    hasResolved: $hasResolved
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
                    Button("Close") { closeBrowser() }
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

    private func closeBrowser() {
        if !hasResolved, let currentURL, let status = classifyCurrentURL(currentURL) {
            hasResolved = true
            onResolvedLookup(StatVinLookupResult(status: status, resolvedURL: currentURL))
        }
        dismiss()
    }

    private func classifyCurrentURL(_ url: URL) -> StatVinLookupStatus? {
        let lowercasedURL = url.absoluteString.lowercased()
        if lowercasedURL.contains("stat.vin/vin-decoding/") {
            return .noHistory
        }
        if lowercasedURL.contains("stat.vin/cars/") {
            return .hasHistory
        }
        return nil
    }
}

private struct StatVinWebView: UIViewRepresentable {
    let initialURL: URL
    @Binding var currentURL: URL?
    @Binding var isLoading: Bool
    let onResolvedLookup: (StatVinLookupResult) -> Void
    @Binding var hasResolved: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(currentURL: $currentURL, isLoading: $isLoading, onResolvedLookup: onResolvedLookup, hasResolved: $hasResolved)
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

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelResolution()
        uiView.navigationDelegate = nil
        uiView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var currentURL: URL?
        @Binding private var isLoading: Bool
        @Binding private var hasResolved: Bool
        private let onResolvedLookup: (StatVinLookupResult) -> Void
        private var lastResolvedURLString: String?
        private var candidateResolvedURLString: String?
        private var candidateResolvedStatus: StatVinLookupStatus = .unknown
        private var candidateResolvedCount = 0
        private var resolutionTask: Task<Void, Never>?
        private weak var webView: WKWebView?
        private var isActive = true

        init(
            currentURL: Binding<URL?>,
            isLoading: Binding<Bool>,
            onResolvedLookup: @escaping (StatVinLookupResult) -> Void,
            hasResolved: Binding<Bool>
        ) {
            _currentURL = currentURL
            _isLoading = isLoading
            _hasResolved = hasResolved
            self.onResolvedLookup = onResolvedLookup
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard isActive else { return }
            self.webView = webView
            resolutionTask?.cancel()
            candidateResolvedURLString = nil
            candidateResolvedStatus = .unknown
            candidateResolvedCount = 0
            isLoading = true
            currentURL = webView.url
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isActive else { return }
            self.webView = webView
            isLoading = false
            currentURL = webView.url
            scheduleResolutionCheck(for: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard isActive else { return }
            resolutionTask?.cancel()
            isLoading = false
            currentURL = webView.url
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard isActive else { return }
            resolutionTask?.cancel()
            isLoading = false
            currentURL = webView.url
        }

        func cancelResolution() {
            isActive = false
            resolutionTask?.cancel()
            resolutionTask = nil
            candidateResolvedURLString = nil
            candidateResolvedStatus = .unknown
            candidateResolvedCount = 0
        }

        private func scheduleResolutionCheck(for webView: WKWebView) {
            self.webView = webView
            resolutionTask?.cancel()
            resolutionTask = Task { [weak webView] in
                // stat.vin may finish one navigation and then redirect again after captcha/JS.
                // Wait for the URL to settle before classifying to avoid false "No pics".
                for attempt in 0..<12 {
                    if Task.isCancelled { return }
                    
                    let waitTime: UInt64 = attempt == 0 ? 2_000_000_000 : 1_500_000_000
                    try? await Task.sleep(nanoseconds: waitTime)
                    
                    if Task.isCancelled { return }

                    guard let webView else { return }
                    guard self.isActive else { return }
                    guard !webView.isLoading else { continue }
                    
                    // We check if there's a captcha pending or error page here?
                    // No, we will just use resolvedURL and resolveIfKnown.

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

        func resolvedURL(from webView: WKWebView) async -> URL {
            if let locationString = try? await webView.evaluateJavaScript("window.location.href") as? String,
               let locationURL = URL(string: locationString) {
                return locationURL
            }
            return webView.url ?? URL(string: "https://stat.vin")!
        }

        @discardableResult
        func resolveIfKnown(_ url: URL) -> Bool {
            guard isActive else { return false }
            let rawURL = url.absoluteString
            let status = classifyResolvedURL(url)
            guard status != .unknown else {
                candidateResolvedURLString = nil
                candidateResolvedStatus = .unknown
                candidateResolvedCount = 0
                return false
            }
            if candidateResolvedURLString == rawURL, candidateResolvedStatus == status {
                candidateResolvedCount += 1
            } else {
                candidateResolvedURLString = rawURL
                candidateResolvedStatus = status
                candidateResolvedCount = 1
            }

            // Require the same terminal stat.vin URL multiple times before saving.
            // This avoids false positives from intermediate /cars/ URLs before redirects finish.
            guard candidateResolvedCount >= 3 else { return false }
            guard lastResolvedURLString != rawURL else { return false }
            lastResolvedURLString = rawURL
            guard isActive else { return false }
            isLoading = false
            hasResolved = true
            onResolvedLookup(StatVinLookupResult(status: status, resolvedURL: url))
            return true
        }

        private func classifyResolvedURL(_ url: URL) -> StatVinLookupStatus {
            let lowercasedURL = url.absoluteString.lowercased()
            if lowercasedURL.contains("stat.vin/vin-decoding/") {
                return .noHistory
            }
            if lowercasedURL.contains("stat.vin/cars/") {
                return .hasHistory
            }
            return .unknown
        }
    }
}
