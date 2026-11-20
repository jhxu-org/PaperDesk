import SwiftUI
import PaperDeskCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var preset: String
    @State private var baseURL: String
    @State private var modelName: String
    @State private var key: String
    @State private var streaming: Bool
    @State private var sendPageImages: Bool
    @State private var rememberKey: Bool
    @State private var keychainError: String?
    @State private var error: String?
    @State private var status: String?
    @State private var modelIDs: [String] = []
    @State private var loadingModels = false
    @State private var testing = false
    @State private var task: Task<Void, Never>?
    @State private var credentialDrafts: [String: String] = [:]
    @State private var rememberDrafts: [String: Bool] = [:]

    init(model: AppModel) {
        self.model = model
        _baseURL = State(initialValue: model.baseURL)
        _modelName = State(initialValue: model.modelName)
        _key = State(initialValue: model.apiKey)
        _streaming = State(initialValue: model.streamResponses)
        _sendPageImages = State(initialValue: model.sendPageImages)
        _rememberKey = State(initialValue: model.remembersKey(baseURL: model.baseURL))
        _keychainError = State(initialValue: model.credentialError)
        let match = ModelPreset.all.first { !$0.baseURL.isEmpty && $0.baseURL == model.baseURL }
        _preset = State(initialValue: match?.id ?? "custom")
    }
    private var config: APIConfiguration {
        APIConfiguration(baseURL: baseURL, model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines), streamResponses: streaming)
    }
    private var busy: Bool { loadingModels || testing }
    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(Palette.accent).padding(12)
                    .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 7) {
                    Text("连接你的 AI 模型").font(.system(size: 21, weight: .semibold))
                    Text("配置一次，即可在阅读页面持续对话分析。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 14) {
                field("模型服务", hint: "支持 Chat Completions 兼容接口") {
                    Picker("模型服务", selection: $preset) {
                        ForEach(ModelPreset.all) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                }
                field("API 基础地址", hint: "可填写基础地址，或完整的 /chat/completions 地址") {
                    TextField("https://api.example.com/v1", text: $baseURL).accessibilityLabel("API 基础地址")
                }
                field("API Key", hint: "按服务地址分别保存在钥匙串中；本机免认证服务可留空。") {
                    SecureField("输入 API Key", text: $key).accessibilityLabel("API Key")
                }
                Toggle("在钥匙串中记住 API Key", isOn: $rememberKey).font(.system(size: 12))
                if !rememberKey {
                    Text("API Key 仅在本次运行中使用，退出后需重新填写。原有钥匙串记录不会被修改。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let keychainError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(keychainError).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("重试读取钥匙串") { retryKeychain() }.disabled(!key.isEmpty)
                            Button("改为仅本次使用") { rememberKey = false }
                        }.controlSize(.small)
                        if !key.isEmpty { Text("已填写的密钥会保留；清空输入后可重试读取旧记录。").font(.system(size: 10)) }
                    }.foregroundStyle(.secondary).padding(10)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                field("模型", hint: "读取服务提供的模型列表，或手动填写准确的模型 ID") {
                    HStack {
                        TextField("模型 ID", text: $modelName).accessibilityLabel("模型名称")
                        if !modelIDs.isEmpty {
                            Menu("选择") {
                                ForEach(modelIDs, id: \.self) { id in Button(id) { modelName = id } }
                            }.fixedSize()
                        }
                        Button(loadingModels ? "读取中…" : "读取模型") { loadModels() }
                            .disabled(busy || baseURL.isEmpty)
                    }
                }
                Toggle("流式输出，边生成边显示", isOn: $streaming).font(.system(size: 12))
                Toggle("向模型发送页面图片（需支持视觉输入）", isOn: $sendPageImages).font(.system(size: 12))
                Text("每次最多发送 3 页相关原文图片，用于理解图表。关闭时仍可查看配图，模型仅根据正文和图注解读。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.textFieldStyle(.roundedBorder)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised").foregroundStyle(Palette.accent)
                Text("提问时会发送相关正文和近期对话；开启页面图片后还会发送相关页的完整图片。测试连接只发送一条文字消息，不验证读图能力；模型服务可能计费。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.padding(12).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let status { Label(status, systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Palette.accent) }
            HStack {
                Button(testing ? "正在测试…" : "测试连接") { testConnection() }
                    .disabled(busy || baseURL.isEmpty || modelName.isEmpty)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(rememberKey ? "保存设置" : "保存并仅本次使用") {
                    do { try model.saveSettings(baseURL: baseURL, modelName: modelName, apiKey: key, streamResponses: streaming, sendPageImages: sendPageImages, rememberKey: rememberKey) }
                    catch let failure as CredentialAccessError { keychainError = failure.localizedDescription; error = nil }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(busy || baseURL.isEmpty || modelName.isEmpty || (keychainError != nil && rememberKey && key.isEmpty))
            }
        }.padding(28)
      }.frame(width: 586, height: 760)
            .onDisappear { task?.cancel() }
            .onChange(of: preset) { _, id in
                if let selected = ModelPreset.all.first(where: { $0.id == id }), !selected.baseURL.isEmpty {
                    baseURL = selected.baseURL; modelName = ""
                }
            }
            .onChange(of: baseURL) { old, new in
                invalidate(); modelIDs = []
                sendPageImages = model.visualInputEnabled(baseURL: new, modelName: modelName)
                let oldAccount = APIConfiguration(baseURL: old, model: "", apiKey: "").credentialAccount
                let newAccount = APIConfiguration(baseURL: new, model: "", apiKey: "").credentialAccount
                if oldAccount != newAccount {
                    keychainError = nil
                    if let oldAccount { credentialDrafts[oldAccount] = key; rememberDrafts[oldAccount] = rememberKey }
                    rememberKey = newAccount.flatMap { rememberDrafts[$0] } ?? model.remembersKey(baseURL: new)
                    if let newAccount, let saved = credentialDrafts[newAccount] { key = saved }
                    else {
                        do { key = try model.keyForSettings(baseURL: new) }
                        catch { key = ""; keychainError = error.localizedDescription }
                    }
                }
            }
            .onChange(of: modelName) { _, _ in invalidate(); sendPageImages = model.visualInputEnabled(baseURL: baseURL, modelName: modelName) }
            .onChange(of: key) { _, _ in invalidate() }
            .onChange(of: streaming) { _, _ in invalidate() }
    }
    private func invalidate() {
        task?.cancel(); testing = false; loadingModels = false; error = nil; status = nil
    }
    private func retryKeychain() {
        guard key.isEmpty else { return }
        do {
            key = try model.keyForSettings(baseURL: baseURL)
            keychainError = nil
            status = key.isEmpty ? "没有已保存的密钥，请填写 API Key；免认证服务可留空。" : "已读取钥匙串凭据。"
        } catch { keychainError = error.localizedDescription }
    }
    private func loadModels() {
        invalidate(); loadingModels = true
        let configuration = config
        task = Task {
            do {
                let ids = try await AIClient().listModels(configuration: configuration)
                guard !Task.isCancelled else { return }
                modelIDs = ids; loadingModels = false
                if ids.isEmpty { error = "服务返回了空模型列表，请手动填写模型 ID。" }
                else { status = "已读取 \(ids.count) 个模型，点击“选择”使用。" }
            } catch {
                guard !Task.isCancelled else { return }
                loadingModels = false; self.error = "读取模型失败：\(error.localizedDescription) 也可以直接手动填写。"
            }
        }
    }
    private func testConnection() {
        invalidate(); testing = true
        let configuration = config
        task = Task {
            do {
                try await AIClient().testConnection(configuration: configuration)
                guard !Task.isCancelled else { return }
                testing = false; status = "连接成功，模型已返回回答。保存后即可使用。"
            } catch {
                guard !Task.isCancelled else { return }
                testing = false; self.error = "连接失败：\(error.localizedDescription)"
            }
        }
    }
    private func field<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            content()
            Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
