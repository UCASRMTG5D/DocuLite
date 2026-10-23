import SwiftUI
import WebKit

/// 只读预览 WebView：渲染与编辑器相同的正文片段，支持图片点击放大。
struct PreviewWebView: NSViewRepresentable {
    var htmlFragment: String
    var documentURL: URL?
    var token: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        // 用默认白底，不关背景、不动 layer，避免透明底在深色容器下透出黑屏
        context.coordinator.currentBaseURL = documentURL
        context.coordinator.currentToken = token
        context.coordinator.pendingHTML = htmlFragment
        context.coordinator.loadPage(in: webView, baseURL: documentURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let baseURLChanged = context.coordinator.currentBaseURL != documentURL
        let tokenChanged = context.coordinator.currentToken != token
        if baseURLChanged {
            context.coordinator.currentBaseURL = documentURL
            context.coordinator.currentToken = token
            context.coordinator.pendingHTML = htmlFragment
            context.coordinator.loadPage(in: webView, baseURL: documentURL)
        } else if tokenChanged {
            context.coordinator.currentToken = token
            context.coordinator.pendingHTML = htmlFragment
            context.coordinator.pushHTML(in: webView)
        } else if context.coordinator.pageLoaded && context.coordinator.sentHTML != htmlFragment {
            context.coordinator.pendingHTML = htmlFragment
            context.coordinator.pushHTML(in: webView)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        if let temp = coordinator.tempPageURL {
            coordinator.tempPageURL = nil
            try? FileManager.default.removeItem(at: temp)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PreviewWebView
        var currentBaseURL: URL?
        var currentToken = UUID()
        var pendingHTML: String?
        var sentHTML: String?
        var tempPageURL: URL?
        var pageLoaded = false

        init(_ parent: PreviewWebView) {
            self.parent = parent
            self.pendingHTML = parent.htmlFragment
        }

        func loadPage(in webView: WKWebView, baseURL: URL?) {
            pageLoaded = false
            guard let pageURL = Bundle.main.url(forResource: "preview", withExtension: "html"),
                  let page = try? String(contentsOf: pageURL, encoding: .utf8) else {
                return
            }
            let prepared = LocalPageLoader.injectingBase(page, into: baseURL)
            if let old = tempPageURL {
                tempPageURL = nil
                try? FileManager.default.removeItem(at: old)
            }
            do {
                let temp = try LocalPageLoader.writeTempPage(prepared, preferredDirectory: baseURL)
                tempPageURL = temp.url
                webView.loadFileURL(temp.url, allowingReadAccessTo: temp.readRoot)
            } catch {
                webView.loadHTMLString(prepared, baseURL: baseURL)
            }
        }

        func pushHTML(in webView: WKWebView) {
            guard let html = pendingHTML else { return }
            pendingHTML = nil
            sentHTML = html
            let literal = EditorBridgeJS.string(html)
            webView.callAsyncJavaScript(
                "window.doculitePreview.setHTML(\(literal));", in: nil, in: .page
            ) { _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            pushHTML(in: webView)
        }
    }
}
