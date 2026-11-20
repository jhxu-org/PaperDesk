import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct PaperDeskApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("PaperDesk", id: "main") {
            ContentView(model: model)
                .tint(Palette.accent)
                .onOpenURL { model.handleOpenURL($0) }
                .onAppear {
                    model.importPendingBrowserFiles()
                    Self.refreshApplicationIcon()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.importPendingBrowserFiles()
                    Self.refreshApplicationIcon()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.persistProgress() }
        }
        .defaultSize(width: 1440, height: 920)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 PaperDesk") {
                    let options: [NSApplication.AboutPanelOptionKey: Any] = Self.applicationIcon.map { [.applicationIcon: $0] } ?? [:]
                    NSApplication.shared.orderFrontStandardAboutPanel(options: options)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("导入 PDF…") { model.showImporter = true }.keyboardShortcut("o").disabled(model.isMovingStorage)
                Button("搜索文献与 arXiv…") { model.openPaperSearch() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("打开阅读示例") { model.openDemo() }
                Button("新建文件夹…") { model.editFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Chrome 扩展…") { model.showBrowserExtension = true }
                Button("存储设置…") { model.showStorageSettings = true }
            }
            CommandGroup(replacing: .appSettings) {
                Button("模型设置…") { model.openSettings() }.keyboardShortcut(",")
                Button("存储设置…") { model.showStorageSettings = true }
            }
            CommandMenu("阅读") {
                Button("在浮窗中讨论选区") { model.discussSelection() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                    .disabled(model.selectedText.isEmpty || model.isAsking)
                Button("在浮窗中打开对话") { model.showFloatingChat() }.disabled(model.pdfDocument == nil)
                Divider()
                Button("保存高亮") { model.highlightSelection() }.keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(model.pdfDocument == nil)
                Button("放大") { model.pdfView?.zoomIn(nil) }.keyboardShortcut("+")
                Button("缩小") { model.pdfView?.zoomOut(nil) }.keyboardShortcut("-")
                Button("适合窗口") { model.pdfView?.autoScales = true }.keyboardShortcut("0")
                Divider()
                Button("导出带批注的 PDF…") { model.exportAnnotatedPDF() }.disabled(model.pdfDocument == nil)
                Button("导出 Markdown 笔记…") { model.exportNotes() }.disabled(model.notes.isEmpty)
            }
        }
    }

    private static var applicationIcon: NSImage? {
        Bundle.main.url(forResource: "PaperDeskLogo", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
    }
    private static func refreshApplicationIcon() {
        // Local app updates can leave the old Launch Services icon cached.
        if let icon = applicationIcon { NSApplication.shared.applicationIconImage = icon }
    }
}

enum Palette {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.48, green: 0.76, blue: 0.73, alpha: 1)
        }
        return NSColor(calibratedRed: 0.17, green: 0.39, blue: 0.41, alpha: 1)
    })
    static let subtle = Color(nsColor: .controlBackgroundColor)
    static let separator = Color.primary.opacity(0.08)
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HSplitView {
            LibrarySidebar(model: model).frame(minWidth: 210, idealWidth: 230, maxWidth: 260)
            Group {
                if model.pdfDocument != nil { ReaderPane(model: model) }
                else { WelcomeView(model: model) }
            }.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            if model.showInspector && model.pdfDocument != nil {
                InspectorPane(model: model).frame(minWidth: 320, idealWidth: 380, maxWidth: 560)
            }
        }
        .frame(minWidth: model.showInspector && model.pdfDocument != nil ? 1100 : 760, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowZoomArea(includesTitleBar: true, includesContentArea: false))
        .disabled(model.isMovingStorage)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { model.openPaperSearch() } label: { Label("搜索文献与 arXiv", systemImage: "magnifyingglass") }
                    .help("搜索本地文献与 arXiv（⌘⇧F）")
                ImportQueueButton(model: model, queue: model.importQueue)
                Button { model.showImporter = true } label: { Label("导入 PDF", systemImage: "plus") }
                    .help("导入 PDF（⌘O）").disabled(model.isMovingStorage)
                Button { model.openSettings() } label: { Label("模型设置", systemImage: "slider.horizontal.3") }
                Button { model.showFloatingChat() } label: { Label("阅读助手浮窗", systemImage: "macwindow.on.rectangle") }
                    .disabled(model.pdfDocument == nil).help("在浮窗中打开对话")
                Button { model.showInspector.toggle() } label: { Label("显示或隐藏辅助面板", systemImage: "sidebar.right") }
                    .disabled(model.pdfDocument == nil)
            }
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importFiles(urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(get: { model.showSettings && !model.isChatFloating },
            set: { model.showSettings = $0 })) { SettingsView(model: model) }
        .sheet(isPresented: $model.showBrowserExtension) { BrowserExtensionView() }
        .sheet(isPresented: $model.showFolderEditor) { FolderEditorView(model: model) }
        .sheet(isPresented: $model.showStorageSettings) { StorageSettingsView(model: model, imports: model.importQueue, cloud: model.cloud) }
        .sheet(isPresented: $model.showPaperSearch) { PaperSearchView(model: model, search: model.paperSearch, imports: model.importQueue) }
        .alert("PaperDesk", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Palette.separator))
                    .padding(.bottom, 22).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                    Task { @MainActor in model.importFiles([url]) }
                }
            }
            return !providers.isEmpty
        }
    }
}

