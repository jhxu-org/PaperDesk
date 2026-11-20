import SwiftUI
import PaperDeskCore

@MainActor
final class PaperSearchModel: ObservableObject {
    @Published var localHits: [LibrarySearchHit] = []
    @Published var searchingLocal = false
    @Published var unreadableCount = 0
    @Published var localError: String?
    @Published var articles: [ArxivArticle] = []
    @Published var remoteQuery = ""
    @Published var remoteTotal = 0
    @Published var nextStart = 0
    @Published var searchingRemote = false
    @Published var remoteAttempted = false
    @Published var remoteError: String?
    @Published var importError: String?
    private let index = LibrarySearchIndex()
    private let arxiv = ArxivClient()
    private var remoteTask: Task<Void, Never>?
    private var localGeneration = UUID()
    private var remoteGeneration = UUID()
    var hasMore: Bool { !articles.isEmpty && nextStart < min(remoteTotal, 1000) }

    func searchLocal(model: AppModel) async {
        let generation = UUID(); localGeneration = generation
        searchingLocal = true; localError = nil; localHits = []; unreadableCount = 0
        let query = model.libraryQuery
        let items = model.documents.compactMap { document in model.repository.map { LibrarySearchItem(document: document, url: $0.url(for: document)) } }
        do {
            try await Task.sleep(for: .milliseconds(200))
            let result = try await index.search(items, query: query)
            guard !Task.isCancelled, localGeneration == generation else { return }
            localHits = result.hits; unreadableCount = result.unreadableCount; searchingLocal = false
        } catch {
            guard !Task.isCancelled, localGeneration == generation else { return }
            searchingLocal = false; localError = error.localizedDescription
        }
    }
    func queryChanged() {
        remoteTask?.cancel(); remoteGeneration = UUID()
        searchingRemote = false; remoteAttempted = false; remoteError = nil
        articles = []; remoteTotal = 0; nextStart = 0; remoteQuery = ""
    }
    func searchArxiv(query: String, more: Bool = false) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !searchingRemote else { return }
        remoteTask?.cancel()
        let generation = UUID(); remoteGeneration = generation
        let start = more && query == remoteQuery ? nextStart : 0
        if start == 0 { articles = []; remoteTotal = 0; nextStart = 0 }
        remoteQuery = query; searchingRemote = true; remoteAttempted = true; remoteError = nil
        remoteTask = Task {
            do {
                let page = try await arxiv.search(query: query, start: start)
                guard !Task.isCancelled, remoteGeneration == generation else { return }
                let old = Set(articles.map(\.id))
                articles += page.articles.filter { !old.contains($0.id) }
                remoteTotal = page.total
                nextStart = page.articles.isEmpty ? page.total : start + page.articles.count
                searchingRemote = false
            } catch {
                guard !Task.isCancelled, remoteGeneration == generation else { return }
                searchingRemote = false; remoteError = Self.describe(error)
            }
        }
    }
    func importArticle(_ article: ArxivArticle, folderID: String?, model: AppModel) {
        if let saved = ArxivIdentifier.existing(article, in: model.documents) {
            model.openDocument(id: saved.id); model.showPaperSearch = false; return
        }
        do {
            try model.importQueue.enqueue(article, folderID: folderID)
            model.rememberPaperImportFolder(folderID ?? ""); importError = nil
        } catch { importError = Self.describe(error) }
    }
    func close() { remoteTask?.cancel(); searchingRemote = false; remoteGeneration = UUID() }
    private static func describe(_ error: Error) -> String {
        if let error = error as? URLError { return "无法连接 arXiv（\(error.code.rawValue)），请检查网络后重试。" }
        return error.localizedDescription
    }
}

