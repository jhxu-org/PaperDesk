import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PaperDeskCore

struct StorageSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var imports: PaperImportQueue
    @ObservedObject var cloud: CloudModel
    @Environment(\.dismiss) private var dismiss
    @State private var selecting = false
    @State private var openingExisting = false
    @State private var selectedFolder: URL?
    @State private var showCloud = false

    private var destination: URL? {
        selectedFolder.map { openingExisting ? $0 : $0.appending(path: "PaperDesk Library", directoryHint: .isDirectory) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("存储设置").font(.title2.weight(.semibold))
                    Text("选择论文、笔记和对话的保存位置").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.storagePath).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text("\(model.documents.count) 篇论文 · 包含文件夹、笔记、阅读进度和 AI 对话")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("选择存储文件夹…") { openingExisting = false; selecting = true }
                                    .disabled(model.repository == nil || model.storageBusyReason != nil)
                                Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.storagePath) }
                                    .disabled(model.repository == nil)
                            }
                            Text("在所选位置创建“PaperDesk Library”文件夹。复制并校验完成后切换，原位置保留副本。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("打开已有书库…") { openingExisting = true; selecting = true }
                                    .disabled(model.storageBusyReason != nil)
                                if model.repository == nil { Button("重新连接原位置") { model.retryStorageLocation() } }
                            }
                            if let reason = model.storageBusyReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    } label: { Label("本地存储", systemImage: "folder").font(.headline) }
                    if let destination {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(openingExisting ? "将打开此书库" : "新的存储位置").font(.headline)
                            Text(destination.path).font(.callout.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if openingExisting {
                                Text("切换到该文件夹已有的论文和笔记，不合并当前书库。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(openingExisting ? "使用此书库" : "迁移并使用此文件夹") {
                                    if openingExisting { model.useExistingLibrary(at: destination) }
                                    else { model.moveStorage(to: destination) }
                                    selectedFolder = nil
                                }.buttonStyle(.borderedProminent).disabled(model.storageBusyReason != nil)
                                Button("取消选择") { selectedFolder = nil }
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("启用百度网盘备份（可选）", isOn: $model.cloudBackupEnabled).disabled(cloud.busy)
                            Text("不启用也可以使用全部本地阅读和笔记功能。启用后可手动备份或恢复论文、文件夹和笔记。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if model.cloudBackupEnabled {
                                Button("配置百度网盘…") { showCloud = true }
                                Text("本地文件继续保存在上方指定的位置。网盘操作按需执行，不会自动上传。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if cloud.busy { Text(cloud.status).font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    } label: { Label("云端备份", systemImage: "icloud").font(.headline) }
                }.disabled(model.isMovingStorage)
                VStack(alignment: .leading, spacing: 8) {
                    if model.isMovingStorage { ProgressView(value: model.storageProgress) }
                    if !model.storageStatus.isEmpty { Text(model.storageStatus).font(.callout).foregroundStyle(.secondary) }
                    if let error = model.storageError { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
            }.padding(24)
            Divider()
            HStack {
                if model.isMovingStorage { Button("取消迁移") { model.cancelStorageMove() } }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isMovingStorage)
            }.padding(16)
        }.frame(width: 650, height: 700)
            .interactiveDismissDisabled(model.isMovingStorage)
            .fileImporter(isPresented: $selecting, allowedContentTypes: [.folder]) { result in
                do { selectedFolder = try result.get(); model.storageError = nil }
                catch { model.storageError = error.localizedDescription }
            }
            .sheet(isPresented: $showCloud) { CloudSettingsView(model: model, cloud: cloud) }
    }
}
