import Foundation
import Combine
import CryptoKit
import PDFKit

public enum PaperImportState: String, Sendable {
    case queued, downloading, importing, cancelling, completed, failed, cancelled
    public var isActive: Bool { [.queued, .downloading, .importing, .cancelling].contains(self) }
    public var title: String {
        switch self {
        case .queued: return "排队中"
        case .downloading: return "下载中"
        case .importing: return "校验并入库"
        case .cancelling: return "正在取消"
        case .completed: return "已完成"
        case .failed: return "导入失败"
        case .cancelled: return "已取消"
        }
    }
}

public struct PaperImportJob: Identifiable, Sendable {
    public let id: UUID
    public let article: ArxivArticle
    public let folderID: String?
    public let folderPath: String
    public var state: PaperImportState = .queued
    public var progress = PaperDownloadProgress(receivedBytes: 0, totalBytes: nil)
    public var error: String?
    public var documentID: String?
}

/// Download, hash, and stage the PDF outside the UI actor; only the small SQLite commit runs on it.
struct PreparedPaperImport: Sendable {
    let file: URL
    let fingerprint: String
    let pageCount: Int
    static func prepare(source: URL, staged: URL) throws -> PreparedPaperImport {
        try Task.checkCancellation()
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else {
            throw PaperDeskError.message("下载内容不是可阅读的 PDF。")
        }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        try data.write(to: staged, options: .atomic)
        return PreparedPaperImport(file: staged, fingerprint: fingerprint, pageCount: pdf.pageCount)
    }
}

extension DocumentRepository {
    func commit(_ prepared: PreparedPaperImport, article: ArxivArticle, folderID: String?) throws -> LibraryDocument {
        let existing = try database.documents()
        if let saved = ArxivIdentifier.existing(article, in: existing) { return saved }
        if var same = existing.first(where: { $0.fingerprint == prepared.fingerprint }) {
            if same.arxiv == nil { same.arxiv = article }
            if same.sourceURL == nil { same.sourceURL = article.abstractURL.absoluteString }
            try database.save(same); return same
        }
        if let folderID, try !database.folders().contains(where: { $0.id == folderID }) {
            throw PaperDeskError.message("目标文件夹已删除。请在搜索结果中重新选择文件夹后导入。")
        }
        let id = UUID().uuidString
        var document = LibraryDocument(id: id, title: article.title, filename: id + ".pdf", fingerprint: prepared.fingerprint,
            pageCount: prepared.pageCount, sourceURL: article.abstractURL.absoluteString, folderID: folderID)
        document.arxiv = article
        let destination = url(for: document)
        // Staging lives on the library's volume, so moving the prepared file does not copy its contents on the UI actor.
        try FileManager.default.moveItem(at: prepared.file, to: destination)
        do { try database.save(document) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return document
    }
}

/// App-owned queue: search views observe it but never own or cancel its lifetime.
@MainActor
public final class PaperImportQueue: ObservableObject {
    @Published public private(set) var jobs: [PaperImportJob] = []
    private var repository: DocumentRepository?
    private let downloader: any PaperDownloading
    private var runner: Task<Void, Never>?
    private var runningID: UUID?
    public var onImported: ((LibraryDocument) -> Void)?
    public init(downloader: any PaperDownloading = ArxivClient()) { self.downloader = downloader }
    public func configure(repository: DocumentRepository) { self.repository = repository }
    public var activeCount: Int { jobs.filter { $0.state.isActive }.count }
    public var failedCount: Int { jobs.filter { $0.state == .failed }.count }
    public func activeJob(for article: ArxivArticle) -> PaperImportJob? {
        jobs.first { $0.state.isActive && ArxivIdentifier.base($0.article.id) == ArxivIdentifier.base(article.id) }
    }
    @discardableResult
    public func enqueue(_ article: ArxivArticle, folderID: String?) throws -> UUID {
        guard let repository else { throw PaperDeskError.message("文献库尚未就绪。") }
        guard ArxivIdentifier.parse(article.id) == article.id else { throw PaperDeskError.message("无效的 arXiv 编号。") }
        if let active = activeJob(for: article) { return active.id }
        let folders = try repository.database.folders()
        if let folderID, !folders.contains(where: { $0.id == folderID }) { throw PaperDeskError.message("目标文件夹已不存在，请重新选择。") }
        var job = PaperImportJob(id: UUID(), article: article, folderID: folderID,
            folderPath: folderID.flatMap { FolderHierarchy(folders).path(for: $0) } ?? "未分类")
        if let saved = ArxivIdentifier.existing(article, in: try repository.database.documents()) {
            job.state = .completed; job.documentID = saved.id
        }
        jobs.append(job); startNext()
        return job.id
    }
    public func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state.isActive, job.state != .cancelling else { return }
        if runningID == id { update(id) { $0.state = .cancelling }; runner?.cancel() }
        else { update(id) { $0.state = .cancelled } }
    }
    public func retry(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), [.failed, .cancelled].contains(job.state) else { return }
        guard activeJob(for: job.article) == nil else { return }
        update(id) { $0.state = .queued; $0.error = nil; $0.progress = .init(receivedBytes: 0, totalBytes: nil) }
        startNext()
    }
    public func clearFinished() { jobs.removeAll { !$0.state.isActive } }
    private func update(_ id: UUID, _ body: (inout PaperImportJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }
    private func startNext() {
        guard runner == nil, let job = jobs.first(where: { $0.state == .queued }), let repository else { return }
        runningID = job.id; update(job.id) { $0.state = .downloading }
        runner = Task {
            let temporary = FileManager.default.temporaryDirectory.appending(path: "PaperDesk-import-\(job.id).pdf")
            let staged = repository.documentDirectory.appending(path: ".import-\(job.id).pdf")
            defer {
                try? FileManager.default.removeItem(at: temporary); try? FileManager.default.removeItem(at: staged)
                runner = nil; runningID = nil; startNext()
            }
            do {
                // A previous import may have saved the same paper while this one was queued.
                if let saved = ArxivIdentifier.existing(job.article, in: try repository.database.documents()) {
                    update(job.id) { $0.state = .completed; $0.documentID = saved.id }; onImported?(saved); return
                }
                if let folderID = job.folderID, try !repository.database.folders().contains(where: { $0.id == folderID }) {
                    throw PaperDeskError.message("目标文件夹已删除。请在搜索结果中重新选择文件夹后导入。")
                }
                try await downloader.download(job.article, to: temporary) { [weak self] progress in
                    await self?.receive(progress, id: job.id)
                }
                try Task.checkCancellation()
                update(job.id) { $0.state = .importing }
                let worker = Task.detached(priority: .utility) { try PreparedPaperImport.prepare(source: temporary, staged: staged) }
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                let document = try repository.commit(prepared, article: job.article, folderID: job.folderID)
                update(job.id) { $0.state = .completed; $0.documentID = document.id }
                onImported?(document)
            } catch {
                if Task.isCancelled { update(job.id) { $0.state = .cancelled; $0.error = nil } }
                else { update(job.id) { $0.state = .failed; $0.error = Self.describe(error) } }
            }
        }
    }
    private func receive(_ progress: PaperDownloadProgress, id: UUID) {
        guard jobs.first(where: { $0.id == id })?.state == .downloading else { return }
        update(id) { $0.progress = progress }
    }
    private static func describe(_ error: Error) -> String {
        if let error = error as? URLError { return "无法连接 arXiv（\(error.code.rawValue)），请检查网络后重试。" }
        return error.localizedDescription
    }
}
