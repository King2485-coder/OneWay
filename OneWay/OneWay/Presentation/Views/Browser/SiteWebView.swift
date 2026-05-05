import SwiftUI
import WebKit

/// Sandboxed WKWebView for rendering *.oneway.app sites. Disables third-party
/// cookies, restricts navigation to oneway.app, and uses a non-persistent
/// data store so each visit is fresh — keeps with the privacy posture.
struct SiteWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(named: "AccentColor") ?? UIColor.black
        webView.scrollView.backgroundColor = UIColor.black
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Only allow loading inside oneway.app surfaces.
            guard let host = navigationAction.request.url?.host else {
                decisionHandler(.cancel); return
            }
            if host == "oneway.app" || host.hasSuffix(".oneway.app") {
                decisionHandler(.allow)
            } else {
                // External link — open in Safari instead of inside the sandbox.
                if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }
    }
}
