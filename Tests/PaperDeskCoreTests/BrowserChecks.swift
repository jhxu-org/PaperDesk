import Foundation
import PaperDeskCore

extension PaperDeskCoreTests {
    @MainActor
    func testBrowserTransferAndLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "fixture.pdf")
        try makePDF(at: source, pages: ["Imported from a browser, ready for grounded analysis."])
        let data = try Data(contentsOf: source)
        let inbox = BrowserImportInbox(root: root)
        let transfer = BrowserPDFTransfer(inbox: inbox)
        let id = try transfer.begin(title: "研究文献", sourceURL: "https://example.org/research.pdf?signature=private-token#page=2")
        for (sequence, start) in stride(from: 0, to: data.count, by: 91).enumerated() {
            try transfer.append(sequence: sequence, base64: data.subdata(in: start..<min(start+91, data.count)).base64EncodedString())
        }
        try XCTAssertTrue(inbox.pendingIDs().isEmpty)
        try XCTAssertEqual(try transfer.prepare(byteCount: data.count), id)
        try XCTAssertEqual(inbox.pendingIDs(), [id])
        let metadata = try inbox.metadata(id)
        try XCTAssertEqual(metadata.sourceURL, "https://example.org/research.pdf")
        let repository = try DocumentRepository(root: root)
        let file = try inbox.directory(id).appending(path: "document.pdf")
        let document = try repository.importPDF(from: file, title: metadata.title, sourceURL: metadata.sourceURL)
        try XCTAssertEqual(document.title, "研究文献")
        try XCTAssertEqual(document.sourceURL, metadata.sourceURL)
        let duplicate = try repository.importPDF(from: file, title: "Do not replace title", sourceURL: metadata.sourceURL)
        try XCTAssertEqual(duplicate.id, document.id)
        try XCTAssertEqual(duplicate.title, "研究文献")
        try inbox.finish(id, receipt: .init(ok: true, message: "Imported"))
        try XCTAssertTrue(inbox.pendingIDs().isEmpty)
        let receipt = try JSONDecoder().decode(BrowserImportReceipt.self, from: Data(contentsOf: inbox.receiptURL(id)))
        try XCTAssertTrue(receipt.ok)
        try XCTAssertEqual(try repository.database.documents().count, 1)
    }
    func testBrowserTransferRejectsInvalidAndInterruptedInput() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = BrowserImportInbox(root: root)
        var transfer: BrowserPDFTransfer? = BrowserPDFTransfer(inbox: inbox)
        let id = try transfer!.begin(title: "Not a PDF", sourceURL: "https://example.org/file")
        try XCTAssertThrowsError(try transfer!.append(sequence: 1, base64: Data("test".utf8).base64EncodedString()))
        try XCTAssertThrowsError(try transfer!.append(sequence: 0, base64: "%%%"))
        try XCTAssertThrowsError(try transfer!.append(sequence: 0, base64: Data(repeating: 65, count: BrowserPDFTransfer.chunkBytes+1).base64EncodedString()))
        try transfer!.append(sequence: 0, base64: Data("<html>login required</html>".utf8).base64EncodedString())
        try XCTAssertThrowsError(try transfer!.prepare(byteCount: 1))
        try XCTAssertThrowsError(try transfer!.prepare(byteCount: 27))
        try XCTAssertTrue(inbox.pendingIDs().isEmpty)
        transfer = nil
        try XCTAssertFalse(FileManager.default.fileExists(atPath: try inbox.directory(id).path))
    }
    func testBrowserURLAndLegacyMetadata() throws {
        let id = UUID().uuidString
        try XCTAssertEqual(try BrowserImportInbox.importID(from: URL(string: "paperdesk://browser-import/\(id)")!), id)
        for value in ["paperdesk://browser-import/../../etc/passwd", "paperdesk://browser-import/\(id)?file=/etc/passwd", "https://browser-import/\(id)", "paperdesk://browser-import/\(id)/extra", "paperdesk://user@browser-import/\(id)"] {
            try XCTAssertThrowsError(try BrowserImportInbox.importID(from: URL(string: value)!))
        }
        for value in ["file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.org/file.pdf", "blob:https://example.org/id"] {
            try XCTAssertThrowsError(try BrowserImportInbox.sourceURL(value))
        }
        let legacy = Data(#"{"id":"old","title":"Old document","filename":"old.pdf","fingerprint":"abc","pageCount":1,"currentPage":0,"addedAt":0,"lastOpenedAt":0}"#.utf8)
        try XCTAssertEqual(try JSONDecoder().decode(LibraryDocument.self, from: legacy).sourceURL, nil)
    }
    func testNativeMessageFraming() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.path, contents: nil)
        let output = try FileHandle(forWritingTo: root)
        let payload = Data(#"{"type":"ping","title":"中文"}"#.utf8)
        try NativeMessageFraming.write(payload, to: output)
        try output.close()
        let input = try FileHandle(forReadingFrom: root)
        defer { try? input.close() }
        try XCTAssertEqual(try NativeMessageFraming.read(from: input), payload)
        try XCTAssertEqual(try NativeMessageFraming.read(from: input), nil)
        try Data([1,0]).write(to: root)
        let truncated = try FileHandle(forReadingFrom: root)
        defer { try? truncated.close() }
        try XCTAssertThrowsError(try NativeMessageFraming.read(from: truncated))
        try Data([255,255,255,127]).write(to: root)
        let oversized = try FileHandle(forReadingFrom: root)
        defer { try? oversized.close() }
        try XCTAssertThrowsError(try NativeMessageFraming.read(from: oversized))
    }
}
