import SwiftUI
import WebKit

/// In-app dApp browser built on WKWebView.
///
/// Features:
///   - URL bar with HTTPS indicator
///   - Back / Forward / Refresh navigation controls
///   - Detects WalletConnect URIs from deep links and initiates pairing
///   - Progress bar during page loads
struct DAppBrowserView: View {
    let initialURL: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var walletConnect = WalletConnectService.shared

    @State private var urlText: String = ""
    @State private var currentURL: URL?
    @State private var isSecure: Bool = true
    @State private var pageTitle: String = ""
    @State private var isLoading = false
    @State private var loadProgress: Double = 0
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var errorMessage: String?

    /// Coordinator reference for imperative navigation commands.
    @State private var webViewRef: WKWebView?

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            if isLoading {
                ProgressView(value: loadProgress)
                    .progressViewStyle(.linear)
                    .tint(.accentGreen)
            }

            // URL bar
            HStack(spacing: 8) {
                Image(systemName: isSecure ? "lock.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(isSecure ? .accentGreen : .warning)
                    .accessibilityLabel(isSecure ? "Secure connection" : "Insecure connection")

                TextField("Search or enter URL", text: $urlText)
                    .font(.subheadline)
                    .foregroundColor(.textPrimary)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .submitLabel(.go)
                    .onSubmit {
                        navigateTo(urlText)
                    }
                    .accessibilityLabel("URL field")

                if !urlText.isEmpty {
                    Button {
                        urlText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Clear URL")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.backgroundCard)
            .cornerRadius(10)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // WebView
            DAppWebView(
                url: initialURL,
                webViewRef: $webViewRef,
                onURLChanged: { url in
                    currentURL = url
                    urlText = url.host ?? url.absoluteString
                    isSecure = url.scheme?.lowercased() == "https"
                },
                onTitleChanged: { title in
                    pageTitle = title
                },
                onLoadingChanged: { loading in
                    isLoading = loading
                },
                onProgressChanged: { progress in
                    loadProgress = progress
                },
                onNavigationChanged: { back, forward in
                    canGoBack = back
                    canGoForward = forward
                },
                onWalletConnectURI: { uri in
                    Task {
                        try? await walletConnect.pair(uri: uri)
                    }
                }
            )
            .ignoresSafeArea(edges: .bottom)

            // Navigation toolbar
            HStack(spacing: 0) {
                Button { webViewRef?.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!canGoBack)
                .accessibilityLabel("Go back")

                Button { webViewRef?.goForward() } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!canGoForward)
                .accessibilityLabel("Go forward")

                Button {
                    if isLoading {
                        webViewRef?.stopLoading()
                    } else {
                        webViewRef?.reload()
                    }
                } label: {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel(isLoading ? "Stop loading" : "Reload page")

                Button {
                    if let url = currentURL {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Image(systemName: "safari")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Open in Safari")
            }
            .foregroundColor(.accentGreen)
            .padding(.vertical, 10)
            .background(Color.backgroundCard)
        }
        .background(Color.backgroundPrimary)
        .navigationTitle(pageTitle.isEmpty ? "Browser" : pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $walletConnect.pendingProposal) { proposal in
            SessionApproveView(proposal: proposal)
        }
        .sheet(item: $walletConnect.pendingRequest) { request in
            SignRequestView(request: request)
        }
        .onAppear {
            urlText = initialURL.host ?? initialURL.absoluteString
        }
    }

    private func navigateTo(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let urlString: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            urlString = trimmed
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            urlString = "https://\(trimmed)"
        } else {
            urlString = "https://www.google.com/search?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)"
        }

        if let url = URL(string: urlString) {
            webViewRef?.load(URLRequest(url: url))
        }
    }
}

// MARK: - WKWebView Wrapper

private struct DAppWebView: UIViewRepresentable {
    let url: URL

    @Binding var webViewRef: WKWebView?

    let onURLChanged: (URL) -> Void
    let onTitleChanged: (String) -> Void
    let onLoadingChanged: (Bool) -> Void
    let onProgressChanged: (Double) -> Void
    let onNavigationChanged: (Bool, Bool) -> Void
    let onWalletConnectURI: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Color.backgroundPrimary)
        webView.scrollView.backgroundColor = UIColor(Color.backgroundPrimary)

        context.coordinator.observe(webView)

        DispatchQueue.main.async {
            webViewRef = webView
        }

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: DAppWebView
        private var urlObservation: NSKeyValueObservation?
        private var titleObservation: NSKeyValueObservation?
        private var loadingObservation: NSKeyValueObservation?
        private var progressObservation: NSKeyValueObservation?

        init(parent: DAppWebView) {
            self.parent = parent
        }

        func observe(_ webView: WKWebView) {
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    if let url = wv.url {
                        self?.parent.onURLChanged(url)
                    }
                }
            }

            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                DispatchQueue.main.async {
                    self?.parent.onTitleChanged(wv.title ?? "")
                }
            }

            loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                DispatchQueue.main.async {
                    self?.parent.onLoadingChanged(change.newValue ?? false)
                    self?.parent.onNavigationChanged(
                        webView.canGoBack,
                        webView.canGoForward
                    )
                }
            }

            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                DispatchQueue.main.async {
                    self?.parent.onProgressChanged(change.newValue ?? 0)
                }
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url {
                let urlString = url.absoluteString

                // Detect WalletConnect deep links
                if urlString.hasPrefix("wc:") {
                    parent.onWalletConnectURI(urlString)
                    decisionHandler(.cancel)
                    return
                }

                // Block non-HTTP(S) schemes except about:blank
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme != "https" && scheme != "http" && scheme != "about" {
                    if scheme != "" {
                        UIApplication.shared.open(url)
                    }
                    decisionHandler(.cancel)
                    return
                }
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.onNavigationChanged(
                    webView.canGoBack,
                    webView.canGoForward
                )
            }
        }
    }
}
