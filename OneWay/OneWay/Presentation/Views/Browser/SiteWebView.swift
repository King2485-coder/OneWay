import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// OneWay's browser engine. Uses WKWebView/WebKit so OneWay gets the current
/// iOS web platform while keeping browser chrome, tabs, and navigation inside
/// the app instead of handing users off to Safari.
struct SiteWebView: UIViewRepresentable {
    let url: URL
    var html: String?
    var browserState: BrowserPageState?
    var onBlockedNavigation: ((URL) -> Void)?
    var onInternalNavigation: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            browserState: browserState,
            onBlockedNavigation: onBlockedNavigation,
            onInternalNavigation: onInternalNavigation
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.applicationNameForUserAgent = "OneWayQuantum/1.0"

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(named: "AccentColor") ?? UIColor.black
        webView.scrollView.backgroundColor = UIColor.black
        context.coordinator.attach(webView)
        loadContent(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.browserState = browserState
        context.coordinator.onBlockedNavigation = onBlockedNavigation
        context.coordinator.onInternalNavigation = onInternalNavigation
        loadContent(in: webView, coordinator: context.coordinator)
        context.coordinator.updateState(from: webView)
    }

    private func loadContent(in webView: WKWebView, coordinator: Coordinator) {
        let signature = contentSignature
        guard coordinator.loadedContentSignature != signature else { return }
        coordinator.loadedContentSignature = signature

        if let html {
            webView.loadHTMLString(html, baseURL: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    private var contentSignature: String {
        if let html {
            return "html:\(url.absoluteString):\(html.hashValue)"
        }
        return "url:\(url.absoluteString)"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var browserState: BrowserPageState?
        var onBlockedNavigation: ((URL) -> Void)?
        var onInternalNavigation: ((URL) -> Void)?
        var loadedContentSignature: String?

        private var titleObservation: NSKeyValueObservation?
        private var urlObservation: NSKeyValueObservation?
        private var loadingObservation: NSKeyValueObservation?
        private var progressObservation: NSKeyValueObservation?
        private var canGoBackObservation: NSKeyValueObservation?
        private var canGoForwardObservation: NSKeyValueObservation?

        init(
            browserState: BrowserPageState?,
            onBlockedNavigation: ((URL) -> Void)?,
            onInternalNavigation: ((URL) -> Void)?
        ) {
            self.browserState = browserState
            self.onBlockedNavigation = onBlockedNavigation
            self.onInternalNavigation = onInternalNavigation
        }

        func attach(_ webView: WKWebView) {
            browserState?.attach(webView)
            observe(webView)
        }

        func updateState(from webView: WKWebView) {
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let webView else { return }
                self?.browserState?.update(from: webView)
            }
        }

        private func observe(_ webView: WKWebView) {
            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                self?.updateState(from: webView)
            }
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                self?.updateState(from: webView)
            }
            loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                self?.updateState(from: webView)
            }
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                self?.updateState(from: webView)
            }
            canGoBackObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                self?.updateState(from: webView)
            }
            canGoForwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                self?.updateState(from: webView)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Keep supported browser navigation inside OneWay's browser chrome.
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel); return
            }
            if url.scheme == "about" {
                decisionHandler(.allow); return
            }
            if OneWayBrowserPolicy.isAllowed(url) {
                let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
                if isMainFrame, navigationAction.navigationType != .other {
                    DispatchQueue.main.async { [onInternalNavigation] in
                        onInternalNavigation?(url)
                    }
                    decisionHandler(.cancel); return
                }
                decisionHandler(.allow)
            } else {
                if navigationAction.navigationType == .linkActivated {
                    DispatchQueue.main.async { [onBlockedNavigation] in
                        onBlockedNavigation?(url)
                    }
                }
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else {
                return nil
            }

            if OneWayBrowserPolicy.isAllowed(url) {
                DispatchQueue.main.async { [onInternalNavigation] in
                    onInternalNavigation?(url)
                }
            } else {
                DispatchQueue.main.async { [onBlockedNavigation] in
                    onBlockedNavigation?(url)
                }
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            #if canImport(UIKit)
            presentJavaScriptDialog(
                title: frame.securityOrigin.host,
                message: message,
                actions: [
                    UIAlertAction(title: "OK", style: .default) { _ in completionHandler() }
                ],
                fallback: completionHandler
            )
            #else
            completionHandler()
            #endif
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            #if canImport(UIKit)
            presentJavaScriptDialog(
                title: frame.securityOrigin.host,
                message: message,
                actions: [
                    UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) },
                    UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) }
                ],
                fallback: { completionHandler(false) }
            )
            #else
            completionHandler(false)
            #endif
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            #if canImport(UIKit)
            DispatchQueue.main.async {
                guard let presenter = Self.topViewController() else {
                    completionHandler(nil)
                    return
                }
                let alert = UIAlertController(
                    title: frame.securityOrigin.host,
                    message: prompt,
                    preferredStyle: .alert
                )
                alert.addTextField { textField in
                    textField.text = defaultText
                }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    completionHandler(nil)
                })
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                    completionHandler(alert.textFields?.first?.text)
                })
                presenter.present(alert, animated: true)
            }
            #else
            completionHandler(nil)
            #endif
        }

        @available(iOS 15.0, *)
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.prompt)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            updateState(from: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            updateState(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateState(from: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            updateState(from: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            updateState(from: webView)
        }

        #if canImport(UIKit)
        private func presentJavaScriptDialog(
            title: String,
            message: String,
            actions: [UIAlertAction],
            fallback: @escaping () -> Void
        ) {
            DispatchQueue.main.async {
                guard let presenter = Self.topViewController() else {
                    fallback()
                    return
                }
                let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                actions.forEach(alert.addAction)
                presenter.present(alert, animated: true)
            }
        }

        private static func topViewController() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
            let root = scenes
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .rootViewController
            return topViewController(from: root)
        }

        private static func topViewController(from root: UIViewController?) -> UIViewController? {
            if let presented = root?.presentedViewController {
                return topViewController(from: presented)
            }
            if let navigation = root as? UINavigationController {
                return topViewController(from: navigation.visibleViewController)
            }
            if let tab = root as? UITabBarController {
                return topViewController(from: tab.selectedViewController)
            }
            return root
        }
        #endif
    }
}
