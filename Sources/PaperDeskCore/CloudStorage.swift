import Foundation

public protocol CloudStorage: Sendable {
    func list(_ path: String) async throws -> [BaiduFile]
    func ensureDirectory(_ path: String) async throws
    func upload(_ file: URL, to path: String) async throws
    func download(_ file: BaiduFile, to destination: URL, limit: Int) async throws
}
public struct BaiduCloudStorage: CloudStorage {
    public let client: BaiduNetdiskClient
    public let token: String
    public init(client: BaiduNetdiskClient = .init(), token: String) { self.client = client; self.token = token }
    public func list(_ path: String) async throws -> [BaiduFile] { try await client.list(path: path, token: token) }
    public func ensureDirectory(_ path: String) async throws { try await client.ensureDirectory(path, token: token) }
    public func upload(_ file: URL, to path: String) async throws { try await client.upload(file, to: path, token: token) }
    public func download(_ file: BaiduFile, to destination: URL, limit: Int) async throws { try await client.download(file, to: destination, token: token, limit: limit) }
}
public enum CloudTransfer {
    public typealias Progress = @Sendable (String, Double) async -> Void
    public static func snapshots(root: String, storage: any CloudStorage) async throws -> [BaiduFile] {
        let root = try BaiduPath.root(root)
        do {
            return try await storage.list(root + "/snapshots").filter { !$0.isDirectory && $0.name.hasSuffix(".json") && $0.path == root + "/snapshots/" + $0.name }
                .sorted { $0.name > $1.name }
        } catch BaiduError.api(-9) { return [] }
    }
    public static func save(_ snapshot: CloudSnapshot, files: [String: URL], root: String, storage: any CloudStorage, progress: Progress) async throws {
        try snapshot.validate()
        let root = try BaiduPath.root(root)
        let manifest = try snapshot.encoded()
        let temporary = FileManager.default.temporaryDirectory.appending(path: "PaperDesk-Cloud-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let components = root.split(separator: "/")
        for count in 2...components.count { try await storage.ensureDirectory("/" + components.prefix(count).joined(separator: "/")) }
        try await storage.ensureDirectory(root + "/objects")
        try await storage.ensureDirectory(root + "/snapshots")
        let existing = try await storage.list(root + "/objects")
        for (index, paper) in snapshot.papers.enumerated() {
            try Task.checkCancellation()
            await progress("保存论文 \(index + 1)/\(snapshot.papers.count)：\(paper.document.title)", Double(index) / Double(max(1, snapshot.papers.count + 2)))
            guard let file = files[paper.document.fingerprint] else { throw PaperDeskError.message("找不到本地 PDF。") }
            try CloudArchive.validatePDF(file, paper: paper)
            let remote = root + "/objects/" + paper.document.fingerprint + ".pdf"
            if let entry = existing.first(where: { $0.path == remote }) {
                guard !entry.isDirectory, entry.size == paper.byteCount else { throw PaperDeskError.message("云端存在大小异常的 PDF，请检查网盘中的 PaperDesk 目录。") }
            } else { try await storage.upload(file, to: remote) }
        }
        try Task.checkCancellation()
        await progress("保存笔记和文件夹结构…", 0.94)
        let notes = temporary.appending(path: "notes.md")
        try snapshot.markdownNotes().write(to: notes, options: .atomic)
        try await storage.upload(notes, to: root + "/snapshots/" + snapshot.filename.replacingOccurrences(of: ".json", with: "-notes.md"))
        try Task.checkCancellation()
        let file = temporary.appending(path: "snapshot.json"); try manifest.write(to: file, options: .atomic)
        // The manifest is the commit marker: a listed version never references an upload still in progress.
        try await storage.upload(file, to: root + "/snapshots/" + snapshot.filename)
        await progress("论文与笔记已保存到百度网盘", 1)
    }
    public static func fetch(_ file: BaiduFile, root: String, into temporary: URL, localFiles: [String: URL], storage: any CloudStorage, progress: Progress) async throws -> (CloudSnapshot, [String: URL]) {
        let root = try BaiduPath.root(root)
        guard file.path == root + "/snapshots/" + file.name, file.name.hasSuffix(".json"), !file.name.contains("/") else { throw PaperDeskError.message("请选择此书库中的云端版本。") }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifest = temporary.appending(path: "snapshot.json")
        try await storage.download(file, to: manifest, limit: CloudArchive.maximumManifestBytes)
        let snapshot = try CloudArchive.decode(Data(contentsOf: manifest))
        let objects = try await storage.list(root + "/objects")
        var result: [String: URL] = [:]
        for (index, paper) in snapshot.papers.enumerated() {
            try Task.checkCancellation()
            await progress("取回论文 \(index + 1)/\(snapshot.papers.count)：\(paper.document.title)", Double(index) / Double(max(1, snapshot.papers.count)))
            let hash = paper.document.fingerprint
            if let local = localFiles[hash], (try? CloudArchive.validatePDF(local, paper: paper)) != nil { result[hash] = local; continue }
            let remotePath = root + "/objects/" + hash + ".pdf"
            guard let remote = objects.first(where: { $0.path == remotePath }), remote.size == paper.byteCount else { throw PaperDeskError.message("云端版本缺少「\(paper.document.title)」的 PDF。") }
            let destination = temporary.appending(path: hash + ".pdf")
            try await storage.download(remote, to: destination, limit: CloudArchive.maximumPDFBytes)
            try CloudArchive.validatePDF(destination, paper: paper)
            result[hash] = destination
        }
        try Task.checkCancellation()
        return (snapshot, result)
    }
}
