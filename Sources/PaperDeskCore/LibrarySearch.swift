import Foundation

public struct LibrarySearchItem: Sendable {
    public let document: LibraryDocument
    public let url: URL
    public init(document: LibraryDocument, url: URL) { self.document = document; self.url = url }
}
public struct LibrarySearchHit: Identifiable, Sendable {
    public var id: String { document.id }
    public let document: LibraryDocument
    public let snippet: String
    public let page: Int?
}
public struct LibrarySearchResult: Sendable {
    public let hits: [LibrarySearchHit]
    public let unreadableCount: Int
}

public actor LibrarySearchIndex {
    private var cache: [String: [SourceChunk]] = [:]
    public init() { }
    public nonisolated static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    public nonisolated static func metadataMatches(_ document: LibraryDocument, query: String) -> Bool {
        let value = normalize([document.title, document.arxiv?.authors.joined(separator: " ") ?? "",
                               document.arxiv?.summary ?? "", document.arxiv?.id ?? "", document.sourceURL ?? ""].joined(separator: " "))
        return normalize(query).split(separator: " ").allSatisfy { value.contains($0) }
    }
    public func search(_ items: [LibrarySearchItem], query: String) throws -> LibrarySearchResult {
        let tokens = Self.normalize(query).split(separator: " ").map(String.init)
        var hits: [LibrarySearchHit] = [], unreadable = 0
        for item in items {
            try Task.checkCancellation()
            if tokens.isEmpty || Self.metadataMatches(item.document, query: query) {
                hits.append(LibrarySearchHit(document: item.document, snippet: item.document.arxiv?.authors.joined(separator: ", ") ?? "已保存在本机", page: nil))
                continue
            }
            do {
                let chunks: [SourceChunk]
                if let cached = cache[item.document.fingerprint] { chunks = cached }
                else {
                    chunks = try PDFTextExtractor.extract(from: item.url)
                    if cache.count >= 20 { cache.removeAll() }
                    cache[item.document.fingerprint] = chunks
                }
                if chunks.isEmpty { unreadable += 1 }
                if let chunk = chunks.first(where: { chunk in let text = Self.normalize(chunk.text); return tokens.allSatisfy(text.contains) }) {
                    let text = chunk.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    let match = text.range(of: tokens[0], options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound ?? text.startIndex
                    let begin = text.index(match, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
                    hits.append(LibrarySearchHit(document: item.document, snippet: (begin > text.startIndex ? "…" : "") + String(text[begin...].prefix(220)), page: chunk.page))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { unreadable += 1 }
        }
        return LibrarySearchResult(hits: hits, unreadableCount: unreadable)
    }
}
