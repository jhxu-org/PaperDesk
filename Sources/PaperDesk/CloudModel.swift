import Foundation
import SwiftUI
import AppKit
import PaperDeskCore

private struct BaiduCredentials: Codable {
    var appKey: String
    var secret: String
    var token: BaiduToken?
    var accountName: String?
}

@MainActor
final class CloudModel: ObservableObject {
    @Published var appKey = ""
    @Published var secret = ""
    @Published var remoteRoot = "/apps/PaperDesk"
    @Published var accountName: String?
    @Published var busy = false
    @Published var signingIn = false
    @Published var status = "连接百度网盘，保存论文、文件夹和笔记。"
    @Published var error: String?
    @Published var progress: Double = 0
    @Published var deviceCode: BaiduDeviceCode?
    @Published var versions: [BaiduFile] = []
    @Published var selectedVersion: Int64?
    @Published var lastSavedAt: Date?
    @Published private(set) var connected = false
    @Published var rememberCredentials = true
    @Published private(set) var credentialReadFailed = false
    private var credentials: BaiduCredentials?
    private var task: Task<Void, Never>?
    private let client = BaiduNetdiskClient()
    private var loaded = false
    private let defaults: UserDefaults
    private let keychainAccount = "baidu-netdisk.credentials"
    init() {
        defaults = Bundle.main.bundleIdentifier == "com.paperdesk.mac.uitests" ? UserDefaults(suiteName: "com.paperdesk.mac.tests")! : .standard
    }
    func load() {
        guard !loaded else { return }
        remoteRoot = defaults.string(forKey: "baiduRoot") ?? "/apps/PaperDesk"
        appKey = defaults.string(forKey: "baiduAppKey") ?? ""
        lastSavedAt = defaults.object(forKey: "baiduLastSaved") as? Date
        do {
            if let stored = try Keychain.read(account: keychainAccount), let data = stored.data(using: .utf8) {
                let value = try JSONDecoder().decode(BaiduCredentials.self, from: data)
                credentials = value; appKey = value.appKey; secret = value.secret; accountName = value.accountName
                connected = value.token != nil
            }
            rememberCredentials = !Keychain.isSessionOnly(account: keychainAccount)
            loaded = true; credentialReadFailed = false
        } catch { credentialReadFailed = true; self.error = "无法读取网盘凭据：\(error.localizedDescription)" }
    }
    func saveConfiguration() throws {
        let key = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !secret.isEmpty else { throw PaperDeskError.message("请填写 AppKey 和 SecretKey。") }
        let root = try BaiduPath.root(remoteRoot)
        if credentials?.appKey != key || credentials?.secret != secret {
            credentials = BaiduCredentials(appKey: key, secret: secret); connected = false; accountName = nil
        }
        try store()
        loaded = true; credentialReadFailed = false
        let changedDestination = defaults.string(forKey: "baiduRoot") != root || defaults.string(forKey: "baiduAppKey") != key
        if changedDestination { versions = []; selectedVersion = nil; lastSavedAt = nil; defaults.removeObject(forKey: "baiduLastSaved") }
        appKey = key; self.secret = secret; remoteRoot = root
        defaults.set(root, forKey: "baiduRoot"); defaults.set(key, forKey: "baiduAppKey")
    }
    private func store() throws {
        if let credentials { try Keychain.write(String(data: JSONEncoder().encode(credentials), encoding: .utf8)!, account: keychainAccount, remember: rememberCredentials) }
    }
    func signIn() {
        guard !busy else { return }
        do { try saveConfiguration() } catch { self.error = error.localizedDescription; return }
        guard let config = credentials else { return }
        busy = true; signingIn = true; error = nil; status = "正在获取百度登录码…"
        task = Task {
            defer { busy = false; signingIn = false; deviceCode = nil }
            do {
                let code = try await client.deviceCode(appKey: config.appKey)
                deviceCode = code; status = "请在百度页面确认授权，登录码：\(code.userCode)"
                NSWorkspace.shared.open(code.verificationURL)
                let deadline = Date().addingTimeInterval(Double(code.expiresIn)); var interval = code.interval
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(interval))
                    do {
                        let token = try await client.token(appKey: config.appKey, secret: config.secret, deviceCode: code.deviceCode)
                        credentials?.token = token
                        // Persist refreshed credentials before requesting optional account information.
                        try store(); connected = true
                        let name = try await client.accountName(token: token.accessToken)
                        credentials?.accountName = name; accountName = name; try store()
                        status = "已连接百度网盘，可以保存书库。"; return
                    } catch BaiduError.oauth("authorization_pending") { continue }
                    catch BaiduError.oauth("slow_down") { interval = min(30, interval + 5); continue }
                }
                throw BaiduError.oauth("expired_token")
            } catch { report(error) }
        }
    }
    private func storage() async throws -> BaiduCloudStorage {
        guard var config = credentials, var token = config.token else { throw PaperDeskError.message("请先登录百度网盘。") }
        if token.expiresAt.timeIntervalSinceNow < 300 {
            token = try await client.refresh(appKey: config.appKey, secret: config.secret, refreshToken: token.refreshToken)
            config.token = token; credentials = config; try store()
        }
        return BaiduCloudStorage(client: client, token: token.accessToken)
    }
    func save(repository: DocumentRepository, progressPersist: () -> Void) {
        guard !busy else { return }
        let snapshot: CloudSnapshot, files: [String: URL]
        do {
            try saveConfiguration(); progressPersist()
            snapshot = try CloudArchive.capture(repository: repository)
            files = Dictionary(uniqueKeysWithValues: snapshot.papers.map { ($0.document.fingerprint, repository.url(for: $0.document)) })
        } catch { self.error = error.localizedDescription; return }
        let root = remoteRoot
        busy = true; error = nil; progress = 0; status = "准备保存书库…"
        task = Task {
            defer { busy = false }
            do {
                let storage = try await storage()
                try await CloudTransfer.save(snapshot, files: files, root: root, storage: storage) { [weak self] message, fraction in
                    await self?.update(message, fraction)
                }
                lastSavedAt = Date(); defaults.set(lastSavedAt, forKey: "baiduLastSaved")
                status = "已保存 \(snapshot.papers.count) 篇论文、\(snapshot.noteCount) 条笔记。"
                versions = try await CloudTransfer.snapshots(root: root, storage: storage)
                selectedVersion = versions.first?.id
            } catch { report(error) }
        }
    }
    func listVersions() {
        guard !busy else { return }
        do { try saveConfiguration() } catch { self.error = error.localizedDescription; return }
        let root = remoteRoot
        busy = true; error = nil; status = "正在读取云端版本…"
        task = Task {
            defer { busy = false }
            do {
                versions = try await CloudTransfer.snapshots(root: root, storage: storage())
                selectedVersion = versions.first?.id
                status = versions.isEmpty ? "此目录中还没有 PaperDesk 云端版本。" : "找到 \(versions.count) 个云端版本。"
            } catch { report(error) }
        }
    }
    func restore(repository: DocumentRepository, completed: @escaping () -> Void) {
        guard !busy, let version = versions.first(where: { $0.id == selectedVersion }) else { return }
        let root = remoteRoot
        let temporary = FileManager.default.temporaryDirectory.appending(path: "PaperDesk-Restore-" + UUID().uuidString)
        let files: [String: URL]
        do { files = Dictionary(uniqueKeysWithValues: try repository.database.documents().map { ($0.fingerprint, repository.url(for: $0)) }) }
        catch { self.error = error.localizedDescription; return }
        busy = true; error = nil; progress = 0; status = "正在取回云端书库…"
        task = Task {
            defer { busy = false; try? FileManager.default.removeItem(at: temporary) }
            do {
                let (snapshot, downloaded) = try await CloudTransfer.fetch(version, root: root, into: temporary, localFiles: files, storage: storage()) { [weak self] message, fraction in
                    await self?.update(message, fraction)
                }
                try Task.checkCancellation()
                let added = try CloudArchive.restore(snapshot, files: downloaded, into: repository)
                completed(); progress = 1; status = "恢复完成：新增 \(added) 篇论文，笔记已合并。本机修改已保留。"
            } catch { report(error) }
        }
    }
    private func update(_ message: String, _ fraction: Double) { status = message; progress = fraction }
    private func report(_ failure: Error) {
        if Task.isCancelled || failure is CancellationError { status = "操作已取消。已完成的云端版本和本地内容均保留。" }
        else { error = failure.localizedDescription; status = "操作未完成，可重新尝试。" }
    }
    func invalidateVersions() { if !busy { versions = []; selectedVersion = nil } }
    func cancel() { task?.cancel() }
    func disconnect() {
        guard !busy else { return }
        do {
            try Keychain.write("", account: keychainAccount, remember: rememberCredentials)
            credentials = nil; secret = ""; accountName = nil; connected = false; versions = []; selectedVersion = nil
            status = rememberCredentials ? "已移除本机授权。云端文件仍保留。" : "已结束本次连接；原有钥匙串记录未修改。"
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
