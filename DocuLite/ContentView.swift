import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

extension Notification.Name {
    static let doculiteSave = Notification.Name("doculite.save")
}

/// 工具栏按钮反映的选区格式状态。
struct EditorSelectionState {
    var bold = false
    var italic = false
    var underline = false
    var strikeThrough = false
    var insertUnorderedList = false
    var insertOrderedList = false
    var justifyLeft = false
    var justifyCenter = false
    var justifyRight = false
    var formatBlock = "p"

    init(dictionary: [String: Any]) {
        bold = dictionary["bold"] as? Bool ?? false
        italic = dictionary["italic"] as? Bool ?? false
        underline = dictionary["underline"] as? Bool ?? false
        strikeThrough = dictionary["strikeThrough"] as? Bool ?? false
        insertUnorderedList = dictionary["insertUnorderedList"] as? Bool ?? false
        insertOrderedList = dictionary["insertOrderedList"] as? Bool ?? false
        justifyLeft = dictionary["justifyLeft"] as? Bool ?? false
        justifyCenter = dictionary["justifyCenter"] as? Bool ?? false
        justifyRight = dictionary["justifyRight"] as? Bool ?? false
        if let block = dictionary["formatBlock"] as? String {
            formatBlock = block
        }
    }

    var headingDisplayName: String {
        switch formatBlock {
        case "h1": return "标题 1"
        case "h2": return "标题 2"
        case "h3": return "标题 3"
        case "blockquote": return "引用"
        default: return "正文"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: DocumentStore
    @StateObject private var bridge = EditorBridge()

    @State private var selectedDoc: DocumentStore.DocuLiteDocument?
    @State private var editorHTML: String = ""
    @State private var previewHTML: String = ""
    @State private var documentToken = UUID()
    @State private var selectionState = EditorSelectionState(dictionary: [:])
    @State private var saveStatus = "已保存"

    @State private var showNewDocAlert = false
    @State private var newDocName = "未命名文档"
    @State private var renameTarget: DocumentStore.DocuLiteDocument?
    @State private var renameText = ""
    @State private var deleteTarget: DocumentStore.DocuLiteDocument?
    @State private var exportResultURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if selectedDoc != nil {
                editorDetail
            } else {
                emptyDetail
            }
        }
        .onAppear {
            if store.workspaceURL != nil, selectedDoc == nil {
                selectedDoc = store.documents.first
            }
        }
        .onChange(of: selectedDoc) { newDoc in
            guard let doc = newDoc else {
                editorHTML = ""
                previewHTML = ""
                return
            }
            let html = store.loadHTML(for: doc) ?? "<p><br></p>"
            editorHTML = html
            previewHTML = html
            documentToken = UUID()
            saveStatus = "已保存"
        }
        .onChange(of: store.documents) { _ in
            // 工作区变化 / 删除 / 重命名后保持选中有效
            if let current = selectedDoc,
               !store.documents.contains(where: { $0.id == current.id }) {
                selectedDoc = nil
            }
            if selectedDoc == nil {
                selectedDoc = store.documents.first
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .doculiteSave)) { _ in
            saveNow()
        }
        .alert("新建文档", isPresented: $showNewDocAlert) {
            TextField("文档名称", text: $newDocName)
            Button("创建") {
                if let doc = store.createDocument(named: newDocName) {
                    switchDocument(to: doc)
                }
                newDocName = "未命名文档"
            }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名文档", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("新名称", text: $renameText)
            Button("重命名") {
                guard let target = renameTarget else { return }
                do {
                    try store.renameDocument(target, to: renameText)
                    if selectedDoc?.id == target.id {
                        selectedDoc = store.documents.first(where: { $0.name == renameText.trimmingCharacters(in: .whitespaces) })
                            ?? store.documents.first
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .alert("删除文档", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("删除", role: .destructive) {
                guard let target = deleteTarget else { return }
                do {
                    try store.deleteDocument(target)
                } catch {
                    errorMessage = error.localizedDescription
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget.map { "确定删除「\($0.name)」？此操作不可撤销。" } ?? "")
        }
        .alert("导出完成", isPresented: Binding(
            get: { exportResultURL != nil },
            set: { if !$0 { exportResultURL = nil } }
        )) {
            Button("好", role: .cancel) { exportResultURL = nil }
            Button("在 Finder 中显示") {
                if let url = exportResultURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                exportResultURL = nil
            }
        } message: {
            Text(exportResultURL.map { "已导出到：\($0.path)" } ?? "")
        }
        .alert("出错了", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.workspaceURL?.lastPathComponent ?? "工作区")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    showNewDocAlert = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新建文档")
                .disabled(store.workspaceURL == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.workspaceURL == nil {
                emptyWorkspace
            } else if store.documents.isEmpty {
                Text("工作区还没有文档\n点击上方 + 创建")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.documents, selection: $selectedDoc) { doc in
                    Label(doc.name, systemImage: "doc.text")
                        .lineLimit(1)
                        .tag(doc)
                        .contextMenu {
                            Button("重命名…") {
                                renameText = doc.name
                                renameTarget = doc
                            }
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([doc.url])
                            }
                            Divider()
                            Button("删除…", role: .destructive) {
                                deleteTarget = doc
                            }
                        }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("未选择工作区\n选择一个本地文件夹来存放你的文档")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开工作区…") {
                store.chooseWorkspace()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - 详情区

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            if store.workspaceURL == nil {
                Image(systemName: "folder")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("先在侧边栏选择一个工作区文件夹")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("打开工作区…") { store.chooseWorkspace() }
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("选择或新建一个文档开始写作")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorDetail: some View {
        VStack(spacing: 0) {
            Divider()
            HSplitView {
                EditorWebView(
                    htmlToLoad: editorHTML,
                    documentURL: selectedDoc?.url,
                    token: documentToken,
                    bridge: bridge,
                    importImageHandler: { dataURL in
                        guard let doc = selectedDoc else { return nil }
                        return try store.importImage(dataURL: dataURL, for: doc)
                    },
                    onContentChanged: {
                        saveNow()
                    },
                    onSelectionState: { dictionary in
                        selectionState = EditorSelectionState(dictionary: dictionary)
                    }
                )
                .frame(minWidth: 360)

                PreviewWebView(
                    htmlFragment: previewHTML,
                    documentURL: selectedDoc?.url,
                    token: documentToken
                )
                .frame(minWidth: 320)
            }
        }
        .toolbar { toolbarContent }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            toggleButton(icon: "bold", active: selectionState.bold, help: "加粗") {
                bridge.exec("bold")
            }
            toggleButton(icon: "italic", active: selectionState.italic, help: "斜体") {
                bridge.exec("italic")
            }
            toggleButton(icon: "underline", active: selectionState.underline, help: "下划线") {
                bridge.exec("underline")
            }
            toggleButton(icon: "strikethrough", active: selectionState.strikeThrough, help: "删除线") {
                bridge.exec("strikeThrough")
            }

            headingMenu

            toggleButton(icon: "list.bullet", active: selectionState.insertUnorderedList, help: "无序列表") {
                bridge.exec("insertUnorderedList")
            }
            toggleButton(icon: "list.number", active: selectionState.insertOrderedList, help: "有序列表") {
                bridge.exec("insertOrderedList")
            }

            toggleButton(icon: "align.horizontal.left", active: selectionState.justifyLeft, help: "左对齐") {
                bridge.exec("justifyLeft")
            }
            toggleButton(icon: "align.horizontal.center", active: selectionState.justifyCenter, help: "居中对齐") {
                bridge.exec("justifyCenter")
            }
            toggleButton(icon: "align.horizontal.right", active: selectionState.justifyRight, help: "右对齐") {
                bridge.exec("justifyRight")
            }

            Button {
                insertImages(copyMode: false)
            } label: {
                Label("插入图片", systemImage: "photo")
            }
            .help("插入图片（链接原图，不复制到工作区）")

            Button {
                exportSelectedDocument()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .help("导出为独立文件夹（文档 + 全部图片拷贝，链接转为相对链接）")

            Button {
                saveNow()
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .help("保存（⌘S）")

            Text(saveStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("构建时间：\(kBuildTime)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }

    private var headingMenu: some View {
        Menu {
            Button("正文") { bridge.exec("formatBlock", "p") }
            Button("标题 1") { bridge.exec("formatBlock", "h1") }
            Button("标题 2") { bridge.exec("formatBlock", "h2") }
            Button("标题 3") { bridge.exec("formatBlock", "h3") }
            Button("引用") { bridge.exec("formatBlock", "blockquote") }
        } label: {
            Text(selectionState.headingDisplayName)
                .frame(minWidth: 52)
        }
        .help("段落格式")
    }

    private func toggleButton(icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .fontWeight(active ? .semibold : .regular)
        }
        .help(help)
    }

    // MARK: - 动作

    /// 切换文档：统一交给 onChange(of: selectedDoc) 加载。
    private func switchDocument(to doc: DocumentStore.DocuLiteDocument) {
        selectedDoc = doc
    }

    /// 从编辑器取回最新 HTML 并保存，同步推送预览。
    private func saveNow() {
        guard let doc = selectedDoc else { return }
        saveStatus = "保存中…"
        Task { @MainActor in
            let html = (try? await bridge.getHTML()) ?? editorHTML
            editorHTML = html
            store.saveHTML(html, for: doc)
            previewHTML = html
            saveStatus = "已保存"
        }
    }

    /// copyMode=true：图片拷贝进文档 assets/；false：仅记录原图绝对路径（不占空间）。
    private func insertImages(copyMode: Bool) {
        guard let doc = selectedDoc else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        var imageTypes: [UTType] = [.png, .jpeg, .gif, .heic, .bmp]
        if let webp = UTType(filenameExtension: "webp") {
            imageTypes.append(webp)
        }
        panel.allowedContentTypes = imageTypes
        panel.title = copyMode ? "插入副本" : "链接原图"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if copyMode {
                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension.lowercased()
                let mime: String
                switch ext {
                case "jpg", "jpeg": mime = "image/jpeg"
                case "gif": mime = "image/gif"
                case "webp": mime = "image/webp"
                case "heic": mime = "image/heic"
                case "bmp": mime = "image/bmp"
                default: mime = "image/png"
                }
                let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
                do {
                    if let relativePath = try store.importImage(dataURL: dataURL, for: doc) {
                        bridge.insertImage(relativePath)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else {
                if let absolutePath = store.linkImage(at: url) {
                    bridge.insertImage(absolutePath)
                } else {
                    errorMessage = "无法读取图片：\(url.lastPathComponent)"
                }
            }
        }
    }

    private func exportSelectedDocument() {
        guard let doc = selectedDoc else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "导出到此"
        panel.title = "选择导出位置"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor in
            let html = (try? await bridge.getHTML()) ?? editorHTML
            editorHTML = html
            store.saveHTML(html, for: doc)
            previewHTML = html
            do {
                let out = try store.exportDocument(doc, htmlFragment: html, toFolder: destination)
                exportResultURL = out
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DocumentStore())
}
