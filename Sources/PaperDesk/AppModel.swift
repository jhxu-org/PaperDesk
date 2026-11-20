import SwiftUI
import AppKit
import PDFKit
import PaperDeskCore

struct OutlineEntry: Identifiable {
    let id = UUID()
    let title: String
    let page: Int
    let depth: Int
}

@MainActor
final class AppModel: ObservableObject {
    @Published var documents: [LibraryDocument] = []
    @Published var folders: [LibraryFolder] = []
    @Published var folderFilter = "all"
    @Published var showFolderEditor = false
    @Published var editingFolder: LibraryFolder?
    @Published var folderEditorParentID: String?
    @Published var expandedFolderIDs = Set<String>()
    @Published var showStorageSettings = false
    @Published var isMovingStorage = false
    @Published var storageProgress = 0.0
    @Published var storageStatus = ""
    @Published var storageError: String?
    @Published var cloudBackupEnabled: Bool {
        didSet { defaults.set(cloudBackupEnabled, forKey: "cloudBackupEnabled") }
    }
    private let libraryLocation: LibraryLocation
    private var storageTask: Task<Void, Never>?
    private var deferredOpenURLs: [URL] = []
    var storagePath: String { repository?.root.path ?? libraryLocation.configuredPath }
    var storageBusyReason: String? {
        if isAsking { return "请等当前对话完成或停止生成后，再切换存储位置。" }
        if cloud.busy { return "请等网盘操作完成后，再切换存储位置。" }
        if importing || importQueue.activeCount > 0 { return "请等后台导入完成或取消任务后，再切换存储位置。" }
        return nil
    }
    @Published var libraryQuery = ""
    @Published var showPaperSearch = false
    let paperSearch = PaperSearchModel()
    let importQueue = PaperImportQueue()
    let cloud = CloudModel()
    var folderHierarchy: FolderHierarchy { FolderHierarchy(folders) }
    var folderTitle: String { folderFilter == "all" ? "全部文献" : folderFilter == "unfiled" ? "未分类" : folderHierarchy.path(for: folderFilter) ?? "全部文献" }
    var destinationFolderID: String? { folders.first { $0.id == folderFilter }?.id }
    var visibleFolderEntries: [FolderEntry] {
        let hierarchy = folderHierarchy
        return hierarchy.entries.filter { hierarchy.ancestorIDs(of: $0.id).allSatisfy(expandedFolderIDs.contains) }
    }
    var folderDocumentCounts: [String: Int] {
        var counts = Dictionary(grouping: documents.compactMap(\.folderID), by: { $0 }).mapValues(\.count)
        for entry in folderHierarchy.entries.reversed() {
            if let parent = entry.folder.parentID { counts[parent, default: 0] += counts[entry.id, default: 0] }
        }
        return counts
    }
    @Published var selectedID: String?
    @Published var pdfDocument: PDFDocument?
    @Published var notes: [ReadingNote] = []
    @Published var messages: [ChatMessage] = []
    @Published var outline: [OutlineEntry] = []
    @Published var currentPage = 0
    @Published var selectedText = ""
    @Published var searchText = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var searchIndex = 0
    @Published var isSearching = false
    @Published var searchAttempted = false
    @Published var isIndexing = false
    @Published var isAsking = false
    @Published var importing = false
    @Published var showImporter = false
    @Published var showSettings = false
    @Published var showBrowserExtension = false
    @Published var showInspector = true
    @Published var inspectorTab = "assistant"
    @Published var sidebarTab = "library"
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published var draftQuestion = ""
    @Published var isConfigured = false
    @Published var baseURL = ""
    @Published var modelName = ""
    @Published var apiKey = ""
    @Published var credentialError: String?
    @Published var chunks: [SourceChunk] = []
    @Published var chatScope: ChatScope = .automatic
    @Published var streamingMessage: ChatMessage?
    @Published var chatError: String?
    @Published var streamResponses = true
    @Published var sendPageImages = false
    @Published var isChatFloating = false
    @Published var pinnedChatSelection: [SourceChunk] = []
    private var floatingChat: FloatingChatController?

