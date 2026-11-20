import Foundation
import PaperDeskCore

extension PaperDeskCoreTests {
    func testArxivParsingAndQueries() throws {
        let page = try ArxivClient.parseFeed(Data(arxivFixture.utf8))
        try XCTAssertEqual(page.total, 11)
        try XCTAssertEqual(page.articles.count, 1)
        let article = try XCTUnwrap(page.articles.first)
        try XCTAssertEqual(article.title, "Attention & Evidence")
        try XCTAssertEqual(article.authors, ["René Reader", "张研究"])
        try XCTAssertEqual(article.summary, "An abstract with multiple lines.")
        try XCTAssertEqual(article.category, "cs.AI")
        try XCTAssertEqual(article.pdfURL.absoluteString, "https://arxiv.org/pdf/1706.03762v2")
        for value in ["1706.03762v2", "arXiv:1706.03762v2", "https://arxiv.org/pdf/1706.03762v2.pdf?download=1", "http://arxiv.org/abs/1706.03762v2"] {
            try XCTAssertEqual(ArxivIdentifier.parse(value), "1706.03762v2")
        }
        try XCTAssertEqual(ArxivIdentifier.parse("https://arxiv.org/abs/hep-th/9901001"), "hep-th/9901001")
        for value in ["https://evil.test/abs/1706.03762", "https://arxiv.org.evil.test/pdf/1706.03762", "https://user:pass@arxiv.org/pdf/1706.03762", "../1706.03762", "1706.03762v0"] {
            try XCTAssertTrue(ArxivIdentifier.parse(value) == nil)
        }
        let link = try ArxivClient.searchURL(query: "https://arxiv.org/abs/1706.03762v2")
        try XCTAssertEqual(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id_list" }?.value, "1706.03762v2")
        let query = try ArxivClient.searchURL(query: "world models & robot", start: 10)
        let items = try XCTUnwrap(URLComponents(url: query, resolvingAgainstBaseURL: false)?.queryItems)
        try XCTAssertEqual(items.first { $0.name == "search_query" }?.value, "all:\"world\" AND all:\"models\" AND all:\"robot\"")
        try XCTAssertEqual(items.first { $0.name == "start" }?.value, "10")
        try XCTAssertThrowsError(try ArxivClient.searchURL(query: " "))
        try XCTAssertThrowsError(try ArxivClient.searchURL(query: String(repeating: "x", count: 301)))
        try XCTAssertThrowsError(try ArxivClient.parseFeed(Data("<html>bad gateway</html>".utf8)))
        try XCTAssertThrowsError(try ArxivClient.parseFeed(Data(arxivFixture.replacingOccurrences(of: "http://arxiv.org/abs/1706.03762v2", with: "http://arxiv.org/api/errors#bad_query").utf8)))
        try XCTAssertThrowsError(try ArxivClient.parseFeed(Data(arxivFixture.dropLast(10).utf8)))
        let empty = #"<feed xmlns="http://www.w3.org/2005/Atom" xmlns:o="http://a9.com/-/spec/opensearch/1.1/"><o:totalResults>0</o:totalResults></feed>"#
        try XCTAssertTrue(try ArxivClient.parseFeed(Data(empty.utf8)).articles.isEmpty)
        try XCTAssertFalse(ArxivClient.allowedURL(URL(string: "https://evil.test/file.pdf")!))
        try XCTAssertFalse(ArxivClient.allowedURL(URL(string: "http://arxiv.org/pdf/1706.03762")!))
    }

    @MainActor
    func testLibrarySearchAndArxivImport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DocumentRepository(root: root)
        let source = root.appending(path: "source.pdf")
        try makePDF(at: source, pages: ["Local original first page.", "Persistent robotics memory is useful."])
        let folder = LibraryFolder(name: "研究")
        try repository.database.save(folder)
        let article = try XCTUnwrap(ArxivClient.parseFeed(Data(arxivFixture.utf8)).articles.first)
        let document = try repository.importArxivPDF(from: source, article: article, folderID: folder.id)
        try XCTAssertEqual(document.arxiv, article)
        try XCTAssertEqual(document.folderID, folder.id)
        try XCTAssertEqual(document.sourceURL, article.abstractURL.absoluteString)
        let reopened = try DocumentRepository(root: root)
        try XCTAssertEqual(try reopened.database.documents().first?.arxiv, article)
        let items = [LibrarySearchItem(document: document, url: repository.url(for: document))]
        let index = LibrarySearchIndex()
        for query in ["ATTENTION", "rene", "张研究", "1706.03762", "abstract lines"] {
            let result = try await index.search(items, query: query)
            try XCTAssertEqual(result.hits.map(\.id), [document.id])
        }
        let body = try await index.search(items, query: "robotics memory")
        try XCTAssertEqual(body.hits.first?.page, 1)
        try XCTAssertTrue(body.hits.first?.snippet.contains("Persistent") == true)
        let absent = try await index.search(items, query: "missing term")
        try XCTAssertTrue(absent.hits.isEmpty)
        let missing = try await index.search([LibrarySearchItem(document: document, url: root.appending(path: "missing.pdf"))], query: "missing term")
        // Same-fingerprint cache remains usable; a fresh index reports unreadable files.
        try XCTAssertTrue(missing.hits.isEmpty)
        let unreadable = try await LibrarySearchIndex().search([LibrarySearchItem(document: document, url: root.appending(path: "missing.pdf"))], query: "missing term")
        try XCTAssertEqual(unreadable.unreadableCount, 1)
        let note = ReadingNote(documentID: document.id, page: 0, quote: "Local", body: "Keep this")
        try repository.database.save(note)
        let later = ArxivArticle(id: "1706.03762v3", title: "Revised title", authors: [], summary: "", published: "", category: "")
        let duplicate = try repository.importArxivPDF(from: source, article: later, folderID: nil)
        try XCTAssertEqual(duplicate.id, document.id)
        try XCTAssertEqual(duplicate.folderID, folder.id)
        try XCTAssertEqual(try repository.database.notes(documentID: document.id), [note])
        try XCTAssertEqual(try repository.database.documents().count, 1)
        let sameTitle = ArxivArticle(id: "2001.00002", title: article.title, authors: [], summary: "", published: "", category: "")
        try XCTAssertTrue(ArxivIdentifier.existing(sameTitle, in: [document]) == nil)
        let saved = try JSONEncoder().encode(document)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any]); legacy.removeValue(forKey: "arxiv")
        try XCTAssertTrue(try JSONDecoder().decode(LibraryDocument.self, from: JSONSerialization.data(withJSONObject: legacy)).arxiv == nil)
        let snapshot = try CloudArchive.capture(repository: repository)
        try XCTAssertEqual(snapshot.papers.first?.document.arxiv, article)
        let target = try DocumentRepository(root: root.appending(path: "restore"))
        _ = try CloudArchive.restore(snapshot, files: [document.fingerprint: repository.url(for: document)], into: target)
        try XCTAssertEqual(try target.database.documents().first?.arxiv, article)
        let bad = root.appending(path: "bad.pdf"); try Data("not pdf".utf8).write(to: bad)
        let other = ArxivArticle(id: "2001.00001", title: "Other", authors: [], summary: "", published: "", category: "")
        try XCTAssertThrowsError(try repository.importArxivPDF(from: bad, article: other, folderID: nil))
        try XCTAssertEqual(try repository.database.documents().count, 1)
    }

    @MainActor
    func testArxivTransportAndCancellation() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArxivFixtureProtocol.self]
        let client = ArxivClient(session: URLSession(configuration: config), minimumInterval: 0)
        ArxivFixtureProtocol.requests = []
        let page = try await client.search(query: "attention")
        _ = try await client.search(query: "attention")
        try XCTAssertEqual(ArxivFixtureProtocol.requests.count, 1)
        _ = try await client.search(query: "attention", start: 10)
        try XCTAssertEqual(ArxivFixtureProtocol.requests.count, 2)
        do { _ = try await client.search(query: "rate_limit"); try XCTFail("Expected rate limit") }
        catch { try XCTAssertTrue(error.localizedDescription.contains("限制")) }
        do { _ = try await client.search(query: "broken"); try XCTFail("Expected invalid feed") }
        catch { try XCTAssertTrue(error.localizedDescription.contains("无法识别")) }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.pdf")
        try makePDF(at: source, pages: ["Remote fixture download, original test content."])
        ArxivFixtureProtocol.pdf = try Data(contentsOf: source)
        let article = try XCTUnwrap(page.articles.first)
        let downloaded = root.appending(path: "download.pdf")
        let progress = DownloadProgressRecorder()
        try await client.download(article, to: downloaded) { await progress.append($0) }
        try XCTAssertEqual(try Data(contentsOf: downloaded), ArxivFixtureProtocol.pdf)
        let updates = await progress.values
        try XCTAssertEqual(updates.first?.receivedBytes, 0)
        try XCTAssertEqual(updates.last?.receivedBytes, ArxivFixtureProtocol.pdf.count)
        try XCTAssertEqual(updates.last?.fraction, 1)
        try XCTAssertEqual(updates.map(\.receivedBytes), updates.map(\.receivedBytes).sorted())
        let unknown = DownloadProgressRecorder()
        let unknownArticle = ArxivArticle(id: "2001.00005", title: "unknown size", authors: [], summary: "", published: "", category: "")
        try await client.download(unknownArticle, to: root.appending(path: "unknown.pdf")) { await unknown.append($0) }
        let unknownUpdates = await unknown.values
        try XCTAssertTrue(unknownUpdates.allSatisfy { $0.totalBytes == nil && $0.fraction == nil })
        try XCTAssertEqual(unknownUpdates.last?.receivedBytes, ArxivFixtureProtocol.pdf.count)
        for id in ["2001.00001", "2001.00002", "2001.00003"] {
            let invalid = ArxivArticle(id: id, title: "invalid", authors: [], summary: "", published: "", category: "")
            let file = root.appending(path: id + ".pdf")
            do { try await client.download(invalid, to: file); try XCTFail("Invalid download succeeded") }
            catch { try XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        }
        let throttled = ArxivClient(session: URLSession(configuration: config), minimumInterval: 0.2)
        _ = try await throttled.search(query: "first")
        let cancelled = Task { try await throttled.download(article, to: root.appending(path: "cancelled.pdf")) }
        try await Task.sleep(for: .milliseconds(30)); cancelled.cancel()
        do { try await cancelled.value; try XCTFail("Cancellation ignored") } catch is CancellationError { }
        try XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "cancelled.pdf").path))
        let retry = try await throttled.search(query: "after cancel")
        try XCTAssertEqual(retry.articles.count, 1)
        let interrupted = root.appending(path: "interrupted.pdf")
        let slow = ArxivArticle(id: "2001.00004", title: "slow", authors: [], summary: "", published: "", category: "")
        let active = Task { try await client.download(slow, to: interrupted) }
        try await Task.sleep(for: .milliseconds(100)); active.cancel()
        do { try await active.value; try XCTFail("Active download was not cancelled") }
        catch { try XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        try XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
    }
}

