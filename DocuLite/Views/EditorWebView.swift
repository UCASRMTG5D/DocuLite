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
        // 用 evaluateJavaScript 而非 callAsyncJavaScript：后者会把字符串返回值当 JSON 反序列化，
        // 使非 JSON 的 HTML 桥接为 nil，导致预览无法刷新。
        let result: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                "window.doculiteAPI.getHTML()", in: nil, in: .page
            ) { res in
                if case .success(let value) = res {
                    continuation.resume(returning: value as? String)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
        return result
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
        // WKWebView 在 macOS 上默认按 WebKit 策略渲染背景；不要手动设 layer 背景，
        // 否则会干扰布局导致 HSplitView 里出现黑底、不响应的"黑屏"。页面 CSS 已强制白底。
        bridge.webView = webView
        context.coordinator.loadPage(in: webView, baseURL: documentURL)
        context.coordinator.currentToken = token
        context.coordinator.currentBaseURL = documentURL
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        bridge.webView = webView
        let baseURLChanged = context.coordinator.currentBaseURL != documentURL
        let tokenChanged = context.coordinator.currentToken != token
        if baseURLChanged {
            context.coordinator.currentBaseURL = documentURL
            context.coordinator.currentToken = token
            context.coordinator.pendingHTML = htmlToLoad
            context.coordinator.loadPage(in: webView, baseURL: documentURL)
        } else if tokenChanged {
            context.coordinator.currentToken = token
            context.coordinator.pendingHTML = htmlToLoad
            if context.coordinator.pageLoaded {
                context.coordinator.setHTML(htmlToLoad ?? "", in: webView)
            }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        if let temp = coordinator.tempPageURL {
            coordinator.tempPageURL = nil
            try? FileManager.default.removeItem(at: temp)
        }
        // WKWebView 会被 SwiftUI 拆卸/复用，removeScriptMessageHandler 会让 JS 侧 messageHandlers 变空，
        // 从而 contentChanged 与图片导入静默失效；保留注册更安全（coordinator 由 context 强持有）。
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
        var parent: EditorWebView
        var currentBaseURL: URL?
        var currentToken = UUID()
        /// 页面加载完成后待注入的 HTML（load 时暂存）
        var pendingHTML: String?
        var tempPageURL: URL?
        var pageLoaded = false

        init(_ parent: EditorWebView) {
            self.parent = parent
            self.pendingHTML = parent.htmlToLoad
        }

    func loadPage(in webView: WKWebView, baseURL: URL?) {
        pageLoaded = false
        guard let pageURL = Bundle.main.url(forResource: "editor", withExtension: "html"),
              let page = try? String(contentsOf: pageURL, encoding: .utf8) else {
            NSLog("DBG editor loadPage: 找不到 editor.html 资源")
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
            NSLog("DBG editor loadPage OK url=%@ root=%@ len=%d", temp.url.absoluteString, temp.readRoot.path, page.utf8.count)
        } catch {
            NSLog("DBG editor loadPage 写临时文件失败: \(error); 回退 loadHTMLString")
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
            if let html = pendingHTML {
                pendingHTML = nil
                setHTML(html, in: webView)
            }
            // 诊断：确认页面 JS 桥与编辑区可交互
            webView.evaluateJavaScript(
                "(function(){var e=document.getElementById('editor');return JSON.stringify({api:typeof window.doculiteAPI,editable:e?e.isContentEditable:null,ready:document.readyState});})()"
            ) { r, e in
                NSLog("DBG editorDidFinish api/editable -> %@ err=%@", String(describing: r), String(describing: e))
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
                if let relativePath {
                    replyHandler(relativePath, nil)
                } else {
                    replyHandler(nil, "图片导入失败：无法解析 dataURL")
                }
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

/// 将打包 HTML 写成临时文件并以文档目录为读根加载，
/// 使编辑器/预览能读取文档包内的 assets/ 相对路径。
enum LocalPageLoader {
    static let fullDiskAccess = URL(fileURLWithPath: "/", isDirectory: true)

    struct TempPage {
        let url: URL
        let readRoot: URL
    }

    static func writeTempPage(_ content: String, preferredDirectory: URL?) throws -> TempPage {
        if let directory = preferredDirectory {
            // 页面必须与 assets/ 同属一个读根，否则 WKWebView 的 WebContent
            // 进程会拒绝加载相对路径图片（naturalWidth 为 0）。
            let url = directory.appendingPathComponent(".doculite-page-\(UUID().uuidString).html")
            if (try? Data(content.utf8).write(to: url, options: .atomic)) != nil {
                return TempPage(url: url, readRoot: directory)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doculite-\(UUID().uuidString).html")
        try Data(content.utf8).write(to: url, options: .atomic)
        return TempPage(url: url, readRoot: fullDiskAccess)
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
