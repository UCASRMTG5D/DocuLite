import SwiftUI
import WebKit
import Combine

/// 原生工具栏与编辑 WebView 之间的桥：持有弱引用 webView，暴露简单命令接口。
@MainActor
final class EditorBridge: ObservableObject {
    weak var webView: WKWebView?

    func exec(_ command: String, _ value: String? = nil) {
        guard let webView else { return }
        let valueJS = value.flatMap(Self.jsLiteral) ?? "null"
        let script = "window.doculiteAPI.exec(\(Self.jsLiteral(command)), \(valueJS));"
        webView.callAsyncJavaScript(script, in: nil, in: .page) { _ in }
    }

    func insertImage(_ src: String) {
        guard let webView else { return }
        let script = "window.doculiteAPI.insertImage(\(Self.jsLiteral(src)));"
        webView.callAsyncJavaScript(script, in: nil, in: .page) { _ in }
    }

    func focus() {
        guard let webView else { return }
        webView.callAsyncJavaScript("window.doculiteAPI.focus();", in: nil, in: .page) { _ in }
    }

    func setHTML(_ html: String) {
        guard let webView else { return }
        let script = "window.doculiteAPI.setHTML(\(Self.jsLiteral(html)));"
        webView.callAsyncJavaScript(script, in: nil, in: .page) { _ in }
    }

    func getHTML() async throws -> String? {
        guard let webView else { return nil }
        let result = try await webView.callAsyncJavaScript(
            "return window.doculiteAPI.getHTML();", in: nil, in: .page
        )
        return result as? String
    }

    /// 将 Swift 字符串编码为 JS 字符串字面量（含引号）。
    private static func jsLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String],
              let first = array.first,
              let encodedData = try? JSONSerialization.data(withJSONObject: [first]),
              let encodedString = String(data: encodedData, encoding: .utf8) else {
            return "\"\""
        }
        // "[\"...\"]" → "\"...\""：去掉外层方括号
        return String(encodedString.dropFirst().dropLast())
    }
}

/// WKWebView 编辑器包装：加载自带 contenteditable 页面，桥接消息与命令。
struct EditorWebView: NSViewRepresentable {
    var htmlToLoad: String?
    var documentURL: URL?
    var token: UUID
    var bridge: EditorBridge
    var importImageHandler: (String) async throws -> String?
    var onContentChanged: () -> Void
    var onSelectionState: ([String: Any]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "doculiteNotify")
        config.userContentController.add(context.coordinator, name: "doculite")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        bridge.webView = webView
        context.coordinator.loadPage(in: webView, baseURL: documentURL)
        context.coordinator.currentToken = token
        context.coordinator.currentBaseURL = documentURL
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        bridge.webView = webView
        if context.coordinator.currentBaseURL != documentURL {
            context.coordinator.currentBaseURL = documentURL
            context.coordinator.currentToken = token
            context.coordinator.pendingHTML = htmlToLoad
            context.coordinator.loadPage(in: webView, baseURL: documentURL)
        } else if context.coordinator.currentToken != token {
            context.coordinator.currentToken = token
            if let html = htmlToLoad {
                context.coordinator.setHTML(html, in: webView)
            }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "doculiteNotify")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "doculite")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
        var parent: EditorWebView
        var currentBaseURL: URL?
        var currentToken = UUID()
        /// 页面加载完成后待注入的 HTML（load 时暂存）
        var pendingHTML: String?
        var tempPageURL: URL?
        private var pageLoaded = false

        init(_ parent: EditorWebView) {
            self.parent = parent
            self.pendingHTML = parent.htmlToLoad
        }

        func loadPage(in webView: WKWebView, baseURL: URL?) {
            pageLoaded = false
            guard let pageURL = Bundle.main.url(forResource: "editor", withExtension: "html"),
                  let page = try? String(contentsOf: pageURL, encoding: .utf8) else {
                return
            }
            let prepared = LocalPageLoader.injectingBase(page, into: baseURL)
            do {
                let tempURL = try LocalPageLoader.writeTempPage(prepared)
                tempPageURL = tempURL
                webView.loadFileURL(tempURL, allowingReadAccessTo: LocalPageLoader.fullDiskAccess)
            } catch {
                webView.loadHTMLString(prepared, baseURL: baseURL)
            }
        }

        func setHTML(_ html: String, in webView: WKWebView) {
            let literal = EditorBridgeJS.string(html)
            webView.callAsyncJavaScript(
                "window.doculiteAPI.setHTML(\(literal));", in: nil, in: .page
            ) { _ in }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            if let temp = tempPageURL {
                tempPageURL = nil
                try? FileManager.default.removeItem(at: temp)
            }
            if let html = pendingHTML {
                pendingHTML = nil
                setHTML(html, in: webView)
            }
        }

        // MARK: WKScriptMessageHandler（普通通知）

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let event = body["event"] as? String else { return }
            switch event {
            case "contentChanged":
                parent.onContentChanged()
            case "selectionState":
                if let state = body["state"] as? [String: Any] {
                    parent.onSelectionState(state)
                }
            default:
                break
            }
        }

        // MARK: WKScriptMessageHandlerWithReply（图片导入）

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            guard let body = message.body as? [String: Any],
                  body["action"] as? String == "importImage",
                  let dataURL = body["dataURL"] as? String else {
                replyHandler(nil, nil)
                return
            }
            let handler = parent.importImageHandler
            Task { @MainActor in
                do {
                    let relativePath = try await handler(dataURL)
                    replyHandler(relativePath, nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            }
        }
    }
}

/// 独立的 JS 字符串字面量编码工具（供 Coordinator 使用）。
enum EditorBridgeJS {
    static func string(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]) else { return "\"\"" }
        guard let wrapped = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(wrapped.dropFirst().dropLast())
    }
}

/// 将打包 HTML 写成临时文件并以整盘读权限加载，
/// 使编辑器/预览既能读文档包内的 assets/ 相对路径，也能显示直链的绝对路径图片。
enum LocalPageLoader {
    static let fullDiskAccess = URL(fileURLWithPath: "/", isDirectory: true)

    static func writeTempPage(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doculite-\(UUID().uuidString).html")
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }

    static func injectingBase(_ page: String, into baseURL: URL?) -> String {
        guard var base = baseURL?.absoluteString else { return page }
        if !base.hasSuffix("/") { base += "/" }
        return page.replacingOccurrences(
            of: "</head>",
            with: "<base href=\"\(base)\">\n</head>",
            options: .caseInsensitive
        )
    }
}