let arxivFixture = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:o="http://a9.com/-/spec/opensearch/1.1/" xmlns:a="http://arxiv.org/schemas/atom">
<title>Feed title</title><o:totalResults>11</o:totalResults><o:startIndex>0</o:startIndex>
<entry><id>http://arxiv.org/abs/1706.03762v2</id><title>Attention &amp;
Evidence</title><summary>An abstract with
multiple lines.</summary><published>2017-06-12T00:00:00Z</published>
<author><name>René Reader</name></author><author><name>张研究</name></author>
<a:primary_category term="cs.AI"/><link title="pdf" href="http://arxiv.org/pdf/1706.03762v2"/></entry></feed>
"""

final class ArxivFixtureProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var pdf = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        var status = 200, data = Data(arxivFixture.utf8), headers: [String: String] = [:]
        if url.path.hasPrefix("/pdf/") {
            data = Self.pdf
            if !url.path.hasSuffix("2001.00005") { headers["Content-Length"] = String(data.count) }
            if url.path.hasSuffix("2001.00001") { data = Data("<html>try again</html>".utf8) }
            if url.path.hasSuffix("2001.00002") { headers["Content-Length"] = "999999999" }
            if url.path.hasSuffix("2001.00003") { headers["Content-Length"] = String(data.count + 100) }
        } else {
            let text = url.absoluteString.removingPercentEncoding ?? ""
            if text.contains("rate") { status = 429 }
            if text.contains("broken") { data = Data("<html>error</html>".utf8) }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        if url.path.hasSuffix("2001.00004") { return } // Keep the response open until the client cancels it.
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private actor DownloadProgressRecorder {
    var values: [PaperDownloadProgress] = []
    func append(_ value: PaperDownloadProgress) { values.append(value) }
}
