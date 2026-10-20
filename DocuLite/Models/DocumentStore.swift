import Foundation
import Combine
import AppKit

/// 文档仓库：管理工作区文件夹与 .doculite 目录包文档（document.html + assets/）。
@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var documents: [DocuLiteDocument] = []

    struct DocuLiteDocument: Identifiable, Hashable {
        let url: URL
        var name: String { url.deletingPathExtension().lastPathComponent }
        var id: URL { url }
    }

    private static let workspaceDefaultsKey = "doculite.workspacePath"

    init() {
        restoreWorkspaceIfNeeded()
    }

    // MARK: - 工作区

    @discardableResult
    func chooseWorkspace() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.title = "选择工作区文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        UserDefaults.standard.set(url.path, forKey: Self.workspaceDefaultsKey)
        workspaceURL = url
        refreshDocuments()
        return true
    }

    func restoreWorkspaceIfNeeded() {
        guard let path = UserDefaults.standard.string(forKey: Self.workspaceDefaultsKey),
              FileManager.default.fileExists(atPath: path, isDirectory: nil) else {
            workspaceURL = nil
            documents = []
            return
        }
        workspaceURL = URL(fileURLWithPath: path, isDirectory: true)
        refreshDocuments()
    }

    func refreshDocuments() {
        guard let workspace = workspaceURL else {
            documents = []
            return
        }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            documents = []
            return
        }
        documents = items
            .filter { $0.pathExtension.lowercased() == "doculite" }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { DocuLiteDocument(url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - 文档 CRUD

    @discardableResult
    func createDocument(named name: String) -> DocuLiteDocument? {
        guard let workspace = workspaceURL else { return nil }
        guard let sanitized = Self.sanitizedUniqueName(base: name, in: workspace) else { return nil }
        let docURL = workspace.appendingPathComponent(sanitized + ".doculite", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: docURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: assetBaseURL(forURL: docURL), withIntermediateDirectories: true)
            let template = "<p>开始写作…</p>\n"
            try Data(template.utf8).write(to: docURL.appendingPathComponent("document.html"), options: .atomic)
        } catch {
            try? fm.removeItem(at: docURL)
            return nil
        }
        refreshDocuments()
        return DocuLiteDocument(url: docURL)
    }

    func deleteDocument(_ doc: DocuLiteDocument) throws {
        try FileManager.default.removeItem(at: doc.url)
        refreshDocuments()
    }

    func renameDocument(_ doc: DocuLiteDocument, to newName: String) throws {
        guard let workspace = workspaceURL else {
            throw Self.error("未选择工作区")
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":") else {
            throw Self.error("文档名不能为空且不能包含 / 或 :")
        }
        // 重名时抛错（用户显式重命名不做自动去重）
        let target = workspace.appendingPathComponent(trimmed + ".doculite")
        guard target.path != doc.url.path else { return }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw Self.error("已存在同名文档")
        }
        try FileManager.default.moveItem(at: doc.url, to: target)
        refreshDocuments()
    }

    // MARK: - 读写

    func loadHTML(for doc: DocuLiteDocument) -> String? {
        let fileURL = doc.url.appendingPathComponent("document.html")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveHTML(_ html: String, for doc: DocuLiteDocument) {
        let fileURL = doc.url.appendingPathComponent("document.html")
        // 原子写 + 失败不破坏旧文件
        try? Data(html.utf8).write(to: fileURL, options: .atomic)
    }

    func assetBaseURL(for doc: DocuLiteDocument) -> URL {
        assetBaseURL(forURL: doc.url)
    }

    // MARK: - 图片导入

    func importImage(dataURL: String, for doc: DocuLiteDocument) throws -> String? {
        let prefix = "data:image/"
        guard dataURL.hasPrefix(prefix),
              let commaIndex = dataURL.firstIndex(of: ","),
              commaIndex > dataURL.startIndex else {
            return nil
        }
        let mimeEnd = dataURL.index(dataURL.startIndex, offsetBy: prefix.count)
        guard mimeEnd < commaIndex else { return nil }
        let mime = String(dataURL[mimeEnd..<commaIndex]).lowercased()
        let base64 = String(dataURL[dataURL.index(after: commaIndex)...])
        guard let imageData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        let ext = Self.extensionForMIME(mime)
        let filename = UUID().uuidString.lowercased() + "." + ext
        let assetsDir = assetBaseURL(for: doc)
        let fileURL = assetsDir.appendingPathComponent(filename)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else {
            throw Self.error("图片文件已存在，请重试")
        }
        if !fm.fileExists(atPath: assetsDir.path) {
            try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        }
        try imageData.write(to: fileURL, options: .atomic)
        return "assets/" + filename
    }

    func linkImage(at sourceURL: URL) -> String? {
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else { return nil }
        return sourceURL.path
    }

    /// 导出：生成 "<文档名>/" 文件夹，内含独立可打开的 document.html 与 assets/ 图片拷贝，
    /// 所有图片链接（副本 assets/… 与直链绝对路径）统一重写为相对路径 "assets/…"。
    func exportDocument(_ doc: DocuLiteDocument, htmlFragment: String, toFolder destination: URL) throws -> URL {
        let fm = FileManager.default
        var exportURL = destination.appendingPathComponent(doc.name, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: exportURL.path) {
            exportURL = destination.appendingPathComponent("\(doc.name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try fm.createDirectory(at: exportURL, withIntermediateDirectories: true)
        let assetsOut = exportURL.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: assetsOut, withIntermediateDirectories: true)

        let rewritten = Self.rewrittenForExport(html: htmlFragment, doc: doc, exportAssets: assetsOut)

        guard let templateURL = Bundle.main.url(forResource: "preview", withExtension: "html"),
              var page = try? String(contentsOf: templateURL, encoding: .utf8) else {
            throw Self.error("找不到导出模板")
        }
        let placeholder = "<div id=\"content\"></div>"
        guard page.contains(placeholder) else {
            throw Self.error("导出模板格式异常")
        }
        page = page.replacingOccurrences(of: placeholder, with: "<div id=\"content\">\(rewritten)</div>")
        try Data(page.utf8).write(to: exportURL.appendingPathComponent("document.html"), options: .atomic)
        return exportURL
    }

    // MARK: - 私有

    private func assetBaseURL(forURL docURL: URL) -> URL {
        docURL.appendingPathComponent("assets", isDirectory: true)
    }

    private static func rewrittenForExport(html: String, doc: DocuLiteDocument, exportAssets: URL) -> String {
        let pattern = "(?i)(<img\\b[^>]*?\\ssrc\\s*=\\s*)([\"'])([^\"']+)\\2"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: (html as NSString).length))
        let fm = FileManager.default
        var usedNames = Set<String>()
        let mutable = NSMutableString(string: html)
        for match in matches.reversed() {
            guard let srcRange = Range(match.range(at: 3), in: html) else { continue }
            let src = String(html[srcRange])
            guard let sourceURL = resolveImageSource(src, doc: doc),
                  fm.fileExists(atPath: sourceURL.path) else { continue }
            var base = sourceURL.deletingPathExtension().lastPathComponent
            if base.isEmpty { base = UUID().uuidString.lowercased() }
            let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
            var candidate = "\(base).\(ext)"
            var n = 2
            while usedNames.contains(candidate) {
                candidate = "\(base)-\(n).\(ext)"
                n += 1
            }
            usedNames.insert(candidate)
            do {
                try fm.copyItem(at: sourceURL, to: exportAssets.appendingPathComponent(candidate))
            } catch {
                continue
            }
            mutable.replaceCharacters(in: match.range(at: 3), with: "assets/\(candidate)")
        }
        return mutable as String
    }

    private static func resolveImageSource(_ src: String, doc: DocuLiteDocument) -> URL? {
        if src.hasPrefix("assets/") {
            return doc.url.appendingPathComponent(src)
        }
        if let url = URL(string: src), url.isFileURL {
            return url
        }
        if src.hasPrefix("/") {
            return URL(fileURLWithPath: src)
        }
        return nil
    }

    /// 校验并生成工作区内唯一名称：trim、去非法字符、重名自动加 " 2"/" 3" 后缀。
    private static func sanitizedUniqueName(base: String, in workspace: URL) -> String? {
        var name = base.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasSuffix(".") || name.hasSuffix(" ") { name = String(name.dropLast()) }
        guard !name.isEmpty else { return nil }
        let fm = FileManager.default
        func exists(_ candidate: String) -> Bool {
            fm.fileExists(atPath: workspace.appendingPathComponent(candidate + ".doculite").path)
        }
        if !exists(name) { return name }
        var index = 2
        while exists("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }

    private static func extensionForMIME(_ mime: String) -> String {
        switch mime {
        case "jpeg", "jpg": return "jpg"
        case "gif": return "gif"
        case "webp": return "webp"
        case "heic": return "heic"
        case "bmp": return "bmp"
        default: return "png"
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "DocuLite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
