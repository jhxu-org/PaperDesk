import SwiftUI
import AppKit
import PaperDeskCore

struct CloudSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var cloud: CloudModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRestore = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "icloud").font(.system(size: 30, weight: .light)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("百度网盘").font(.title2.weight(.semibold))
                    Text(cloud.connected ? "已连接 · \(cloud.accountName ?? "百度账号")" : "保存论文与笔记，在需要时恢复")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("AppKey") { TextField("开放平台应用 AppKey", text: $cloud.appKey).textFieldStyle(.roundedBorder) }
                            LabeledContent("SecretKey") { SecureField("开放平台应用 SecretKey", text: $cloud.secret).textFieldStyle(.roundedBorder) }
                            LabeledContent("网盘目录") { TextField("/apps/应用目录名/PaperDesk", text: $cloud.remoteRoot).textFieldStyle(.roundedBorder) }
                            Text("请将 /apps/ 后的目录改为你的百度开放平台应用目录名。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Toggle("在钥匙串中记住密钥和登录授权", isOn: $cloud.rememberCredentials)
                                .font(.caption)
                            if !cloud.rememberCredentials {
                                Text("仅在本次运行中使用；退出后需重新填写并登录。原有钥匙串记录不会被修改。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if cloud.credentialReadFailed {
                                HStack {
                                    Button("重试读取钥匙串") { cloud.load() }.disabled(!cloud.secret.isEmpty)
                                    Button("改为仅本次使用") { cloud.rememberCredentials = false }
                                }
                            }
                            HStack {
                                Button("保存配置") {
                                    do { try cloud.saveConfiguration(); cloud.error = nil; cloud.status = cloud.rememberCredentials ? "配置已安全保存。" : "配置仅在本次运行中使用。" }
                                    catch { cloud.error = error.localizedDescription }
                                }
                                Button(cloud.connected ? "重新授权" : "登录百度网盘") { cloud.signIn() }.buttonStyle(.borderedProminent)
                                Spacer()
                                if cloud.connected { Button(cloud.rememberCredentials ? "断开连接" : "结束本次连接") { cloud.disconnect() } }
                            }
                        }.padding(10).disabled(cloud.busy)
                    } label: { Text("连接设置").font(.headline) }
                    if let code = cloud.deviceCode {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("在百度页面确认授权").font(.headline)
                            Text("登录码：\(code.userCode)").font(.title3.monospaced()).textSelection(.enabled)
                            Button("重新打开百度授权页面") { NSWorkspace.shared.open(code.verificationURL) }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("保存整个书库：PDF 原文件、文件夹、阅读进度、高亮和笔记。每次保存生成独立版本，另附可直接阅读的 Markdown 笔记。")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            Text("按需手动保存。模型密钥和 AI 对话不会上传。")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("保存到百度网盘") {
                                    if let repository = model.repository { cloud.save(repository: repository, progressPersist: model.persistProgress) }
                                }.buttonStyle(.borderedProminent).disabled(!cloud.connected || cloud.busy || model.repository == nil)
                                if let date = cloud.lastSavedAt {
                                    Text("上次保存 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    } label: { Text("保存书库").font(.headline) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("选择一个完整版本恢复到本机。").font(.callout)
                                Spacer()
                                Button("读取云端版本") { cloud.listVersions() }.disabled(!cloud.connected || cloud.busy)
                            }
                            if !cloud.versions.isEmpty {
                                Picker("云端版本", selection: $cloud.selectedVersion) {
                                    ForEach(cloud.versions) { file in
                                        Text(file.modifiedAt.formatted(date: .abbreviated, time: .standard)).tag(Optional(file.id))
                                    }
                                }.disabled(cloud.busy)
                                Button("恢复所选版本…") { model.persistProgress(); confirmRestore = true }
                                    .disabled(cloud.selectedVersion == nil || cloud.busy || model.isAsking)
                            }
                            Text("恢复会合并内容，保留本机已有论文和修改；不同版本的笔记分别保留。不会删除云端或本机文件。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    } label: { Text("恢复书库").font(.headline) }
                    VStack(alignment: .leading, spacing: 8) {
                        if cloud.busy {
                            if cloud.signingIn { ProgressView().controlSize(.small) }
                            else { ProgressView(value: cloud.progress) }
                        }
                        Text(cloud.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let error = cloud.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                if cloud.busy { Button("取消操作") { cloud.cancel() } }
                Spacer()
                Button(cloud.busy && !cloud.signingIn ? "后台继续" : "完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }.frame(width: 650, height: 740)
            .onAppear { cloud.load() }
            .onDisappear { if cloud.signingIn { cloud.cancel() } }
            .onChange(of: cloud.remoteRoot) { _, _ in cloud.invalidateVersions() }
            .onChange(of: cloud.appKey) { _, _ in cloud.invalidateVersions() }
            .onChange(of: cloud.secret) { _, _ in cloud.invalidateVersions() }
            .confirmationDialog("恢复所选云端版本？", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("合并到本机书库") {
                    if let repository = model.repository { cloud.restore(repository: repository, completed: model.cloudRestoreCompleted) }
                }
                Button("取消", role: .cancel) { }
            } message: { Text("新增论文会被下载，已有论文保持不变。云端笔记与本机笔记不同时会分别保留。") }
    }
}
