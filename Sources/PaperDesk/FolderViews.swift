import SwiftUI
import PaperDeskCore

struct FolderNavigation: View {
    @ObservedObject var model: AppModel
    @State private var deletingFolder: LibraryFolder?
    var body: some View {
        let hierarchy = model.folderHierarchy
        let entries = model.visibleFolderEntries
        let counts = model.folderDocumentCounts
        VStack(spacing: 3) {
            HStack {
                Text("文件夹").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.editFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("新建文件夹").accessibilityLabel("新建文件夹")
            }.padding(.horizontal, 10).padding(.bottom, 6)
            row("all", "全部文献", "books.vertical", model.documents.count)
            row("unfiled", "未分类", "tray", model.documents.filter { $0.folderID == nil }.count)
                .dropDestination(for: String.self) { ids, _ in move(ids, to: nil) }
            if !model.folders.isEmpty {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(entries) { entry in
                            folderRow(entry, hasChildren: hierarchy.hasChildren(entry.id), count: counts[entry.id, default: 0])
                                .contextMenu {
                                    Button("新建子文件夹…") { model.editFolder(parentID: entry.id) }
                                    Button("重命名或移动…") { model.editFolder(entry.folder) }
                                    Divider()
                                    Button("删除文件夹（保留论文）", role: .destructive) { deletingFolder = entry.folder }
                                }
                                .dropDestination(for: String.self) { ids, _ in move(ids, to: entry.id) }
                        }
                    }
                }.frame(height: min(CGFloat(entries.count) * 34, 220))
            }
        }.padding(.horizontal, 10)
            .alert("删除文件夹及其子目录？", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })) {
                Button("取消", role: .cancel) { deletingFolder = nil }
                Button("删除文件夹", role: .destructive) {
                    if let folder = deletingFolder { model.deleteFolder(folder) }
                    deletingFolder = nil
                }
            } message: {
                if let folder = deletingFolder {
                    let children = max(0, hierarchy.descendantIDs(of: folder.id).count - 1)
                    Text("将删除「\(folder.name)」及 \(children) 个子文件夹。所有论文移入“未分类”，PDF、笔记和对话均会保留。")
                }
            }
    }
    private func folderRow(_ entry: FolderEntry, hasChildren: Bool, count: Int) -> some View {
        HStack(spacing: 4) {
            if hasChildren {
                Button { model.toggleFolderExpansion(entry.id) } label: {
                    Image(systemName: model.expandedFolderIDs.contains(entry.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 14, height: 28)
                }.buttonStyle(.plain).accessibilityLabel((model.expandedFolderIDs.contains(entry.id) ? "收起" : "展开") + entry.folder.name)
            } else { Color.clear.frame(width: 14, height: 28) }
            Button { model.folderFilter = entry.id } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder").frame(width: 16)
                    Text(entry.folder.name).lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }.font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(entry.path).accessibilityLabel(entry.path + "，\(count) 篇论文")
        }.padding(.leading, 4 + CGFloat(min(entry.depth, 6)) * 12).padding(.trailing, 10).padding(.vertical, 1)
            .background(model.folderFilter == entry.id ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
    private func row(_ id: String, _ name: String, _ icon: String, _ count: Int) -> some View {
        Button { model.folderFilter = id } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(name).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7)
                .background(model.folderFilter == id ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    private func move(_ ids: [String], to folderID: String?) -> Bool {
        let valid = ids.filter { id in model.documents.contains { $0.id == id } }
        for id in valid { model.moveDocument(id, to: folderID) }
        return !valid.isEmpty
    }
}

struct FolderEditorView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parent = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    var body: some View {
        let excluded = model.editingFolder.map { model.folderHierarchy.descendantIDs(of: $0.id) } ?? []
        VStack(alignment: .leading, spacing: 18) {
            Label(model.editingFolder == nil ? "新建文件夹" : "编辑文件夹", systemImage: "folder")
                .font(.title3.weight(.semibold))
            TextField("文件夹名称", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityLabel("文件夹名称")
            Picker("上级文件夹", selection: $parent) {
                Text("文献库（顶层）").tag("")
                ForEach(model.folderHierarchy.entries.filter { !excluded.contains($0.id) }) { entry in
                    Text(entry.path).tag(entry.id)
                }
            }.pickerStyle(.menu).accessibilityLabel("上级文件夹")
            Text("在文献上右键选择“移动到”，或将文献拖入文件夹。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try model.saveFolder(name: name, parentID: parent.isEmpty ? nil : parent) } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420)
            .onAppear { name = model.editingFolder?.name ?? ""; parent = model.folderEditorParentID ?? ""; focused = true }
    }
}
