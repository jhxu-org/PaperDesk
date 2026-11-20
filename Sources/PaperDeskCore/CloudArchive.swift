import Foundation
import CryptoKit
import PDFKit

public struct CloudPaper: Codable, Sendable {
    public var document: LibraryDocument
    public var notes: [ReadingNote]
    public var byteCount: Int
    public init(document: LibraryDocument, notes: [ReadingNote], byteCount: Int) {
        self.document = document; self.notes = notes; self.byteCount = byteCount
    }
}

public struct CloudSnapshot: Codable, Sendable {
    public var schemaVersion = 2
    public var id = UUID().uuidString
    public var createdAt = Date()
    public var folders: [LibraryFolder]
    public var papers: [CloudPaper]
    public init(folders: [LibraryFolder], papers: [CloudPaper]) { self.folders = folders; self.papers = papers }
    public var noteCount: Int { papers.reduce(0) { $0 + $1.notes.count } }
    public var filename: String { "\(Int(createdAt.timeIntervalSince1970))_\(id).json" }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let result = try encoder.encode(self)
        guard result.count <= CloudArchive.maximumManifestBytes else { throw PaperDeskError.message("书库索引超过 20 MB，暂无法保存。") }
        return result
    }
    public func validate() throws {
        func require(_ value: Bool) throws { if !value { throw PaperDeskError.message("云端备份格式无效或版本不受支持。") } }
        try require(createdAt.timeIntervalSince1970.isFinite && (-62_135_596_800...253_402_300_799).contains(createdAt.timeIntervalSince1970))
        try require((1...2).contains(schemaVersion) && UUID(uuidString: id) != nil && papers.count <= 10_000 && folders.count <= 1_000)
        try require(Set(papers.map { $0.document.id }).count == papers.count)
        try require(Set(papers.map { $0.document.fingerprint }).count == papers.count)
        try require(Set(folders.map(\.id)).count == folders.count)
        let folderIDs = Set(folders.map(\.id))
        for folder in folders { try require(UUID(uuidString: folder.id) != nil && !folder.name.isEmpty && folder.name.count <= 80) }
        try require(schemaVersion != 1 || folders.allSatisfy { $0.parentID == nil })
        try FolderHierarchy(folders).validate()
        for paper in papers {
            let doc = paper.document
            try require(UUID(uuidString: doc.id) != nil && Self.isFingerprint(doc.fingerprint))
            try require(doc.pageCount > 0 && doc.pageCount <= 100_000 && doc.currentPage >= 0 && doc.currentPage < doc.pageCount)
            try require(doc.title.count <= 2_000 && paper.byteCount > 0 && paper.byteCount <= CloudArchive.maximumPDFBytes)
            if let source = doc.sourceURL { _ = try BrowserImportInbox.sourceURL(source) }
            if let article = doc.arxiv {
                try require(ArxivIdentifier.parse(article.id) == article.id && article.title.count <= 2_000 && article.summary.count <= 100_000 && article.authors.count <= 5_000)
            }
            if let folder = doc.folderID { try require(folderIDs.contains(folder)) }
            try require(paper.notes.count <= 100_000 && Set(paper.notes.map(\.id)).count == paper.notes.count)
            for note in paper.notes {
                try require(note.documentID == doc.id && note.page >= 0 && note.page < doc.pageCount)
                try require(note.quote.count <= 1_000_000 && note.body.count <= 1_000_000 && note.rects.count <= 10_000)
                try require(note.rects.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width >= 0 && $0.height >= 0 })
            }
        }
    }
    public static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public func markdownNotes() -> Data {
        var output = "# PaperDesk 阅读笔记\n\n保存时间：\(createdAt.formatted(.iso8601))\n\n"
        let hierarchy = FolderHierarchy(folders)
        for paper in papers {
            output += "## \(paper.document.title)\n\n"
            if let folderID = paper.document.folderID, let path = hierarchy.path(for: folderID) { output += "文件夹：\(path)\n\n" }
            if paper.notes.isEmpty { output += "尚无笔记。\n\n" }
            for note in paper.notes {
                output += "### 第 \(note.page + 1) 页\n\n> " + note.quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n" + note.body + "\n\n"
            }
        }
        return Data(output.utf8)
    }
}

