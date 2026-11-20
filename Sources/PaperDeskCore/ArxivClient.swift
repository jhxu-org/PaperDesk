import Foundation
import PDFKit

public struct PaperDownloadProgress: Equatable, Sendable {
    public let receivedBytes: Int
    public let totalBytes: Int?
    public init(receivedBytes: Int, totalBytes: Int?) {
        self.receivedBytes = receivedBytes; self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
    }
    public var fraction: Double? { totalBytes.map { min(1, max(0, Double(receivedBytes) / Double($0))) } }
}

public protocol PaperDownloading: Sendable {
    func download(_ article: ArxivArticle, to destination: URL,
                  progress: @escaping @Sendable (PaperDownloadProgress) async -> Void) async throws
}

public struct ArxivArticle: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let authors: [String]
    public let summary: String
    public let published: String
    public let category: String
    public var abstractURL: URL { URL(string: "https://arxiv.org/abs/" + id)! }
    public var pdfURL: URL { URL(string: "https://arxiv.org/pdf/" + id)! }
    public init(id: String, title: String, authors: [String], summary: String, published: String, category: String) {
        self.id = id; self.title = title; self.authors = authors; self.summary = summary
        self.published = published; self.category = category
    }
}

public struct ArxivSearchPage: Sendable {
    public let articles: [ArxivArticle]
    public let total: Int
    public let start: Int
}

public enum ArxivIdentifier {
    public static func parse(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("arxiv:") { value = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if value.contains("://") {
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(url.host?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, url.port == nil,
                  url.path.hasPrefix("/abs/") || url.path.hasPrefix("/pdf/") else { return nil }
            value = String(url.path.dropFirst(5))
        }
        if value.hasSuffix(".pdf") { value = String(value.dropLast(4)) }
        let pattern = #"^(?:[0-9]{4}\.[0-9]{4,5}|[a-zA-Z][a-zA-Z.-]+/[0-9]{7})(?:v[1-9][0-9]*)?$"#
        return value.range(of: pattern, options: .regularExpression) != nil ? value : nil
    }
    public static func base(_ value: String) -> String? {
        parse(value)?.replacingOccurrences(of: #"v[0-9]+$"#, with: "", options: .regularExpression).lowercased()
    }
    public static func existing(_ article: ArxivArticle, in documents: [LibraryDocument]) -> LibraryDocument? {
        documents.first { document in
            if let id = document.arxiv?.id ?? document.sourceURL, let known = base(id) { return known == base(article.id) }
            return LibrarySearchIndex.normalize(document.title) == LibrarySearchIndex.normalize(article.title)
        }
    }
}

private final class ArxivFeedParser: NSObject, XMLParserDelegate {
    var articles: [ArxivArticle] = []
    var total: Int?
    var start = 0
    var stack: [String] = []
    var text = ""
    var values: [String: String] = [:]
    var authors: [String] = []
    var category = ""
    var invalid = false
    var sawFeed = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name); text = ""
        if stack.count == 1 { sawFeed = name == "feed" && namespaceURI == "http://www.w3.org/2005/Atom" }
        if name == "entry" { values = [:]; authors = []; category = "" }
        if name == "primary_category" { category = attributes["term"] ?? "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let clean = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if stack.contains("entry") {
            if stack.suffix(2) == ["author", "name"] { authors.append(clean) }
            if stack.dropLast().last == "entry" { values[name] = clean }
            if name == "entry" {
                if let id = ArxivIdentifier.parse(values["id"] ?? ""), let title = values["title"], !title.isEmpty {
                    articles.append(ArxivArticle(id: id, title: title, authors: authors, summary: values["summary"] ?? "",
                        published: values["published"] ?? "", category: category))
                } else { invalid = true }
            }
        } else if name == "totalResults" { total = Int(clean) }
        else if name == "startIndex" { start = Int(clean) ?? 0 }
        _ = stack.popLast(); text = ""
    }
}

private final class ArxivRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(ArxivClient.allowedURL) == true ? request : nil)
    }
}