struct LibrarySidebar: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    var filtered: [PaperDeskCore.LibraryDocument] {
        let included = model.folderHierarchy.descendantIDs(of: model.folderFilter)
        if !model.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model.documents.filter { LibrarySearchIndex.metadataMatches($0, query: model.libraryQuery) }
        }
        return model.documents.filter { model.folderFilter == "all" || (model.folderFilter == "unfiled" ? $0.folderID == nil : $0.folderID.map(included.contains) == true) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("我的阅读空间").font(.system(size: 17, weight: .semibold))
                    Text("READ · THINK · CONNECT").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.2).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 22)
            Picker("导航", selection: $model.sidebarTab) {
                Text("文献库").tag("library")
                Text("文档目录").tag("outline")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.bottom, 18)

            if model.sidebarTab == "library" {
                FolderNavigation(model: model).padding(.bottom, 14)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("搜索论文或 arXiv", text: $model.libraryQuery).textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityLabel("搜索论文或 arXiv").onSubmit { model.openPaperSearch() }
                    if !model.libraryQuery.isEmpty {
                        Button {
                            model.libraryQuery = ""
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: 18, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("清空搜索").accessibilityLabel("清空搜索")
                    }
                    Button { model.openPaperSearch() } label: { Image(systemName: "arrow.up.right") }
                        .buttonStyle(.plain).help("搜索全文与 arXiv").accessibilityLabel("搜索全文与 arXiv")
                }.font(.system(size: 12)).padding(9).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 16).padding(.bottom, 8)
                Button { model.openPaperSearch() } label: { Text("搜索全文与 arXiv  ⌘⇧F").font(.system(size: 10)).foregroundStyle(Palette.accent) }
                    .buttonStyle(.plain).padding(.horizontal, 20).padding(.bottom, 16)
                HStack {
                    Text(model.libraryQuery.isEmpty ? model.folderTitle : "全库搜索").lineLimit(2).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).help(model.folderTitle)
                    Spacer()
                    Text("\(filtered.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.bottom, 10)
                if model.libraryQuery.isEmpty && model.folderHierarchy.hasChildren(model.folderFilter) {
                    Text("包含子文件夹中的论文").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 20).padding(.bottom, 8)
                }
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(filtered) { document in
                            Button { model.openDocument(id: document.id) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "doc.richtext").font(.system(size: 22, weight: .light))
                                        .foregroundStyle(model.selectedID == document.id ? Palette.accent : .secondary).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(document.title).font(.system(size: 12, weight: model.selectedID == document.id ? .semibold : .medium))
                                            .lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                        Text("PDF  ·  \(document.pageCount) 页").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.selectedID == document.id ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                            .draggable(document.id)
                            .contextMenu {
                                Menu("移动到") {
                                    Button("未分类") { model.moveDocument(document.id, to: nil) }
                                    ForEach(model.folderHierarchy.entries) { entry in
                                        Button(entry.path) { model.moveDocument(document.id, to: entry.id) }
                                    }
                                }
                            }
                        }
                    }.padding(.horizontal, 9)
                    if filtered.isEmpty {
                        Text(model.documents.isEmpty ? "导入第一篇文献，\n开始你的阅读记录。" : "没有匹配的文献")
                            .font(.system(size: 12)).foregroundStyle(.tertiary).lineSpacing(6)
                            .frame(maxWidth: .infinity).padding(.top, 30)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !model.outline.isEmpty {
                            ForEach(model.outline) { entry in
                                Button { model.goToPage(entry.page) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Text(String(format: "%02d", entry.page + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                        Text(entry.title).font(.system(size: 12)).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }.padding(10).padding(.leading, CGFloat(min(entry.depth, 4) * 10))
                                        .background(model.currentPage == entry.page ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        } else if let document = model.selectedDocument {
                            Text("文档没有书签目录").font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
                            ForEach(0..<document.pageCount, id: \.self) { index in
                                Button { model.goToPage(index) } label: {
                                    Label("第 \(index + 1) 页", systemImage: "doc.text").font(.system(size: 12))
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                        .background(model.currentPage == index ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        } else {
                            Text("打开文献后查看目录").font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
                        }
                    }.padding(.horizontal, 10)
                }
            }
            Spacer(minLength: 0)
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 9) {
                Button { model.showImporter = true } label: {
                    HStack { Image(systemName: "plus.circle"); Text("导入文献"); Spacer(); Text("⌘O").foregroundStyle(.tertiary) }
                        .font(.system(size: 12)).padding(.vertical, 5)
                }.buttonStyle(.plain)
                Button { model.showStorageSettings = true } label: {
                    Label("存储设置", systemImage: "externaldrive").font(.system(size: 12))
                }.buttonStyle(.plain)
                Label("文献与笔记保存在本地文件夹", systemImage: "internaldrive")
                    .font(.system(size: 10)).foregroundStyle(.secondary).help(model.storagePath)
            }.padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

import PaperDeskCore

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 26).fill(Palette.accent.opacity(0.07)).frame(width: 104, height: 104)
                Image(systemName: "book.pages").font(.system(size: 46, weight: .light)).foregroundStyle(Palette.accent)
            }.padding(.bottom, 28)
            Text("让阅读，留下思考。").font(.system(size: 30, weight: .semibold)).padding(.bottom, 14)
            Text("一个安静的论文阅读空间。\n从原文出发，把重点、疑问和灵感留在一起。")
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(7).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { model.showImporter = true } label: { Label("导入 PDF", systemImage: "plus").padding(.horizontal, 12).padding(.vertical, 6) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("打开阅读示例") { model.openDemo() }.buttonStyle(.bordered).controlSize(.large)
            }.padding(.top, 28)
            Text("也可以将 PDF 拖到窗口中").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 14)
            HStack(alignment: .top, spacing: 36) {
                feature("doc.text.viewfinder", "沉浸阅读", "搜索、目录与原文定位")
                feature("highlighter", "留住思考", "高亮、笔记与本地保存")
                feature("sparkles", "带着问题读", "翻译、解释与引用回溯")
            }.padding(.top, 64)
            Spacer()
            Text("PAPERDESK   /   YOUR PERSONAL READING SPACE")
                .font(.system(size: 9, design: .monospaced)).tracking(1.5).foregroundStyle(.tertiary).padding(.bottom, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
    }
    private func feature(_ icon: String, _ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 18, weight: .light)).foregroundStyle(Palette.accent)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(description).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct ReaderPane: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var pageInput = "1"
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.selectedDocument?.title ?? "").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 7) {
                        Text("PDF 文献").foregroundStyle(Palette.accent)
                        Text("·")
                        Text("\(model.selectedDocument?.pageCount ?? 0) 页")
                        if model.isIndexing { Text("·  正在提取正文…") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .background(WindowZoomArea())
                Menu {
                    if let source = model.selectedDocument?.sourceURL, let url = URL(string: source) {
                        Link("打开网页来源", destination: url)
                        Divider()
                    }
                    Button("导出带批注的 PDF…") { model.exportAnnotatedPDF() }
                    Button("导出 Markdown 笔记…") { model.exportNotes() }.disabled(model.notes.isEmpty)
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton).menuIndicator(.visible)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.accent.opacity(0.14)))
                .fixedSize().layoutPriority(1)
                .accessibilityLabel("导出").help("导出 PDF 或 Markdown 笔记")
            }.padding(.horizontal, 22).padding(.vertical, 17).background(.background)
            Divider()
            HStack(spacing: 8) {
                tool("上一页", "chevron.left") { model.goToPage(model.currentPage - 1) }.disabled(model.currentPage == 0)
                TextField("页码", text: $pageInput).textFieldStyle(.plain).multilineTextAlignment(.center)
                    .font(.system(size: 11, design: .monospaced)).frame(width: 28)
                    .onSubmit {
                        if let page = Int(pageInput), page > 0, page <= (model.pdfDocument?.pageCount ?? 0) { model.goToPage(page - 1) }
                        pageInput = "\(model.currentPage + 1)"
                    }.accessibilityLabel("页码")
                Text("/ \(model.pdfDocument?.pageCount ?? 0)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                tool("下一页", "chevron.right") { model.goToPage(model.currentPage + 1) }
                    .disabled(model.currentPage + 1 >= (model.pdfDocument?.pageCount ?? 0))
                Divider().frame(height: 16).padding(.horizontal, 3)
                tool("缩小", "minus.magnifyingglass") { model.pdfView?.zoomOut(nil) }
                tool("放大", "plus.magnifyingglass") { model.pdfView?.zoomIn(nil) }
                tool("适合窗口", "arrow.up.left.and.arrow.down.right") { model.pdfView?.autoScales = true }
                tool("保存高亮", "highlighter") { model.highlightSelection() }.disabled(model.selectedText.isEmpty)
                Spacer(minLength: 2)
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索正文", text: $model.searchText).textFieldStyle(.plain).focused($searchFocused)
                        .onSubmit { model.search() }.frame(minWidth: 55, maxWidth: 105)
                    if model.isSearching { ProgressView().controlSize(.mini) }
                    else if !model.searchResults.isEmpty {
                        Text("\(model.searchIndex + 1)/\(model.searchResults.count)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        Button { model.showSearchResult(model.searchIndex + 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
                    } else if model.searchAttempted && !model.searchText.isEmpty {
                        Text("无结果").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Palette.subtle, in: RoundedRectangle(cornerRadius: 6))
                Button("") { searchFocused = true }.keyboardShortcut("f").hidden().frame(width: 0)
            }.padding(.horizontal, 16).padding(.vertical, 10).background(.background)
            Divider()
            PDFReaderView(model: model)
                .overlay(alignment: .bottom) {
                    if !model.selectedText.isEmpty {
                        HStack(spacing: 12) {
                            Text("\(model.selectedText.count) 字").font(.system(size: 10)).foregroundStyle(.secondary)
                            Divider().frame(height: 14)
                            Button("高亮") { model.highlightSelection() }
                            Button("翻译") { model.askAboutCurrentSelection("请翻译选中内容，保留关键术语并标注原文依据。") }.disabled(model.isAsking)
                            Button("解释") { model.askAboutCurrentSelection("请解释选中内容，标注原文依据。") }.disabled(model.isAsking)
                            Divider().frame(height: 14)
                            Button { model.discussSelection() } label: { Label("浮窗讨论", systemImage: "sparkles") }
                                .foregroundStyle(Palette.accent).disabled(model.isAsking)
                                .help("在浮窗中讨论选区（⌘⇧J）").accessibilityLabel("在浮窗中讨论选区")
                        }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(Palette.separator))
                            .shadow(color: .black.opacity(0.08), radius: 12, y: 3).padding(.bottom, 20)
                    }
                }
            HStack {
                Label("本地文献", systemImage: "internaldrive").font(.system(size: 10))
                Spacer()
                Text("第 \(model.currentPage + 1) 页，共 \(model.pdfDocument?.pageCount ?? 0) 页").font(.system(size: 10))
                ProgressView(value: Double(model.currentPage + 1), total: Double(max(1, model.pdfDocument?.pageCount ?? 1)))
                    .progressViewStyle(.linear).frame(width: 66).tint(Palette.accent)
            }.foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10).background(.background)
        }
        .onChange(of: model.currentPage) { _, page in pageInput = "\(page + 1)" }
        .onAppear { pageInput = "\(model.currentPage + 1)" }
    }
    private func tool(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12)).frame(width: 24, height: 24) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}
