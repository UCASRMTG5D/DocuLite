import Foundation
import Combine
import AppKit
import CryptoKit

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
    private static let saveQueue = DispatchQueue(label: "app.doculite.save", qos: .userInitiated)

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
        Self.removeStaleTempPages(in: doc.url)
        guard let data = try? Data(contentsOf: fileURL),
              let html = String(data: data, encoding: .utf8) else { return nil }
        // 旧版本把图片以 base64 内联在 HTML 里（单张图可达数 MB），导致每次保存
        // 都要序列化、跨进程传输、写盘并重建整个预览。首次打开时安全迁移到
        // assets/：先备份、逐张校验字节一致后才替换文件；任何一步失败都保留原文件。
        if let migrated = Self.migrateInlineImages(in: html, doc: doc) {
            return migrated
        }
        return html
    }

    private static func removeStaleTempPages(in docURL: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: docURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for item in items where item.lastPathComponent.hasPrefix(".doculite-page-") {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }

    func saveHTML(_ html: String, for doc: DocuLiteDocument) {
        let fileURL = doc.url.appendingPathComponent("document.html")
        let data = Data(html.utf8)
        // 后台串行写：同一文档的多次保存按调用顺序落盘，且不阻塞输入事件。
        Self.saveQueue.async {
            do {
                // 原子写 + 失败不破坏旧文件
                try data.write(to: fileURL, options: .atomic)
            } catch {
                NSLog("DBG saveHTML failed: \(error)")
            }
        }
    }

    /// 等待当前已排队的磁盘写入全部完成。切换文档前调用，避免立刻读回旧文件。
    static func flushPendingWrites() async {
        await withCheckedContinuation { continuation in
            saveQueue.async { continuation.resume() }
        }
    }

    /// 把 `<img src="data:image/...;base64,...">` 抽取为 assets/ 下的实体文件。
    /// 返回迁移后的 HTML；没有可迁移内容或任何一步失败时返回 nil（调用方继续用原 HTML）。
    static func migrateInlineImages(in html: String, doc: DocuLiteDocument) -> String? {
        guard html.contains("data:image/") else { return nil }
        let pattern = "(<img\\b[^>]*?\\ssrc\\s*=\\s*)([\"'])(data:image/([A-Za-z0-9.+-]+);base64,([^\"']*))\\2"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        let fm = FileManager.default
        let assetsDir = doc.url.appendingPathComponent("assets", isDirectory: true)
        do {
            try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        } catch {
            NSLog("DBG migrate assets dir failed: \(error)")
            return nil
        }

        var replacements: [(range: NSRange, value: String)] = []
        for match in matches {
            let dataRange = match.range(at: 3)
            let subtypeRange = match.range(at: 4)
            let base64Range = match.range(at: 5)
            guard dataRange.location != NSNotFound,
                  subtypeRange.location != NSNotFound,
                  base64Range.location != NSNotFound else { return nil }

            let mime = "image/" + ns.substring(with: subtypeRange).lowercased()
            let base64 = ns.substring(with: base64Range)
            guard let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                  !bytes.isEmpty else {
                NSLog("DBG migrate decode failed mime=%@", mime)
                return nil
            }

            let ext = Self.extensionForMIME(mime)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let baseName = "img-\(digest.prefix(16))"
            var filename = "\(baseName).\(ext)"
            var target = assetsDir.appendingPathComponent(filename)
            var suffix = 2
            while fm.fileExists(atPath: target.path) {
                if (try? Data(contentsOf: target)) == bytes { break }
                filename = "\(baseName)-\(suffix).\(ext)"
                target = assetsDir.appendingPathComponent(filename)
                suffix += 1
            }
            if !fm.fileExists(atPath: target.path) {
                do {
                    try bytes.write(to: target, options: .atomic)
                    guard (try? Data(contentsOf: target)) == bytes else {
                        try? fm.removeItem(at: target)
                        NSLog("DBG migrate verify failed: %@", filename)
                        return nil
                    }
                } catch {
                    NSLog("DBG migrate write failed: \(error)")
                    return nil
                }
            }
            replacements.append((dataRange, "assets/\(filename)"))
        }

        let rewritten = NSMutableString(string: html)
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            rewritten.replaceCharacters(in: replacement.range, with: replacement.value)
        }
        let migrated = rewritten as String
        guard migrated != html else { return nil }

        let fileURL = doc.url.appendingPathComponent("document.html")
        let backupURL = doc.url.appendingPathComponent("document.html.bak")
        if !fm.fileExists(atPath: backupURL.path) {
            do {
                try fm.copyItem(at: fileURL, to: backupURL)
            } catch {
                NSLog("DBG migrate backup failed: \(error)")
                return nil
            }
        }
        do {
            try Data(migrated.utf8).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("DBG migrate write html failed: \(error)")
            return nil
        }
        NSLog("DBG migrated %d inline image(s), html %d -> %d chars", replacements.count, html.count, migrated.count)
        return migrated
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

    func importImage(fileURL: URL, for doc: DocuLiteDocument) throws -> String {
        let ext = fileURL.pathExtension.lowercased()
        let resolvedExt = ext.isEmpty ? "png" : ext
        let filename = UUID().uuidString.lowercased() + "." + resolvedExt
        let assetsDir = assetBaseURL(for: doc)
        let destination = assetsDir.appendingPathComponent(filename)
        let fm = FileManager.default
        if !fm.fileExists(atPath: assetsDir.path) {
            try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        }
        guard !fm.fileExists(atPath: destination.path) else {
            throw Self.error("图片文件已存在，请重试")
        }
        try fm.copyItem(at: fileURL, to: destination)
        return "assets/" + filename
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
            var baseName = ""
            var ext = "png"
            var payload: Data?
            var sourceFile: URL?

            if src.hasPrefix("data:") {
                guard let data = Self.decodeDataURI(src) else { continue }
                payload = data
                ext = Self.extensionForMIME(Self.mimeFromDataURI(src))
                baseName = "img-\(UUID().uuidString.lowercased())"
            } else {
                guard let fileURL = Self.resolveImageSource(src, doc: doc),
                      fm.fileExists(atPath: fileURL.path) else { continue }
                sourceFile = fileURL
                baseName = fileURL.deletingPathExtension().lastPathComponent
                if baseName.isEmpty { baseName = "img-\(UUID().uuidString.lowercased())" }
                ext = fileURL.pathExtension.isEmpty ? "png" : fileURL.pathExtension
            }

            var candidate = "\(baseName).\(ext)"
            var n = 2
            while usedNames.contains(candidate) {
                candidate = "\(baseName)-\(n).\(ext)"
                n += 1
            }
            usedNames.insert(candidate)
            do {
                if let file = sourceFile {
                    try fm.copyItem(at: file, to: exportAssets.appendingPathComponent(candidate))
                } else if let data = payload {
                    try data.write(to: exportAssets.appendingPathComponent(candidate))
                }
                mutable.replaceCharacters(in: match.range(at: 3), with: "assets/\(candidate)")
            } catch {
                continue
            }
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

    /// 从 data: URI 解出图片字节；无法解析时返回 nil。
    private static func decodeDataURI(_ src: String) -> Data? {
        guard src.hasPrefix("data:"),
              src.count > 5,
              let comma = src.firstIndex(of: ","),
              comma > src.startIndex else { return nil }
        let b64 = String(src[src.index(after: comma)...])
        return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
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
        let token = mime.lowercased()
        switch token {
        case "image/jpeg", "jpeg", "jpg": return "jpg"
        case "image/gif", "gif": return "gif"
        case "image/webp", "webp": return "webp"
        case "image/heic", "heic": return "heic"
        case "image/bmp", "bmp": return "bmp"
        case "image/svg+xml", "svg": return "svg"
        default: return "png"
        }
    }

    /// 取 data: URI 的 MIME（如 image/png）。
    private static func mimeFromDataURI(_ src: String) -> String {
        guard src.hasPrefix("data:"), let comma = src.firstIndex(of: ",") else { return "" }
        let metaEnd = src.index(src.startIndex, offsetBy: 5)
        guard comma > metaEnd else { return "" }
        var mime = String(src[metaEnd..<comma])
        if let semi = mime.firstIndex(of: ";") { mime = String(mime[..<semi]) }
        return mime
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "DocuLite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