public enum CloudArchive {
    public static let maximumPDFBytes = 500 * 1024 * 1024
    public static let maximumManifestBytes = 20 * 1024 * 1024
    public static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    @MainActor
    public static func capture(repository: DocumentRepository) throws -> CloudSnapshot {
        let papers = try repository.database.documents().map { doc in
            let size = try repository.url(for: doc).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return CloudPaper(document: doc, notes: try repository.database.notes(documentID: doc.id), byteCount: size)
        }
        let snapshot = CloudSnapshot(folders: try repository.database.folders(), papers: papers)
        try snapshot.validate(); return snapshot
    }
    public static func decode(_ data: Data) throws -> CloudSnapshot {
        guard data.count <= maximumManifestBytes else { throw PaperDeskError.message("云端索引超过 20 MB。") }
        let snapshot: CloudSnapshot
        do { snapshot = try JSONDecoder().decode(CloudSnapshot.self, from: data) }
        catch { throw PaperDeskError.message("无法读取云端书库索引。") }
        try snapshot.validate(); return snapshot
    }
    public static func validatePDF(_ url: URL, paper: CloudPaper) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == paper.byteCount, fingerprint(data) == paper.document.fingerprint,
              let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount == paper.document.pageCount else {
            throw PaperDeskError.message("「\(paper.document.title)」的 PDF 校验失败，未恢复书库。")
        }
    }
    /// Validates all files first, then merges metadata atomically. Existing local edits always survive.
    @MainActor
    public static func restore(_ snapshot: CloudSnapshot, files: [String: URL], into repository: DocumentRepository) throws -> Int {
        try snapshot.validate()
        for paper in snapshot.papers {
            guard let file = files[paper.document.fingerprint] else { throw PaperDeskError.message("备份缺少 PDF。") }
            try validatePDF(file, paper: paper)
        }
        let originalDocuments = try repository.database.documents()
        let originalIDs = Set(originalDocuments.map(\.id))
        var createdFiles: [URL] = []
        do {
            return try repository.database.transaction {
                var folderMap: [String: String] = [:]
                for entry in FolderHierarchy(snapshot.folders).entries {
                    var folder = entry.folder
                    let oldID = folder.id
                    let existing = try repository.database.folders()
                    // A matching identity retains local renames and moves. Otherwise merge only siblings.
                    if let match = existing.first(where: { $0.id == oldID }) {
                        folderMap[oldID] = match.id; continue
                    }
                    if let parent = folder.parentID {
                        guard let mapped = folderMap[parent] else { throw PaperDeskError.message("无法恢复文件夹的上级目录。") }
                        folder.parentID = mapped
                    }
                    if let match = existing.first(where: { $0.parentID == folder.parentID && FolderHierarchy.namesEqual($0.name, folder.name) }) {
                        folderMap[folder.id] = match.id; continue
                    }
                    try repository.database.save(folder); folderMap[oldID] = folder.id
                }
                var count = 0
                for paper in snapshot.papers {
                    try Task.checkCancellation()
                    var imported = try repository.importPDF(from: files[paper.document.fingerprint]!, title: paper.document.title, sourceURL: try paper.document.sourceURL.map(BrowserImportInbox.sourceURL))
                    if originalIDs.contains(imported.id), (try? validatePDF(repository.url(for: imported), paper: paper)) == nil {
                        // Repair a missing/damaged local PDF through a new file, leaving the previous copy intact.
                        imported.filename = UUID().uuidString + ".pdf"
                        let repaired = repository.url(for: imported)
                        createdFiles.append(repaired)
                        try Data(contentsOf: files[paper.document.fingerprint]!, options: .mappedIfSafe).write(to: repaired, options: .atomic)
                        try repository.database.save(imported)
                    }
                    if !originalIDs.contains(imported.id) {
                        createdFiles.append(repository.url(for: imported)); count += 1
                        imported.currentPage = paper.document.currentPage
                        imported.folderID = paper.document.folderID.flatMap { folderMap[$0] }
                        imported.addedAt = paper.document.addedAt
                        imported.arxiv = paper.document.arxiv
                        try repository.database.save(imported)
                    }
                    var notes = try repository.database.notes(documentID: imported.id)
                    for var note in paper.notes {
                        note.documentID = imported.id
                        // Repeated restores do not duplicate notes; diverged versions become independent notes.
                        if notes.contains(where: { $0.page == note.page && $0.quote == note.quote && $0.body == note.body && $0.rects == note.rects }) { continue }
                        note.id = UUID().uuidString
                        try repository.database.save(note); notes.append(note)
                    }
                }
                return count
            }
        } catch {
            for file in createdFiles { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }
}
