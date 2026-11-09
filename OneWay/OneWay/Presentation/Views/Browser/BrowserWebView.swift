import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif

enum QuantumBrowserViewportPolicy {
    /// Browser chrome is reserved by SwiftUI safe-area insets. The webpage itself
    /// must not reserve a second estimated toolbar region.
    static let additionalWebContentInset: CGFloat = 0
    static let usesContainerSafeAreaInsets = true
}

struct BrowserWebView: UIViewRepresentable {
    let tabID: UUID
    let url: URL
    let settings: BrowserSettings
    let isPrivate: Bool
    @ObservedObject var viewModel: BrowserViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        BrowserPrivacyManager.shared.configure(configuration, settings: settings, isPrivate: isPrivate)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInset.bottom = QuantumBrowserViewportPolicy.additionalWebContentInset
        webView.scrollView.verticalScrollIndicatorInsets.bottom = QuantumBrowserViewportPolicy.additionalWebContentInset
        context.coordinator.attach(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.viewModel = viewModel
        if webView.url?.absoluteString != url.absoluteString {
            webView.load(URLRequest(url: url))
        }
        webView.scrollView.contentInset.bottom = QuantumBrowserViewportPolicy.additionalWebContentInset
        webView.scrollView.verticalScrollIndicatorInsets.bottom = QuantumBrowserViewportPolicy.additionalWebContentInset
        context.coordinator.update(from: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        var viewModel: BrowserViewModel

        private var titleObservation: NSKeyValueObservation?
        private var urlObservation: NSKeyValueObservation?
        private var loadingObservation: NSKeyValueObservation?
        private var progressObservation: NSKeyValueObservation?
        private var canGoBackObservation: NSKeyValueObservation?
        private var canGoForwardObservation: NSKeyValueObservation?

        init(viewModel: BrowserViewModel) {
            self.viewModel = viewModel
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            viewModel.attach(webView)
            observe(webView)
            update(from: webView)
        }

        func update(from webView: WKWebView) {
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.viewModel.updateWebState(from: webView)
            }
        }

        private func observe(_ webView: WKWebView) {
            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in self?.update(from: webView) }
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in self?.update(from: webView) }
            loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in self?.update(from: webView) }
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in self?.update(from: webView) }
            canGoBackObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in self?.update(from: webView) }
            canGoForwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in self?.update(from: webView) }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            update(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            update(from: webView)
            viewModel.recordCurrentPage()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            viewModel.markLoadFailed()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            viewModel.markLoadFailed()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let requestedURL = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            let scheme = requestedURL.scheme?.lowercased() ?? ""
            if !["http", "https", "about"].contains(scheme) {
                if navigationAction.navigationType == .linkActivated {
                    viewModel.notice = BrowserNotice(
                        title: "External App Link Blocked",
                        message: "Quantum kept this page inside OneWay. Open a portal externally only from its explicit portal menu."
                    )
                }
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame == nil {
                viewModel.newTab()
                viewModel.open(requestedURL)
                decisionHandler(.cancel)
                return
            }

            if viewModel.settings.httpsOnlyMode,
               requestedURL.scheme?.lowercased() == "http",
               var components = URLComponents(url: requestedURL, resolvingAgainstBaseURL: false) {
                components.scheme = "https"
                if let httpsURL = components.url {
                    viewModel.open(httpsURL)
                    decisionHandler(.cancel)
                    return
                }
            }

            viewModel.notePotentialBlockedResource(requestedURL)
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                viewModel.newTab()
                viewModel.open(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            #if canImport(UIKit)
            presentAlert(title: frame.request.url?.host ?? "Quantum", message: message, actions: [
                UIAlertAction(title: "OK", style: .default) { _ in completionHandler() }
            ])
            #else
            completionHandler()
            #endif
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            #if canImport(UIKit)
            presentAlert(title: frame.request.url?.host ?? "Quantum", message: message, actions: [
                UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) },
                UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) }
            ])
            #else
            completionHandler(false)
            #endif
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            #if canImport(UIKit)
            let alert = UIAlertController(title: frame.request.url?.host ?? "Quantum", message: prompt, preferredStyle: .alert)
            alert.addTextField { field in field.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            topViewController()?.present(alert, animated: true)
            #else
            completionHandler(nil)
            #endif
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            viewModel.recordDownload(from: navigationResponse.response.url, suggestedFilename: navigationResponse.response.suggestedFilename)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
            } else {
                viewModel.recordDownload(from: navigationResponse.response.url, suggestedFilename: navigationResponse.response.suggestedFilename)
                decisionHandler(.download)
            }
        }

        #if canImport(UIKit)
        private func presentAlert(title: String, message: String, actions: [UIAlertAction]) {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            actions.forEach(alert.addAction)
            topViewController()?.present(alert, animated: true)
        }

        private func topViewController() -> UIViewController? {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
            while let presented = controller?.presentedViewController {
                controller = presented
            }
            return controller
        }
        #endif
    }
}