struct PaperSearchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var search: PaperSearchModel
    @ObservedObject var imports: PaperImportQueue
    @FocusState private var focused: Bool
    @State private var pendingImport: ArxivArticle?
    private var query: String { model.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var localTaskID: String { model.libraryQuery + model.documents.map { $0.id + $0.title + ($0.arxiv?.id ?? "") }.joined() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("搜索文献").font(.title2.weight(.semibold))
                    Text("先查本地文献，也可以从 arXiv 发现并导入论文。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                ImportQueueButton(model: model, queue: imports)
                Button("完成") { model.showPaperSearch = false }.keyboardShortcut(.cancelAction)
            }.padding(24)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.accent)
                TextField("标题、作者、关键词或 arXiv 编号 / 链接", text: $model.libraryQuery)
                    .textFieldStyle(.plain).focused($focused).accessibilityLabel("文献搜索关键词")
                    .onSubmit { search.searchArxiv(query: query) }
                if !model.libraryQuery.isEmpty {
                    Button {
                        model.libraryQuery = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("清空搜索").accessibilityLabel("清空搜索")
                }
                Button { search.searchArxiv(query: query) } label: {
                    Label("搜索 arXiv", systemImage: "globe")
                }.buttonStyle(.borderedProminent).disabled(query.isEmpty || search.searchingRemote)
            }.padding(12).background(Palette.subtle, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 24)
            HStack(spacing: 10) {
                Text("点击“导入 PDF”后选择保存文件夹").foregroundStyle(.secondary)
                Spacer()
                Text("本地搜索覆盖所有文件夹").foregroundStyle(.secondary)
            }.font(.system(size: 11)).padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("本地文献", systemImage: "internaldrive").font(.headline)
                        Text("\(search.localHits.count)").foregroundStyle(.secondary)
                        if search.searchingLocal { ProgressView().controlSize(.small); Text("正在搜索正文…").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let error = search.localError { Text(error).foregroundStyle(.red) }
                    if !search.searchingLocal && search.localHits.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(query.isEmpty ? "还没有保存的论文。" : "本地没有找到匹配的论文。")
                            if !query.isEmpty {
                                Button("去 arXiv 搜索“\(query)”") { search.searchArxiv(query: query) }
                                    .disabled(search.searchingRemote)
                            }
                        }.font(.system(size: 13)).padding(.vertical, 8)
                    }
                    ForEach(search.localHits) { hit in localRow(hit) }
                    if search.unreadableCount > 0 {
                        Text("\(search.unreadableCount) 篇文献无法提取正文，仅匹配标题和已有元数据。扫描版 PDF 暂不支持文字搜索。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider().padding(.vertical, 8)
                    HStack {
                        Label("arXiv", systemImage: "globe").font(.headline)
                        if search.remoteAttempted && search.remoteError == nil { Text("\(search.remoteTotal) 篇").foregroundStyle(.secondary) }
                        if search.searchingRemote { ProgressView().controlSize(.small); Text("正在搜索…").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Link("arXiv.org", destination: URL(string: "https://arxiv.org")!).font(.caption)
                    }
                    if let error = search.remoteError {
                        HStack { Text(error).foregroundStyle(.red); Spacer(); Button("重试搜索") { search.searchArxiv(query: query, more: !search.articles.isEmpty) } }
                    } else if !search.remoteAttempted {
                        Text("输入英文关键词、作者或论文标题，然后点击“搜索 arXiv”。也支持粘贴论文链接或编号。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if !search.searchingRemote && search.articles.isEmpty {
                        Text("arXiv 没有匹配结果，试试英文关键词或论文编号。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(search.articles) { article in remoteRow(article) }
                    if search.hasMore {
                        Button("加载更多") { search.searchArxiv(query: query, more: true) }.disabled(search.searchingRemote)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }.padding(24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error = search.importError { Text(error).font(.caption).foregroundStyle(.red) }
                Text(imports.activeCount > 0 ? "\(imports.activeCount) 个任务正在后台导入。可以关闭此窗口继续阅读，点击右上角查看进度。" : "导入任务在后台执行，关闭此窗口后仍会继续。已保存的论文可直接打开。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }.frame(width: 840, height: 660)
            .onAppear { focused = true; if query != search.remoteQuery { search.queryChanged() } }
            .onChange(of: model.libraryQuery) { _, _ in search.queryChanged() }
            .task(id: localTaskID) { await search.searchLocal(model: model) }
            .onDisappear { search.close() }
            .sheet(item: $pendingImport) { article in
                PaperImportDestinationView(model: model, article: article, initialFolder: model.suggestedPaperImportFolder) { folder in
                    pendingImport = nil
                    search.importArticle(article, folderID: folder.isEmpty ? nil : folder, model: model)
                }
            }
    }
    private func localRow(_ hit: LibrarySearchHit) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "doc.text").foregroundStyle(Palette.accent).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text(hit.document.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                Text((hit.document.folderID.flatMap { model.folderHierarchy.path(for: $0) } ?? "未分类") + " · \(hit.document.pageCount) 页" + (hit.page.map { " · 匹配第 \($0 + 1) 页" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Text(hit.snippet).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 4)
            Button("打开") { model.openDocument(id: hit.id); if let page = hit.page { model.goToPage(page) }; model.showPaperSearch = false }
                .accessibilityLabel("打开本地论文：" + hit.document.title)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.subtle, in: RoundedRectangle(cornerRadius: 10))
    }
    private func remoteRow(_ article: ArxivArticle) -> some View {
        let existing = ArxivIdentifier.existing(article, in: model.documents)
        let active = imports.activeJob(for: article)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                Text(article.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                Spacer(minLength: 0)
                Button(existing != nil ? "已保存 · 打开" : active.map { $0.state.title } ?? "导入 PDF") {
                    if existing != nil { search.importArticle(article, folderID: nil, model: model) }
                    else { pendingImport = article }
                }
                    .disabled(existing == nil && active != nil)
                    .accessibilityLabel((existing != nil ? "打开已保存论文：" : active != nil ? "已加入后台导入：" : "导入论文：") + article.title)
            }
            Text(article.authors.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            Text("\(article.published.prefix(10)) · \(article.category) · arXiv:\(article.id)").font(.caption).foregroundStyle(.secondary)
            Text(article.summary).font(.system(size: 12)).lineLimit(4).textSelection(.enabled)
            DisclosureGroup("完整摘要") { Text(article.summary).font(.system(size: 12)).textSelection(.enabled).padding(.top, 6) }.font(.caption)
            Link("查看 arXiv 原文", destination: article.abstractURL).font(.caption)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.subtle, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PaperImportDestinationView: View {
    @ObservedObject var model: AppModel
    let article: ArxivArticle
    let onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folder: String
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var newFolderParent = ""
    @State private var folderError: String?
    @FocusState private var folderNameFocused: Bool
    init(model: AppModel, article: ArxivArticle, initialFolder: String, onImport: @escaping (String) -> Void) {
        self.model = model; self.article = article; self.onImport = onImport
        _folder = State(initialValue: initialFolder)
    }
    private var validFolder: Bool { folder.isEmpty || model.folders.contains { $0.id == folder } }
    private var validParent: Bool { newFolderParent.isEmpty || model.folders.contains { $0.id == newFolderParent } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("选择保存文件夹", systemImage: "folder.badge.plus").font(.title3.weight(.semibold))
            Text(article.title).font(.system(size: 14, weight: .medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker("保存到", selection: $folder) {
                    Text("未分类").tag("")
                    ForEach(model.folderHierarchy.entries) { entry in Text(entry.path).tag(entry.id) }
                }.pickerStyle(.menu).accessibilityLabel("论文保存文件夹").disabled(creatingFolder)
                Button {
                    newFolderName = ""; newFolderParent = validFolder ? folder : ""
                    folderError = nil; creatingFolder = true; folderNameFocused = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }.disabled(creatingFolder).accessibilityLabel("导入时新建文件夹")
            }
            if creatingFolder {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("文件夹名称", text: $newFolderName)
                        .textFieldStyle(.roundedBorder).focused($folderNameFocused)
                        .accessibilityLabel("新文件夹名称")
                    Picker("上级文件夹", selection: $newFolderParent) {
                        Text("文献库（顶层）").tag("")
                        ForEach(model.folderHierarchy.entries) { entry in Text(entry.path).tag(entry.id) }
                    }.pickerStyle(.menu).accessibilityLabel("新文件夹的上级目录")
                    Text("创建后自动选为保存位置，也可在已有目录下创建子文件夹。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !validParent {
                        Text("上级文件夹已不存在，请重新选择。").font(.caption).foregroundStyle(.red)
                    }
                    if let folderError { Text(folderError).font(.caption).foregroundStyle(.red) }
                    HStack {
                        Spacer()
                        Button("取消新建") { cancelFolderCreation() }.keyboardShortcut(.cancelAction)
                        Button("创建并选中") { createFolder() }
                            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !validParent)
                    }
                }.padding(14).background(Palette.subtle, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("确认后加入后台导入队列，可以继续搜索或阅读。下次会记住此次文件夹选择。")
                .font(.caption).foregroundStyle(.secondary)
            if !validFolder { Text("该文件夹已不存在，请重新选择保存位置。").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                if creatingFolder {
                    Button("取消导入") { dismiss() }
                } else {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("确认导入") { onImport(folder) }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).disabled(!validFolder)
                }
            }
        }.padding(24).frame(width: 480)
            .onChange(of: newFolderName) { _, _ in folderError = nil }
            .onChange(of: newFolderParent) { _, _ in folderError = nil }
    }
    private func cancelFolderCreation() {
        creatingFolder = false; folderError = nil; folderNameFocused = false
    }
    private func createFolder() {
        do {
            let created = try model.createFolder(name: newFolderName, parentID: newFolderParent.isEmpty ? nil : newFolderParent)
            folder = created.id
            cancelFolderCreation()
        } catch { folderError = error.localizedDescription }
    }
}