    private(set) var repository: DocumentRepository?
    weak var pdfView: PDFView?
    private var indexTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var retryRequest: PreparedChat?
    private let defaults: UserDefaults
    let isUITesting: Bool
    var selectedDocument: LibraryDocument? { documents.first { $0.id == selectedID } }
    var canAsk: Bool { selectedID != nil && !isIndexing && !isAsking && !chunks.isEmpty && isConfigured }
    var resolvedDraftScope: ChatScope {
        ChatContextBuilder.resolvedScope(chatScope, question: draftQuestion, hasSelection: !chatSelectionText.isEmpty)
    }
    var showsChatSelection: Bool { !chatSelectionText.isEmpty && (chatScope == .selection || chatScope == .automatic) }
    var chatSelectionLabel: String {
        guard !pinnedChatSelection.isEmpty else { return "当前选区" }
        let pages = Array(Set(pinnedChatSelection.map(\.page))).sorted().map { String($0 + 1) }.joined(separator: "、")
        return "固定选区 · 第 \(pages) 页"
    }
    var chatScopeLabel: String {
        if chatScope == .automatic {
            if draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "自动识别问题范围" }
            return "自动 · " + (resolvedDraftScope == .currentPage ? "当前页（第 \(currentPage + 1) 页）" : resolvedDraftScope.title)
        }
        if chatScope == .currentPage { return "当前页 · 第 \(currentPage + 1) 页" }
        if chatScope == .selection, !pinnedChatSelection.isEmpty {
            return chatSelectionLabel
        }
        return chatScope.title
    }
    var chatSelectionText: String {
        pinnedChatSelection.isEmpty ? selectedText : pinnedChatSelection.map(\.text).joined(separator: "\n")
    }
    private struct PreparedChat {
        let documentID: String
        let title: String
        let question: String
        let sources: [SourceChunk]
        let selection: String
        let history: [ChatMessage]
        let context: ChatContext
        let visuals: [ChatVisual]
        let documentURL: URL
    }

    init() {
        isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing") || Bundle.main.bundleIdentifier == "com.paperdesk.mac.uitests"
        defaults = isUITesting ? UserDefaults(suiteName: "com.paperdesk.mac.tests")! : .standard
        cloudBackupEnabled = defaults.object(forKey: "cloudBackupEnabled") as? Bool ?? !(defaults.string(forKey: "baiduAppKey") ?? "").isEmpty
        let defaultRoot = isUITesting ? FileManager.default.temporaryDirectory.appending(path: "PaperDesk-UITests") :
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/PaperDesk")
        libraryLocation = LibraryLocation(defaultRoot: defaultRoot, defaults: defaults)
        expandedFolderIDs = Set(defaults.stringArray(forKey: "expandedFolderIDs") ?? [])
        baseURL = defaults.string(forKey: "apiBaseURL") ?? ""
        modelName = defaults.string(forKey: "apiModel") ?? ""
        if !defaults.bool(forKey: "keychainPerEndpoint"), defaults.string(forKey: "legacyKeyEndpoint") == nil,
           let account = APIConfiguration(baseURL: baseURL, model: "", apiKey: "").credentialAccount {
            defaults.set(account, forKey: "legacyKeyEndpoint")
        }
        streamResponses = defaults.object(forKey: "apiStreamResponses") as? Bool ?? true
        sendPageImages = visualInputEnabled(baseURL: baseURL, modelName: modelName)
        // Read Keychain only when the user opens settings or sends a request.
        isConfigured = !baseURL.isEmpty && !modelName.isEmpty
        do {
            let root = try libraryLocation.resolve()
            repository = try DocumentRepository(root: root)
            if let repository {
                importQueue.configure(repository: repository)
                importQueue.onImported = { [weak self] _ in
                    guard let self else { return }
                    self.persistProgress()
                    do { try self.refreshLibrary() } catch { self.errorMessage = error.localizedDescription }
                }
            }
            try refreshLibrary()
            if isUITesting { openDemo() }
            else if let lastID = defaults.string(forKey: "lastDocument"), documents.contains(where: { $0.id == lastID }) {
                openDocument(id: lastID)
            }
        } catch {
            storageError = "文献库初始化失败：\(error.localizedDescription)"
            showStorageSettings = true
        }
    }

    func moveStorage(to destination: URL) {
        guard !isMovingStorage, storageBusyReason == nil, let repository else { return }
        storageError = nil
        // Save the latest page before taking the SQLite snapshot, then keep the library quiescent.
        do {
            if var document = selectedDocument {
                document.currentPage = currentPage
                try repository.database.save(document)
            }
        } catch { storageError = "无法保存当前阅读进度：\(error.localizedDescription)"; return }
        progressTask?.cancel(); closeFloatingChat()
        isMovingStorage = true; storageProgress = 0; storageStatus = "正在创建书库副本…"
        storageTask = Task {
            let access = destination.deletingLastPathComponent().startAccessingSecurityScopedResource()
            defer {
                if access { destination.deletingLastPathComponent().stopAccessingSecurityScopedResource() }
                finishStorageOperation()
            }
            do {
                let transfer = try LibraryTransfer(repository: repository, destination: destination)
                defer { transfer.discardStaging() }
                let worker = Task.detached(priority: .utility) {
                    try await transfer.copyFiles { done, total in
                        await self.updateStorageProgress(done, total)
                    }
                }
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                let next = try transfer.commit()
                try libraryLocation.use(next.root)
                try activateLibrary(next, preserveDraft: true)
                storageProgress = 1
                storageStatus = "已使用新位置。原位置保留副本，之后的修改只写入新位置。"
            } catch is CancellationError { storageStatus = "已取消，继续使用原来的书库。" }
            catch { storageError = "切换未完成，继续使用原书库：\(error.localizedDescription)"; storageStatus = "" }
        }
    }
    private func updateStorageProgress(_ done: Int, _ total: Int) {
        storageProgress = Double(done) / Double(max(total, 1))
        storageStatus = "正在复制并校验论文 \(done) / \(total)…"
    }
    func cancelStorageMove() { storageTask?.cancel() }
    func useExistingLibrary(at root: URL) {
        guard !isMovingStorage, storageBusyReason == nil else { return }
        storageError = nil
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        do {
            try LibraryLocation.validate(root)
            let next = try DocumentRepository(root: root)
            // Decode before replacing any active state or preferences.
            _ = try next.database.documents(); _ = try next.database.folders()
            persistProgress(); closeFloatingChat()
            try libraryLocation.use(root)
            try activateLibrary(next, preserveDraft: false)
            storageStatus = "已打开所选书库。之后的导入和笔记保存在此位置。"
            importPendingBrowserFiles()
        } catch { storageError = error.localizedDescription }
    }
    func retryStorageLocation() {
        do { useExistingLibrary(at: try libraryLocation.resolve()) }
        catch { storageError = error.localizedDescription }
    }
    private func activateLibrary(_ next: DocumentRepository, preserveDraft: Bool) throws {
        let items = try next.database.documents(), newFolders = try next.database.folders()
        let previousID = selectedID, draft = draftQuestion
        indexTask?.cancel(); searchTask?.cancel(); progressTask?.cancel()
        repository = next; importQueue.configure(repository: next)
        importQueue.clearFinished()
        documents = items; folders = newFolders
        selectedID = nil; pdfDocument = nil; notes = []; messages = []; outline = []; chunks = []
        isIndexing = false; selectedText = ""; pinnedChatSelection = []; draftQuestion = ""
        if let id = previousID, items.contains(where: { $0.id == id }) { openDocument(id: id) }
        else if let first = items.first { openDocument(id: first.id) }
        if preserveDraft { draftQuestion = draft }
        try refreshLibrary()
    }
    private func finishStorageOperation() {
        isMovingStorage = false; storageTask = nil
        let urls = deferredOpenURLs; deferredOpenURLs = []
        for url in urls { handleOpenURL(url) }
        importPendingBrowserFiles()
    }

    func refreshLibrary() throws {
        documents = try repository?.database.documents() ?? []
        folders = try repository?.database.folders() ?? []
        expandedFolderIDs.formIntersection(folders.map(\.id))
        if folderFilter != "all", folderFilter != "unfiled", !folders.contains(where: { $0.id == folderFilter }) { folderFilter = "all" }
    }
    func openPaperSearch() {
        guard !isMovingStorage else { return }
        showPaperSearch = true
    }
    var suggestedPaperImportFolder: String {
        if let saved = defaults.string(forKey: "arxivImportFolder"), saved.isEmpty || folders.contains(where: { $0.id == saved }) {
            return saved
        }
        return destinationFolderID ?? ""
    }
    func rememberPaperImportFolder(_ id: String) {
        defaults.set(id, forKey: "arxivImportFolder")
    }
    func editFolder(_ folder: LibraryFolder? = nil, parentID: String? = nil) {
        guard !isMovingStorage else { return }
        editingFolder = folder
        folderEditorParentID = folder != nil ? folder?.parentID : (parentID ?? destinationFolderID)
        showFolderEditor = true
    }
    func toggleFolderExpansion(_ id: String) {
        if !expandedFolderIDs.insert(id).inserted { expandedFolderIDs.remove(id) }
        defaults.set(Array(expandedFolderIDs), forKey: "expandedFolderIDs")
    }
    func saveFolder(name: String, parentID: String?) throws {
        var folder = editingFolder ?? LibraryFolder(name: name)
        folder.name = name
        folder.parentID = parentID
        try persistFolder(folder)
        folderFilter = folder.id; sidebarTab = "library"; showFolderEditor = false
    }
    func createFolder(name: String, parentID: String?) throws -> LibraryFolder {
        let folder = LibraryFolder(name: name, parentID: parentID)
        try persistFolder(folder)
        return folder
    }
    private func persistFolder(_ folder: LibraryFolder) throws {
        guard !isMovingStorage else { throw PaperDeskError.message("正在迁移书库，请稍后再创建或修改文件夹。") }
        guard let repository else { throw PaperDeskError.message("书库尚未就绪。") }
        try repository.database.save(folder); try refreshLibrary()
        expandedFolderIDs.formUnion(folderHierarchy.ancestorIDs(of: folder.id))
        defaults.set(Array(expandedFolderIDs), forKey: "expandedFolderIDs")
    }
    func deleteFolder(_ folder: LibraryFolder) {
        do { try repository?.database.deleteFolder(id: folder.id); try refreshLibrary(); notify("文件夹及子目录已删除，论文、笔记和对话均已保留") }
        catch { errorMessage = error.localizedDescription }
    }
    func moveDocument(_ id: String, to folderID: String?) {
        do { persistProgress(); try repository?.database.moveDocument(id: id, to: folderID); try refreshLibrary() }
        catch { errorMessage = error.localizedDescription }
    }
    private func classifyNewImport(_ document: LibraryDocument) throws {
        if !documents.contains(where: { $0.id == document.id }), let destinationFolderID {
            try repository?.database.moveDocument(id: document.id, to: destinationFolderID)
        }
    }
    func cloudRestoreCompleted() {
        do {
            try refreshLibrary()
            if let selectedID { notes = try repository?.database.notes(documentID: selectedID) ?? [] }
            else if let first = documents.first { openDocument(id: first.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func handleOpenURL(_ url: URL) {
        if isMovingStorage { deferredOpenURLs.append(url); return }
        if url.isFileURL { importFiles([url]); return }
        do {
            let id = try BrowserImportInbox.importID(from: url)
            importBrowserFile(id: id)
        } catch { errorMessage = error.localizedDescription }
    }

    func importPendingBrowserFiles() {
        guard !isMovingStorage, repository != nil else { return }
        // Chrome's native host always stages in Application Support, independent of the selected library.
        for id in BrowserImportInbox(root: libraryLocation.defaultRoot).pendingIDs() { importBrowserFile(id: id) }
    }

    private func importBrowserFile(id: String) {
        guard let repository else { return }
        let inbox = BrowserImportInbox(root: libraryLocation.defaultRoot)
        do {
            // A launch can deliver both activation and openURL; consume each job once.
            if FileManager.default.fileExists(atPath: try inbox.receiptURL(id).path) { return }
            guard FileManager.default.fileExists(atPath: try inbox.directory(id).appending(path: "ready.json").path) else { return }
            let metadata = try inbox.metadata(id)
            let file = try inbox.directory(id).appending(path: "document.pdf")
            let document = try repository.importPDF(from: file, title: metadata.title, sourceURL: metadata.sourceURL)
            try classifyNewImport(document)
            try refreshLibrary(); openDocument(id: document.id)
            try inbox.finish(id, receipt: BrowserImportReceipt(ok: true, message: "已加入 PaperDesk：\(document.title)"))
            notify("已从 Chrome 导入文献")
        } catch {
            let message = "浏览器导入失败：\(error.localizedDescription)"
            try? inbox.finish(id, receipt: BrowserImportReceipt(ok: false, message: message))
            errorMessage = message
        }
    }

    func importFiles(_ urls: [URL]) {
        if isMovingStorage { deferredOpenURLs.append(contentsOf: urls); return }
        guard let repository else { return }
        importing = true
        var last: LibraryDocument?
        var failures: [String] = []
        for url in urls {
            do { let imported = try repository.importPDF(from: url); try classifyNewImport(imported); last = imported }
            catch { failures.append(error.localizedDescription) }
        }
        do { try refreshLibrary() } catch { failures.append(error.localizedDescription) }
        importing = false
        if let last { openDocument(id: last.id); notify("文献已加入本地书库") }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func openDocument(id: String) {
        guard id != selectedID, let repository, var document = documents.first(where: { $0.id == id }) else { return }
        persistProgress()
        guard let pdf = PDFDocument(url: repository.url(for: document)), !pdf.isLocked else {
            errorMessage = "找不到这份 PDF，或文档无法打开。"; return
        }
        closeFloatingChat()
        pinnedChatSelection = []
        chatScope = .automatic
        indexTask?.cancel(); chatTask?.cancel(); searchTask?.cancel(); progressTask?.cancel()
        activeRequestID = nil; streamingMessage = nil; retryRequest = nil; chatError = nil
        isAsking = false; isSearching = false; searchAttempted = false
        selectedID = id; pdfDocument = pdf; currentPage = min(max(0, document.currentPage), max(0, pdf.pageCount - 1))
        selectedText = ""; searchText = ""; searchResults = []; chunks = []; draftQuestion = ""
        outline = outlineEntries(pdf.outlineRoot, document: pdf)
        do {
            notes = try repository.database.notes(documentID: id)
            messages = try repository.database.messages(documentID: id)
            document.lastOpenedAt = Date(); try repository.database.save(document); try refreshLibrary()
            defaults.set(id, forKey: "lastDocument")
        } catch { notes = []; messages = []; errorMessage = error.localizedDescription }
        let url = repository.url(for: document)
        isIndexing = true
        indexTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { try PDFTextExtractor.extract(from: url) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.selectedID == id else { return }
                self.chunks = result; self.isIndexing = false
            } catch is CancellationError { }
            catch {
                guard let self, self.selectedID == id, !Task.isCancelled else { return }
                self.isIndexing = false; self.errorMessage = "正文提取失败：\(error.localizedDescription)"
            }
        }
    }

    func outlineEntries(_ root: PDFOutline?, document: PDFDocument, depth: Int = 0) -> [OutlineEntry] {
        guard let root else { return [] }
        var result: [OutlineEntry] = []
        for i in 0..<root.numberOfChildren {
            guard let item = root.child(at: i) else { continue }
            if let page = (item.destination ?? (item.action as? PDFActionGoTo)?.destination)?.page {
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound { result.append(OutlineEntry(title: item.label ?? "未命名章节", page: pageIndex, depth: depth)) }
            }
            result += outlineEntries(item, document: document, depth: depth + 1)
        }
        return result
    }

    func pageChanged(_ page: Int) {
        guard currentPage != page else { return }
        currentPage = page
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.persistProgress()
        }
    }
    func persistProgress() {
        guard !isMovingStorage, let repository, var document = selectedDocument else { return }
        document.currentPage = currentPage
        do {
            try repository.database.save(document)
            if let i = documents.firstIndex(where: { $0.id == document.id }) { documents[i] = document }
        } catch { errorMessage = error.localizedDescription }
    }
    func goToPage(_ page: Int) {
        guard let target = pdfDocument?.page(at: page) else { return }
        if pdfView?.document === pdfDocument { pdfView?.go(to: target) }
        pageChanged(page)
    }
    func jump(to source: SourceChunk) {
        guard let page = pdfDocument?.page(at: source.page) else { return }
        let length = (page.string ?? "" as String).utf16.count
        if source.characterOffset < length,
           let selection = page.selection(for: NSRange(location: source.characterOffset, length: min(source.text.utf16.count, length - source.characterOffset))) {
            pdfView?.setCurrentSelection(selection, animate: true)
            pdfView?.go(to: selection)
            selectedText = selection.string ?? ""
        } else { goToPage(source.page) }
        pageChanged(source.page)
        if isChatFloating { pdfView?.window?.makeKeyAndOrderFront(nil) }
    }
    func showVisualInPDF(_ visual: ChatVisual) {
        guard let page = pdfDocument?.page(at: visual.page) else { return }
        if let source = visual.source { jump(to: source) }
        else { pdfView?.clearSelection(); selectedText = "" }
        // Show the whole original page, with the caption selected where its text range is known.
        pdfView?.go(to: page)
        pageChanged(visual.page)
        pdfView?.window?.makeKeyAndOrderFront(nil)
        notify("第 \(visual.page + 1) 页原文\(visual.source == nil ? "" : " · 已标出相关文字")")
    }
    func documentURL(for id: String) -> URL? {
        guard let document = documents.first(where: { $0.id == id }) else { return nil }
        return repository?.url(for: document)
    }
    func jump(to note: ReadingNote) {
        guard let page = pdfDocument?.page(at: note.page) else { return }
        pdfView?.clearSelection(); selectedText = ""
        if let rect = note.rects.first {
            pdfView?.go(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), on: page)
        } else { pdfView?.go(to: page) }
        pageChanged(note.page)
    }

    func highlightSelection() {
        guard !isMovingStorage else { return }
        guard let id = selectedID, let selection = pdfView?.currentSelection,
              let pdfDocument, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notify("先在 PDF 中选中一段文字"); return
        }
        do {
            for page in selection.pages {
                let lines = selection.selectionsByLine().filter { $0.pages.contains(page) }
                let rects = lines.map { $0.bounds(for: page) }.filter { !$0.isEmpty && !$0.isInfinite }
                    .map { PageRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
                let quote = lines.compactMap(\.string).joined(separator: "\n")
                let pageIndex = pdfDocument.index(for: page)
                guard !quote.isEmpty, pageIndex != NSNotFound else { continue }
                let note = ReadingNote(documentID: id, page: pageIndex, quote: quote, rects: rects)
                try repository?.database.save(note)
            }
            notes = try repository?.database.notes(documentID: id) ?? []
            inspectorTab = "notes"; showInspector = true; notify("已保存高亮，可在右侧添加笔记")
        } catch { errorMessage = error.localizedDescription }
    }
    func updateNote(_ note: ReadingNote, body: String) {
        var edited = note; edited.body = body
        do {
            try repository?.database.save(edited)
            if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = edited }
        } catch { errorMessage = error.localizedDescription }
    }
    func deleteNote(_ note: ReadingNote) {
        do { try repository?.database.deleteNote(id: note.id); notes.removeAll { $0.id == note.id } }
        catch { errorMessage = error.localizedDescription }
    }

    func search() {
        searchTask?.cancel()
        searchResults = []; searchIndex = 0; searchAttempted = true
        guard let document = selectedDocument, let repository else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { isSearching = false; searchAttempted = false; return }
        let url = repository.url(for: document)
        let id = document.id
        isSearching = true
        searchTask = Task { [weak self] in
            // Search an independent document in the background, then transfer only text ranges.
            let worker = Task.detached(priority: .userInitiated) { () -> [(Int, Int, Int)] in
                guard let pdf = PDFDocument(url: url) else { return [] }
                var results: [(Int, Int, Int)] = []
                for index in 0..<pdf.pageCount {
                    if Task.isCancelled { break }
                    let text = (pdf.page(at: index)?.string ?? "") as NSString
                    var range = NSRange(location: 0, length: text.length)
                    while range.length > 0 {
                        let found = text.range(of: query, options: .caseInsensitive, range: range)
                        if found.location == NSNotFound { break }
                        results.append((index, found.location, found.length))
                        let next = NSMaxRange(found)
                        range = NSRange(location: next, length: text.length - next)
                        if results.count >= 1_000 { return results }
                    }
                }
                return results
            }
            let results = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, !Task.isCancelled, self.selectedID == id else { return }
            self.searchResults = results.compactMap { page, start, length in
                self.pdfDocument?.page(at: page)?.selection(for: NSRange(location: start, length: length))
            }
            self.isSearching = false
            self.showSearchResult(0)
        }
    }
    func showSearchResult(_ index: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (index + searchResults.count) % searchResults.count
        let result = searchResults[searchIndex]
        pdfView?.setCurrentSelection(result, animate: true); pdfView?.go(to: result)
    }

    func openSettings() {
        guard !isMovingStorage else { return }
        credentialError = nil
        do { apiKey = try keyForSettings(baseURL: baseURL) }
        catch { apiKey = ""; credentialError = error.localizedDescription }
        showSettings = true
    }
    func keyForSettings(baseURL: String) throws -> String {
        let config = APIConfiguration(baseURL: baseURL, model: "", apiKey: "")
        guard let account = config.credentialAccount else { return "" }
        let legacy = defaults.string(forKey: "legacyKeyEndpoint") == account ? "api-key" : nil
        return try Keychain.read(account: account, legacyAccount: legacy) ?? ""
    }
    func remembersKey(baseURL: String) -> Bool {
        guard let account = APIConfiguration(baseURL: baseURL, model: "", apiKey: "").credentialAccount else { return true }
        return !Keychain.isSessionOnly(account: account)
    }
    func visualInputEnabled(baseURL: String, modelName: String) -> Bool {
        let key = (APIConfiguration(baseURL: baseURL, model: modelName, apiKey: "").credentialAccount ?? baseURL) + "|" + modelName
        return defaults.dictionary(forKey: "visionModels")?[key] as? Bool ?? false
    }
    func saveSettings(baseURL: String, modelName: String, apiKey: String, streamResponses: Bool, sendPageImages: Bool, rememberKey: Bool = true) throws {
        let config = APIConfiguration(baseURL: baseURL, model: modelName, apiKey: apiKey)
        _ = try config.endpoint()
        guard let account = config.credentialAccount else { throw PaperDeskError.message("模型地址无效。") }
        try Keychain.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: account, remember: rememberKey)
        if rememberKey {
            defaults.set(true, forKey: "keychainPerEndpoint")
            if defaults.string(forKey: "legacyKeyEndpoint") == account { defaults.removeObject(forKey: "legacyKeyEndpoint") }
        }
        defaults.set(streamResponses, forKey: "apiStreamResponses")
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "apiBaseURL")
        defaults.set(modelName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "apiModel")
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey
        self.streamResponses = streamResponses
        self.sendPageImages = sendPageImages
        var visionModels = defaults.dictionary(forKey: "visionModels") ?? [:]
        visionModels[account + "|" + self.modelName] = sendPageImages
        defaults.set(visionModels, forKey: "visionModels")
        credentialError = nil
        isConfigured = true; showSettings = false
        notify(rememberKey ? "模型设置已保存" : "模型设置已保存；API Key 仅在本次运行中使用")
    }

    func ask(_ prompt: String? = nil, scope: ChatScope? = nil) {
        guard !isMovingStorage, let document = selectedDocument, !isAsking else { return }
        let question = (prompt ?? draftQuestion).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        chatError = nil; retryRequest = nil; streamingMessage = nil
        let requestedScope = scope ?? chatScope
        if !isConfigured { draftQuestion = question; openSettings(); return }
        guard !isIndexing else { notify("正在提取正文，请稍候"); return }
        let selection = pinnedChatSelection.isEmpty ? currentSelectionSources() : pinnedChatSelection
        let resolvedScope = ChatContextBuilder.resolvedScope(requestedScope, question: question, hasSelection: !selection.isEmpty)
        let sources = ChatContextBuilder.sources(chunks: chunks, scope: requestedScope, page: currentPage,
            selection: selection, question: question, history: messages)
        let visuals = ChatVisualBuilder.candidates(chunks: chunks, sources: sources, scope: resolvedScope,
            page: currentPage, question: question, pageCount: document.pageCount)
        guard !sources.isEmpty || (sendPageImages && !visuals.isEmpty && resolvedScope == .currentPage) else {
            chatError = resolvedScope == .selection ? "请先在 PDF 中选中需要分析的文字。" : "当前范围没有可提取的文字。扫描件或纯图片页面可连接视觉模型，开启页面图片后选择“仅当前页”分析。"
            return
        }
        let selectionIDs = Set(selection.map(\.id))
        let selected = sources.filter { selectionIDs.contains($0.id) }.map(\.text).joined(separator: "\n")
        let contextPage = resolvedScope == .selection ? (sources.first?.page ?? currentPage) : currentPage
        let context = ChatContext(scope: resolvedScope, page: contextPage, sourcePages: Array(Set(sources.map(\.page) + visuals.map(\.page))),
            automaticallySelected: requestedScope == .automatic)
        guard let documentURL = repository?.url(for: document) else { return }
        let prepared = PreparedChat(documentID: document.id, title: document.title, question: question,
            sources: sources, selection: selected, history: messages, context: context, visuals: visuals, documentURL: documentURL)
        let userMessage = ChatMessage(documentID: document.id, role: "user", content: question, context: context)
        do { try repository?.database.save(userMessage) }
        catch { errorMessage = error.localizedDescription; return }
        messages.append(userMessage); draftQuestion = ""
        startAnswer(prepared)
    }

    func currentSelectionSources() -> [SourceChunk] {
        guard let selection = pdfView?.currentSelection, let pdf = pdfDocument else { return [] }
        var result: [SourceChunk] = []
        for page in selection.pages {
            let pageIndex = pdf.index(for: page)
            guard pageIndex != NSNotFound, let text = page.string else { continue }
            for index in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: index, on: page)
                guard range.location != NSNotFound, NSMaxRange(range) <= text.utf16.count else { continue }
                let selected = (text as NSString).substring(with: range)
                guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(SourceChunk(id: "p\(pageIndex + 1)s\(index + 1)", page: pageIndex,
                    text: selected, characterOffset: range.location))
            }
        }
        return result
    }

    func discussSelection() {
        guard !isAsking else { showFloatingChat(); return }
        let sources = currentSelectionSources()
        guard !sources.isEmpty else { notify("先在 PDF 中选中需要讨论的文字"); return }
        pinnedChatSelection = sources
        chatScope = .automatic
        showFloatingChat()
    }

    func askAboutCurrentSelection(_ prompt: String) {
        // PDF selection actions always target the newly selected text, even after a previous pinned discussion.
        guard !isAsking else { return }
        pinnedChatSelection = currentSelectionSources()
        ask(prompt, scope: .selection)
    }

    func clearChatSelection() {
        pinnedChatSelection = []
        pdfView?.clearSelection(); selectedText = ""
        chatScope = .automatic
    }

    func setChatScope(_ scope: ChatScope) {
        chatScope = scope
        if isChatFloating && scope == .selection && pinnedChatSelection.isEmpty {
            pinnedChatSelection = currentSelectionSources()
        }
    }

    func showFloatingChat() {
        guard !isMovingStorage else { return }
        guard selectedDocument != nil else { return }
        if chatScope == .selection && pinnedChatSelection.isEmpty { pinnedChatSelection = currentSelectionSources() }
        inspectorTab = "assistant"
        isChatFloating = true
        showInspector = false
        if floatingChat == nil { floatingChat = FloatingChatController(model: self) }
        floatingChat?.show()
    }

    func closeFloatingChat() { floatingChat?.close() }

    func floatingChatDidClose() {
        isChatFloating = false
        showInspector = true
        inspectorTab = "assistant"
    }

    func setFloatingChatPinned(_ pinned: Bool) { floatingChat?.setPinned(pinned) }

    private func startAnswer(_ prepared: PreparedChat) {
        guard prepared.documentID == selectedID else { return }
        let key: String
        retryRequest = prepared
        do { key = try keyForSettings(baseURL: baseURL) }
        catch { chatError = error.localizedDescription; return }
        let configuration = APIConfiguration(baseURL: baseURL, model: modelName, apiKey: key, streamResponses: streamResponses)
        let requestID = UUID()
        activeRequestID = requestID; chatError = nil; streamingMessage = nil
        isAsking = true; inspectorTab = "assistant"
        if !isChatFloating { showInspector = true }
        let answerID = UUID().uuidString
        let includeImages = sendPageImages
        chatTask = Task { [weak self] in
            do {
                var images: [ChatPageImage] = []
                if includeImages {
                    let worker = Task.detached(priority: .userInitiated) {
                        try ChatVisualBuilder.render(url: prepared.documentURL, visuals: prepared.visuals)
                    }
                    images = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    try Task.checkCancellation()
                }
                let answer = try await AIClient().reply(configuration: configuration, question: prepared.question,
                    title: prepared.title, sources: prepared.sources, selectedText: prepared.selection,
                    history: prepared.history, context: prepared.context, visuals: prepared.visuals, images: images) { [weak self] text in
                        await self?.receiveStream(text, answerID: answerID, requestID: requestID, prepared: prepared)
                    }
                try Task.checkCancellation()
                guard let self, self.activeRequestID == requestID, self.selectedID == prepared.documentID else { return }
                let message = ChatMessage(id: answerID, documentID: prepared.documentID, role: "assistant", content: answer,
                    sources: ContextBuilder.citedSources(in: answer, candidates: prepared.sources), context: prepared.context,
                    visuals: ChatVisualBuilder.cited(in: answer, candidates: prepared.visuals))
                try self.repository?.database.save(message)
                self.messages.append(message); self.isAsking = false; self.streamingMessage = nil
                self.activeRequestID = nil; self.retryRequest = nil
            } catch {
                guard let self, self.activeRequestID == requestID, !Task.isCancelled else { return }
                self.isAsking = false; self.activeRequestID = nil
                self.chatError = "回答未完成：\(error.localizedDescription)"
            }
        }
    }
    private func receiveStream(_ text: String, answerID: String, requestID: UUID, prepared: PreparedChat) {
        guard activeRequestID == requestID, selectedID == prepared.documentID else { return }
        streamingMessage = ChatMessage(id: answerID, documentID: prepared.documentID, role: "assistant", content: text,
            sources: ContextBuilder.citedSources(in: text, candidates: prepared.sources), context: prepared.context,
            visuals: ChatVisualBuilder.cited(in: text, candidates: prepared.visuals))
    }
    func retryAnswer() { if let retryRequest, !isAsking { startAnswer(retryRequest) } }
    var canRetryAnswer: Bool { retryRequest != nil && !isAsking }
    func cancelAnswer() {
        activeRequestID = nil; chatTask?.cancel(); isAsking = false
        chatError = "已停止生成；已显示的内容尚未完成。可重试同一个问题。"
    }

    func exportAnnotatedPDF() {
        guard let document = pdfDocument else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (selectedDocument?.title ?? "文献") + "-批注.pdf"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if document.write(to: url) { self?.notify("已导出带批注的 PDF") }
            else { self?.errorMessage = "导出失败，请检查保存位置。" }
        }
    }
    func exportNotes() {
        guard let document = selectedDocument else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.title + "-笔记.md"
        let content = "# \(document.title)\n\n" + notes.map {
            "## 第 \($0.page + 1) 页\n\n> \($0.quote.replacingOccurrences(of: "\n", with: "\n> "))\n\n\($0.body)\n"
        }.joined(separator: "\n")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try content.write(to: url, atomically: true, encoding: .utf8); self?.notify("笔记已导出") }
            catch { self?.errorMessage = error.localizedDescription }
        }
    }
    func notify(_ message: String) {
        toastTask?.cancel(); toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }
    func openDemo() {
        guard !isMovingStorage else { return }
        do { let url = try DemoDocument.make(); importFiles([url]) }
        catch { errorMessage = error.localizedDescription }
    }
}
