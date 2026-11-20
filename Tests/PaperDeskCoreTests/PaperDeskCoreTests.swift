import Foundation
import AppKit
import PDFKit
import PaperDeskCore

final class PaperDeskCoreTests {
    @MainActor
    func testImportDeduplicatesAndPersistsLibraryAndAnnotations() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "研究样本.pdf")
        try makePDF(at: source, pages: ["Evidence must remain attached to its source.", "A second page supports navigation."])
        let repository = try DocumentRepository(root: root.appending(path: "Library"))
        var document = try repository.importPDF(from: source)
        let duplicate = try repository.importPDF(from: source)
        try XCTAssertEqual(document.id, duplicate.id)
        try XCTAssertEqual(try repository.database.documents().count, 1)
        try XCTAssertEqual(document.pageCount, 2)
        try XCTAssertEqual(document.title, "研究样本")
        try XCTAssertNotEqual(repository.url(for: document), source)
        document.currentPage = 1
        try repository.database.save(document)
        let note = ReadingNote(documentID: document.id, page: 1, quote: "A second page", body: "值得进一步讨论",
            rects: [PageRect(x: 32, y: 700, width: 150, height: 14)])
        try repository.database.save(note)
        let message = ChatMessage(documentID: document.id, role: "assistant", content: "有依据 [p2b1]",
            sources: [SourceChunk(id: "p2b1", page: 1, text: "A second page", characterOffset: 0)])
        try repository.database.save(message)

        let reopened = try DocumentRepository(root: repository.root)
        try XCTAssertEqual(try reopened.database.documents().first?.currentPage, 1)
        try XCTAssertEqual(try reopened.database.notes(documentID: document.id), [note])
        try XCTAssertEqual(try reopened.database.messages(documentID: document.id), [message])
        // Original-file deletion must not break the imported copy.
        try FileManager.default.removeItem(at: source)
        try XCTAssertEqual(PDFDocument(url: reopened.url(for: document))?.pageCount, 2)
        try reopened.database.deleteNote(id: note.id)
        try XCTAssertTrue(try reopened.database.notes(documentID: document.id).isEmpty)
        try XCTAssertThrowsError(try reopened.database.save(ReadingNote(documentID: "missing-document", page: 0, quote: "orphan")))
    }

    @MainActor
    func testInvalidPDFDoesNotLeaveLibraryEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DocumentRepository(root: root)
        let source = root.appending(path: "broken.pdf")
        try Data("not a pdf".utf8).write(to: source)
        try XCTAssertThrowsError(try repository.importPDF(from: source))
        try XCTAssertTrue(try repository.database.documents().isEmpty)
        try XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: repository.documentDirectory.path).isEmpty)
    }

    @MainActor
    func testExtractedOffsetsResolveBackToExactPDFText() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let paragraph = Array(repeating: "Evidence-first reading keeps each claim tied to an original passage.", count: 30).joined(separator: "\n")
        try makePDF(at: url, pages: [paragraph, "Second page: source identity survives extraction."])
        let chunks = try PDFTextExtractor.extract(from: url)
        try XCTAssertGreaterThan(chunks.count, 2)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        for chunk in chunks {
            let page = try XCTUnwrap(pdf.page(at: chunk.page))
            let text = try XCTUnwrap(page.string) as NSString
            try XCTAssertEqual(text.substring(with: NSRange(location: chunk.characterOffset, length: chunk.text.utf16.count)), chunk.text)
            try XCTAssertNotNil(page.selection(for: NSRange(location: chunk.characterOffset, length: chunk.text.utf16.count)))
        }
        try XCTAssertEqual(chunks.last?.page, 1)
    }

    func testRetrievalBudgetAndCitationsAreBoundedByRealSources() throws {
        let sources = [
            SourceChunk(id: "p1b1", page: 0, text: String(repeating: "introduction ", count: 20)),
            SourceChunk(id: "p2b1", page: 1, text: String(repeating: "quantum evidence ", count: 20)),
            SourceChunk(id: "p3b1", page: 2, text: String(repeating: "appendix ", count: 20))
        ]
        let result = ContextBuilder.select(chunks: sources, question: "quantum", currentPage: 2, budget: 400)
        try XCTAssertTrue(result.contains { $0.id == "p2b1" && $0.text == sources[1].text })
        try XCTAssertTrue(result.allSatisfy { source in sources.contains { $0.id == source.id && $0.text.hasPrefix(source.text) } })
        try XCTAssertLessThanOrEqual(result.reduce(0) { $0 + $1.text.count }, 400)
        try XCTAssertEqual(ContextBuilder.citedSources(in: "Evidence [p2b1], fabricated [p999b9]", candidates: sources).map(\.id), ["p2b1"])
        try XCTAssertTrue(ContextBuilder.select(chunks: [], question: "anything", currentPage: 0).isEmpty)
    }

    @MainActor
    func testAnnotationExportPreservesExistingMarks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "original.pdf")
        try makePDF(at: url, pages: ["An original document with an existing highlight."])
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let existing = PDFAnnotation(bounds: CGRect(x: 30, y: 900, width: 100, height: 14), forType: .highlight, withProperties: nil)
        existing.setValue("previous-export", forAnnotationKey: PDFAnnotationKey(rawValue: "PaperDeskID"))
        existing.contents = "Imported annotation"
        page.addAnnotation(existing)
        let overlay = PDFAnnotationOverlay()
        var note = ReadingNote(documentID: "sample", page: 0, quote: "original document", body: "First note",
            rects: [PageRect(x: 30, y: 860, width: 120, height: 14)])
        overlay.apply([note], to: document)
        overlay.apply([note], to: document)
        try XCTAssertEqual(page.annotations.count, 2)
        note.body = "Edited note"
        overlay.apply([note], to: document)
        try XCTAssertEqual(page.annotations.count, 2)
        let output = root.appending(path: "annotated.pdf")
        try XCTAssertTrue(document.write(to: output))
        let exported = try XCTUnwrap(PDFDocument(url: output))
        let exportedPage = try XCTUnwrap(exported.page(at: 0))
        try XCTAssertEqual(exportedPage.annotations.count, 2)
        try XCTAssertTrue(exportedPage.annotations.contains { $0.contents == "Edited note" })
        try XCTAssertEqual(exported.outlineRoot?.numberOfChildren, 1)
        overlay.apply([], to: document)
        try XCTAssertEqual(page.annotations.count, 1)
        try XCTAssertEqual(page.annotations.first?.contents, "Imported annotation")
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        let newSession = PDFAnnotationOverlay()
        newSession.apply([], to: reopened)
        try XCTAssertEqual(reopened.page(at: 0)?.annotations.count, 2)
    }

    func testEndpointValidation() throws {
        try XCTAssertEqual(try APIConfiguration(baseURL: "https://example.com/v1/", model: "model", apiKey: "").endpoint().absoluteString, "https://example.com/v1/chat/completions")
        try XCTAssertEqual(try APIConfiguration(baseURL: "https://example.com/v1/chat/completions", model: "model", apiKey: "").endpoint().path, "/v1/chat/completions")
        try XCTAssertNoThrow(try APIConfiguration(baseURL: "http://127.0.0.1:1234/v1", model: "local", apiKey: "").endpoint())
        try XCTAssertThrowsError(try APIConfiguration(baseURL: "http://remote.example/v1", model: "model", apiKey: "secret").endpoint())
        try XCTAssertThrowsError(try APIConfiguration(baseURL: "https://user:secret@example.com/v1", model: "model", apiKey: "").endpoint())
        try XCTAssertThrowsError(try APIConfiguration(baseURL: "https://example.com/v1?token=secret", model: "model", apiKey: "").endpoint())
        try XCTAssertThrowsError(try APIConfiguration(baseURL: "https://example.com/v1", model: " ", apiKey: "").endpoint())
    }

    func testChatRequestAndAnswerThroughStubbedTransport() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let answer = try await AIClient(session: session).answer(
            configuration: APIConfiguration(baseURL: "https://success.example/v1", model: "fixture-model", apiKey: "test-key"),
            question: "What is supported?", title: "Sample", sources: [SourceChunk(id: "p1b1", page: 0, text: "Evidence text")],
            selectedText: "Selected passage", history: [])
        try XCTAssertEqual(answer, "A grounded answer [p1b1]")
    }

    func testAuthenticationFailureDoesNotExposeProviderPayload() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AIClient(session: session).answer(
                configuration: APIConfiguration(baseURL: "https://denied.example/v1", model: "fixture-model", apiKey: "test-key"),
                question: "test", title: "Sample", sources: [], selectedText: "", history: [])
            try XCTFail("Expected an authentication error")
        } catch {
            try XCTAssertTrue(error.localizedDescription.contains("认证"))
            try XCTAssertFalse(error.localizedDescription.contains("provider-secret"))
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: config)
    }

    @MainActor
    func makePDF(at url: URL, pages: [String]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 1000)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(in: CGRect(x: 30, y: 30, width: 552, height: 940), withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        let children: [[String: Any]] = pages.indices.map {
            [kCGPDFOutlineTitle as String: "Chapter \($0 + 1)", kCGPDFOutlineDestination as String: $0 + 1]
        }
        CGPDFContextSetOutline(context, [kCGPDFOutlineChildren as String: children] as CFDictionary)
        context.closePDF()
    }
}

private final class FixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let denied = url.host == "denied.example"
        var data: Data
        var code = denied ? 401 : 200
        if denied { data = Data("provider-secret".utf8) }
        else {
            let body: Data
            if let direct = request.httpBody { body = direct }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bytes.append(buffer, count: count)
                }
                body = bytes
            } else { body = Data() }
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let messages = json?["messages"] as? [[String: String]]
            let content = messages?.last?["content"] ?? ""
            if request.httpMethod != "POST" || request.value(forHTTPHeaderField: "Authorization") != "Bearer test-key" ||
                json?["model"] as? String != "fixture-model" || !content.contains("[p1b1]") || !content.contains("Selected passage") ||
                url.path != "/v1/chat/completions" { code = 400 }
            data = Data(#"{"choices":[{"message":{"content":"A grounded answer [p1b1]"}}]}"#.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
