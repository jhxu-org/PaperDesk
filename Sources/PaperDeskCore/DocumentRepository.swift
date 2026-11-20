import Foundation
import CryptoKit
import PDFKit

@MainActor
public final class DocumentRepository {
    public let root: URL
    public let database: LibraryDatabase
    public var documentDirectory: URL { root.appending(path: "Documents", directoryHint: .isDirectory) }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appending(path: "Documents"), withIntermediateDirectories: true)
        database = try LibraryDatabase(url: root.appending(path: "library.sqlite"))
    }
    public func url(for document: LibraryDocument) -> URL { documentDirectory.appending(path: document.filename) }

    public func importArxivPDF(from source: URL, article: ArxivArticle, folderID: String?) throws -> LibraryDocument {
        guard ArxivIdentifier.parse(article.id) == article.id else { throw PaperDeskError.message("无效的 arXiv 编号。") }
        let existing = try database.documents()
        if let saved = ArxivIdentifier.existing(article, in: existing) { return saved }
        if let folderID, try !database.folders().contains(where: { $0.id == folderID }) {
            throw PaperDeskError.message("目标文件夹已不存在，请重新选择。")
        }
        var imported: LibraryDocument?
        do {
            return try database.transaction {
                var document = try importPDF(from: source, title: article.title, sourceURL: article.abstractURL.absoluteString)
                imported = document
                document.arxiv = article
                if !existing.contains(where: { $0.id == document.id }) { document.folderID = folderID }
                try database.save(document)
                return document
            }
        } catch {
            if let imported, !existing.contains(where: { $0.id == imported.id }) { try? FileManager.default.removeItem(at: url(for: imported)) }
            throw error
        }
    }

    public func importPDF(from source: URL, title: String? = nil, sourceURL: String? = nil) throws -> LibraryDocument {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if var existing = try database.documents().first(where: { $0.fingerprint == fingerprint }) {
            if existing.sourceURL == nil, let sourceURL { existing.sourceURL = sourceURL; try database.save(existing) }
            return existing
        }
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else {
            throw PaperDeskError.message("无法读取「\(source.lastPathComponent)」。请使用有效且未加密的 PDF。")
        }
        let id = UUID().uuidString
        let document = LibraryDocument(id: id, title: title ?? source.deletingPathExtension().lastPathComponent,
            filename: id + ".pdf", fingerprint: fingerprint, pageCount: pdf.pageCount, sourceURL: sourceURL)
        let destination = url(for: document)
        try data.write(to: destination, options: .atomic)
        do { try database.save(document) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return document
    }
}

public enum PDFTextExtractor {
    /// Use a separate PDFDocument from the displayed instance when called off the main thread.
    public static func extract(from url: URL) throws -> [SourceChunk] {
        guard let document = PDFDocument(url: url), !document.isLocked else {
            throw PaperDeskError.message("无法提取此文档的文本。")
        }
        var chunks: [SourceChunk] = []
        for page in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let text = document.page(at: page)?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var start = text.startIndex
            var index = 0
            while start < text.endIndex {
                let end = text.index(start, offsetBy: 1_200, limitedBy: text.endIndex) ?? text.endIndex
                let range = start..<end
                chunks.append(SourceChunk(id: "p\(page + 1)b\(index + 1)", page: page,
                    text: String(text[range]), characterOffset: NSRange(range, in: text).location))
                start = end; index += 1
            }
        }
        return chunks
    }
}

public enum ContextBuilder {
    /// Lightweight local retrieval; all candidates keep their original page and text range.
    public static func select(chunks: [SourceChunk], question: String, currentPage: Int, budget: Int = 24_000) -> [SourceChunk] {
        guard budget > 0 else { return [] }
        let chunks = chunks.filter { !$0.text.isEmpty }
        if chunks.reduce(0, { $0 + $1.text.count }) <= budget { return chunks }
        let words = question.lowercased().components(separatedBy: .alphanumerics.inverted).filter { $0.count > 1 }
        let chinese = Array(question.unicodeScalars.filter { (0x4E00...0x9FFF).contains(Int($0.value)) })
        var tokens = Set(words)
        if chinese.count > 1 {
            for i in 0..<(chinese.count - 1) { tokens.insert(String(chinese[i]) + String(chinese[i + 1])) }
        }
        // Common Chinese research questions should also retrieve English section evidence.
        let concepts: [([String], [String])] = [
            (["总结", "概括", "整体", "全文", "研究问题", "贡献", "创新", "目标", "目的"], ["abstract", "introduction", "contribution", "objective", "conclusion"]),
            (["方法", "模型", "架构", "算法", "训练"], ["method", "model", "architecture", "algorithm", "training"]),
            (["实验", "结果", "效果", "性能", "评估", "消融", "比较", "对比"], ["experiment", "result", "evaluation", "benchmark", "ablation", "comparison"]),
            (["局限", "缺点", "不足", "限制", "未来"], ["limitation", "discussion", "future work"]),
            (["结论", "启示", "意义"], ["conclusion", "discussion", "finding"])
        ]
        for (terms, english) in concepts where terms.contains(where: question.contains) { tokens.formUnion(english) }
        tokens.subtract(["the", "this", "that", "what", "does", "can", "you", "and", "for", "with", "are", "is", "it", "of", "to", "in"])
        var ranked: [(Int, SourceChunk, Int)] = []
        for (index, chunk) in chunks.enumerated() {
            let lower = chunk.text.lowercased()
            var score = 0
            for token in tokens where lower.contains(token) { score += 5 }
            if chunk.page == currentPage { score += 1 }
            if chunk.page == 0 { score += 2 }
            ranked.append((index, chunk, score))
        }
        ranked.sort { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }
        var used = 0
        var result: [(Int, SourceChunk)] = []
        // Reserve a small document-wide sample, evenly spaced rather than stopping at the first few pages.
        let firstPerPage = Dictionary(grouping: chunks.enumerated().map { ($0.offset, $0.element) }, by: { $0.1.page })
            .values.compactMap { $0.first }.sorted { $0.0 < $1.0 }
        let sampleCount = budget >= 2_400 ? min(firstPerPage.count, 6, budget / 2_400) : 0
        if sampleCount > 0 {
            let sampleBudget = budget / 3 / sampleCount
            for i in 0..<sampleCount {
                let index = sampleCount == 1 ? 0 : i * (firstPerPage.count - 1) / (sampleCount - 1)
                let (position, original) = firstPerPage[index]
                var chunk = original; chunk.text = String(chunk.text.prefix(sampleBudget))
                if !chunk.text.isEmpty { result.append((position, chunk)); used += chunk.text.count }
            }
        }
        var included = Set(result.map { $0.1.id })
        for (index, chunk, _) in ranked where !included.contains(chunk.id) {
            guard used < budget else { break }
            var excerpt = chunk; excerpt.text = String(chunk.text.prefix(budget - used))
            result.append((index, excerpt)); used += excerpt.text.count; included.insert(chunk.id)
        }
        return result.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    public static func citedSources(in answer: String, candidates: [SourceChunk]) -> [SourceChunk] {
        candidates.filter { answer.contains("[\($0.id)]") }
    }
}