/// One connection at a time, at least three seconds between requests, and a short query cache.
public actor ArxivClient: PaperDownloading {
    private let session: URLSession
    private let interval: TimeInterval
    private var busy = false
    private var nextRequest = Date.distantPast
    private var cache: [URL: (Date, ArxivSearchPage)] = [:]
    public init(session: URLSession? = nil, minimumInterval: TimeInterval = 3) {
        self.interval = minimumInterval
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 300
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config, delegate: ArxivRedirectGuard(), delegateQueue: nil)
        }
    }
    public nonisolated static func allowedURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && ["arxiv.org", "www.arxiv.org", "export.arxiv.org"].contains(url.host?.lowercased() ?? "")
    }
    public nonisolated static func searchURL(query: String, start: Int = 0) throws -> URL {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 300, start >= 0, start < 1000 else {
            throw PaperDeskError.message("请输入 1–300 个字符的关键词、论文标题或 arXiv 编号。")
        }
        var parts = URLComponents(string: "https://export.arxiv.org/api/query")!
        var items = [URLQueryItem(name: "start", value: String(start)), .init(name: "max_results", value: "10")]
        if let id = ArxivIdentifier.parse(query) { items.append(.init(name: "id_list", value: id)) }
        else {
            let tokens = query.components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
            guard !tokens.isEmpty else { throw PaperDeskError.message("请输入论文关键词或 arXiv 编号。") }
            items += [.init(name: "search_query", value: tokens.map { "all:\"\($0)\"" }.joined(separator: " AND ")),
                      .init(name: "sortBy", value: "relevance"), .init(name: "sortOrder", value: "descending")]
        }
        parts.queryItems = items
        return parts.url!
    }
    public nonisolated static func parseFeed(_ data: Data) throws -> ArxivSearchPage {
        guard data.count <= 2 * 1024 * 1024 else { throw PaperDeskError.message("arXiv 搜索结果过大，请缩小搜索范围。") }
        let delegate = ArxivFeedParser(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.sawFeed, !delegate.invalid, let total = delegate.total, total >= 0 else {
            throw PaperDeskError.message("arXiv 返回了无法识别的结果，请检查关键词或稍后重试。")
        }
        return ArxivSearchPage(articles: delegate.articles, total: total, start: delegate.start)
    }
    private func acquire() async throws {
        while busy { try await Task.sleep(for: .milliseconds(100)) }
        busy = true
        do {
            let delay = nextRequest.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            try Task.checkCancellation()
        } catch { busy = false; throw error }
    }
    private func release() { nextRequest = Date().addingTimeInterval(interval); busy = false }
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("PaperDesk/0.7 (macOS; personal research reader)", forHTTPHeaderField: "User-Agent")
        return request
    }
    private func validate(_ response: URLResponse, limit: Int) throws {
        guard let response = response as? HTTPURLResponse else { throw PaperDeskError.message("arXiv 返回了无效响应。") }
        guard response.statusCode == 200 else {
            if response.statusCode == 429 { throw PaperDeskError.message("arXiv 暂时限制请求，请稍后重试。") }
            throw PaperDeskError.message("arXiv 请求失败（HTTP \(response.statusCode)），请稍后重试。")
        }
        guard response.expectedContentLength <= limit else { throw PaperDeskError.message("文件超过允许大小（100 MB），请使用浏览器下载。") }
    }
    public func search(query: String, start: Int = 0) async throws -> ArxivSearchPage {
        let url = try Self.searchURL(query: query, start: start)
        try Task.checkCancellation()
        if let (date, page) = cache[url], Date().timeIntervalSince(date) < 300 { return page }
        try await acquire(); defer { release() }
        let (bytes, response) = try await session.bytes(for: request(url))
        defer { bytes.task.cancel() }
        try validate(response, limit: 2 * 1024 * 1024)
        var data = Data()
        try await withTaskCancellationHandler {
            for try await byte in bytes {
                try Task.checkCancellation(); data.append(byte)
                guard data.count <= 2 * 1024 * 1024 else { throw PaperDeskError.message("arXiv 搜索结果过大。") }
            }
        } onCancel: { bytes.task.cancel() }
        let page = try Self.parseFeed(data)
        if cache.count >= 30 { cache.removeAll() }
        cache[url] = (Date(), page)
        return page
    }
    public func download(_ article: ArxivArticle, to destination: URL,
                         progress: @escaping @Sendable (PaperDownloadProgress) async -> Void = { _ in }) async throws {
        guard ArxivIdentifier.parse(article.id) == article.id else { throw PaperDeskError.message("无效的 arXiv 编号。") }
        try await acquire(); defer { release() }
        let (bytes, response) = try await session.bytes(for: request(article.pdfURL))
        defer { bytes.task.cancel() }
        let limit = 100 * 1024 * 1024
        try validate(response, limit: limit)
        let total = response.expectedContentLength > 0 ? Int(response.expectedContentLength) : nil
        await progress(.init(receivedBytes: 0, totalBytes: total))
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PaperDeskError.message("无法创建 PDF 下载文件。")
        }
        let output = try FileHandle(forWritingTo: destination)
        var completed = false
        defer { try? output.close(); if !completed { try? FileManager.default.removeItem(at: destination) } }
        var buffer = Data(), count = 0, lastProgress = Date.distantPast
        try await withTaskCancellationHandler {
            for try await byte in bytes {
                try Task.checkCancellation(); buffer.append(byte); count += 1
                guard count <= limit else { throw PaperDeskError.message("PDF 超过 100 MB。") }
                if buffer.count == 65_536 {
                    try output.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
                    if Date().timeIntervalSince(lastProgress) >= 0.2 {
                        lastProgress = Date(); await progress(.init(receivedBytes: count, totalBytes: total))
                    }
                }
            }
        } onCancel: { bytes.task.cancel() }
        try output.write(contentsOf: buffer); try output.close(); try Task.checkCancellation()
        await progress(.init(receivedBytes: count, totalBytes: total))
        guard response.expectedContentLength < 0 || count == response.expectedContentLength,
              let pdf = PDFDocument(url: destination), !pdf.isLocked, pdf.pageCount > 0 else {
            throw PaperDeskError.message("下载内容不是完整、可阅读的 PDF，请稍后重试。")
        }
        completed = true
    }
}
