import Foundation
import AppKit
import PDFKit
import PaperDeskCore

extension PaperDeskCoreTests {
    func testVisualScopeAndProvenance() throws {
        let chunks = [SourceChunk(id: "p1b1", page: 0, text: "Abstract and introduction"),
            SourceChunk(id: "p2b1", page: 1, text: "🧪 Evidence\nFigure 1: Architecture.\nFigure 2: Training."),
            SourceChunk(id: "p9b1", page: 8, text: "Results\nTable 3: Ablation outcomes."),
            SourceChunk(id: "p12b1", page: 11, text: "\nFigure 3: Evaluation curve.", characterOffset: 200)]
        let visuals = ChatVisualBuilder.candidates(chunks: chunks, sources: [chunks[0]], scope: .document,
            page: 0, question: "解释图 3", pageCount: 12)
        try XCTAssertEqual(visuals.first?.page, 11)
        try XCTAssertEqual(Set(visuals.map(\.page)).count, visuals.count)
        try XCTAssertLessThanOrEqual(visuals.count, 3)
        for visual in visuals {
            let source = try XCTUnwrap(visual.source)
            let original = try XCTUnwrap(chunks.first { $0.id == source.id })
            let range = NSRange(location: source.characterOffset - original.characterOffset, length: source.text.utf16.count)
            try XCTAssertEqual((original.text as NSString).substring(with: range), source.text)
        }
        let local = ChatVisualBuilder.candidates(chunks: chunks, sources: [chunks[0]], scope: .currentPage,
            page: 0, question: "Figure 3", pageCount: 12)
        try XCTAssertEqual(local.map(\.page), [0])
        let selection = ChatVisualBuilder.candidates(chunks: chunks, sources: [chunks[1]], scope: .selection,
            page: 0, question: "Figure 3", pageCount: 12)
        try XCTAssertEqual(selection.map(\.page), [1])
        try XCTAssertEqual(ChatVisualBuilder.cited(in: "[visual:p12] [visual:p99]", candidates: visuals).map(\.page), [11])
        try XCTAssertEqual(ChatContextBuilder.resolvedScope(.automatic, question: "解释这张图", hasSelection: false), .currentPage)
        try XCTAssertEqual(ChatContextBuilder.resolvedScope(.automatic, question: "对比图1和图3", hasSelection: false), .document)
    }

    func testVisualRequestCompatibility() throws {
        let visual = ChatVisual(page: 1, caption: "Figure 1: Original diagram")
        let image = ChatPageImage(visual: visual, jpeg: Data([0xff, 0xd8, 0xff, 0xd9]))
        let history = [ChatMessage(documentID: "d", role: "assistant", content: visual.marker, visuals: [visual])]
        let text = AIClient.requestMessages(question: "explain", title: "fixture", sources: [], selectedText: "",
            history: history, context: nil, visuals: [visual], images: [])
        try XCTAssertTrue((text.last?["content"] as? String)?.contains("本轮未向模型发送图片") == true)
        let multimodal = AIClient.requestMessages(question: "explain", title: "fixture", sources: [], selectedText: "",
            history: history, context: nil, visuals: [visual], images: [image, ChatPageImage(visual: ChatVisual(page: 98, caption: "unknown"), jpeg: image.jpeg)])
        let parts = try XCTUnwrap(multimodal.last?["content"] as? [[String: Any]])
        try XCTAssertEqual(parts.filter { $0["type"] as? String == "image_url" }.count, 1)
        let attached = try XCTUnwrap(parts.last?["image_url"] as? [String: String])
        try XCTAssertEqual(attached["url"], image.dataURL)
        try XCTAssertTrue(multimodal[1]["content"] is String)
        try XCTAssertNoThrow(JSONSerialization.data(withJSONObject: multimodal))
        let message = ChatMessage(documentID: "d", role: "assistant", content: visual.marker, visuals: [visual])
        try XCTAssertEqual(JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)), message)
        let legacy = Data(#"{"id":"old","documentID":"d","role":"assistant","content":"old","sources":[],"createdAt":0}"#.utf8)
        try XCTAssertTrue(JSONDecoder().decode(ChatMessage.self, from: legacy).visuals == nil)
    }

    @MainActor func testVisualRenderingAndPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DocumentRepository(root: root)
        let url = root.appending(path: "visual.pdf")
        try makePDF(at: url, pages: ["Figure 1: An original test illustration.", "Table 1: Test values."])
        let doc = try repository.importPDF(from: url)
        let visual = ChatVisual(page: 1, caption: "Table 1: Test values.")
        let worker = Task.detached { try ChatVisualBuilder.render(url: url, visuals: [visual], maxDimension: 800) }
        let image = try XCTUnwrap(try await worker.value.first)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.jpeg))
        try XCTAssertGreaterThan(bitmap.pixelsWide, 100)
        try XCTAssertGreaterThan(bitmap.pixelsHigh, bitmap.pixelsWide)
        try XCTAssertLessThanOrEqual(image.jpeg.count, 3_000_000)
        let message = ChatMessage(documentID: doc.id, role: "assistant", content: visual.marker, visuals: [visual])
        try repository.database.save(message)
        let reopened = try DocumentRepository(root: root)
        try XCTAssertEqual(reopened.database.messages(documentID: doc.id), [message])
        // History stores portable page provenance, not image bytes or machine-specific paths.
        let data = try JSONEncoder().encode(message)
        try XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("base64"))
        try FileManager.default.removeItem(at: url)
        try XCTAssertEqual(ChatVisualBuilder.render(url: repository.url(for: doc), visuals: [visual]).first?.visual, visual)
        try XCTAssertThrowsError(ChatVisualBuilder.render(url: repository.url(for: doc), visuals: [ChatVisual(page: 999, caption: "invalid")]))
    }
}
