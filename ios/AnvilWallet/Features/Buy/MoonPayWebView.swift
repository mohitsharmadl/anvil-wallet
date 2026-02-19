import SwiftUI
import WebKit

/// A SwiftUI wrapper around WKWebView for embedding the MoonPay (or Transak) buy widget.
///
/// Navigation policy:
///   - Allows navigation within moonpay.com and transak.com domains
///   - Opens all other URLs in the system browser (Safari)
///   - Reports loading state and errors to the parent view via callbacks
struct MoonPayWebView: UIViewRepresentable {
    let url: URL

    /// Called when the loading state changes (true = loading, false = done).
    var onLoadingStateChanged: ((Bool) -> Void)?

    /// Called when the WebView encounters a navigation or page load error.
    var onError: ((Error) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLoadingStateChanged: onLoadingStateChanged,
            onError: onError
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Allow inline media playback (MoonPay may use video for KYC)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        // Observe loading state via KVO
        context.coordinator.observeLoading(webView)

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // If the URL changed, reload with the new URL
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        private var onLoadingStateChanged: ((Bool) -> Void)?
        private var onError: ((Error) -> Void)?
        private var loadingObservation: NSKeyValueObservation?

        /// Domains that are allowed to navigate within the WebView.
        private let allowedDomains = [
            "moonpay.com",
            "buy.moonpay.com",
            "global.transak.com",
            "transak.com",
            // MoonPay may redirect through these for 3DS / payment processing
            "stripe.com",
            "checkout.com",
        ]

        init(
            onLoadingStateChanged: ((Bool) -> Void)?,
            onError: ((Error) -> Void)?
        ) {
            self.onLoadingStateChanged = onLoadingStateChanged
            self.onError = onError
        }

        func observeLoading(_ webView: WKWebView) {
            loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                DispatchQueue.main.async {
                    self?.onLoadingStateChanged?(change.newValue ?? false)
                }
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let requestURL = navigationAction.request.url,
                  let host = requestURL.host?.lowercased() else {
                decisionHandler(.allow)
                return
            }

            // Allow navigation within permitted domains
            let isAllowed = allowedDomains.contains { domain in
                host == domain || host.hasSuffix(".\(domain)")
            }

            if isAllowed {
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .linkActivated {
                // User tapped a link to an external domain -- open in Safari
                UIApplication.shared.open(requestURL)
                decisionHandler(.cancel)
            } else {
                // Sub-resource loads, redirects within the page, etc. -- allow
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            // Ignore cancellation errors (triggered by our own navigation policy cancels)
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.onError?(error)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.onError?(error)
            }
        }
    }
}
