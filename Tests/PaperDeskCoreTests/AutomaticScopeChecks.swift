import Foundation
import PaperDeskCore

extension PaperDeskCoreTests {
    func testAutomaticScopeUsesQuestionInsteadOfReadingPage() throws {
        for question in ["这篇论文的主要贡献是什么？", "分析研究方法和实验结论", "ELBO 是什么？", "为什么这样设计？", "请不要局限于当前页", "比较这一页和后面的实验", "Explain this paragraph in the context of the whole paper"] {
            try XCTAssertEqual(ChatContextBuilder.resolvedScope(.automatic, question: question, hasSelection: true), .document)
        }
        for question in ["解释这一页", "总结当前页", "What does this page mean?"] {
            try XCTAssertEqual(ChatContextBuilder.resolvedScope(.automatic, question: question, hasSelection: true), .currentPage)
        }
        for question in ["解释选中的这段话", "翻译一下", "Explain this equation"] {
            try XCTAssertEqual(ChatContextBuilder.resolvedScope(.automatic, question: question, hasSelection: true), .selection)
        }
        try XCTAssertEqual(ChatContextBuilder.resolvedScope(.automatic, question: "翻译选区", hasSelection: false), .selection)
        try XCTAssertEqual(ChatContextBuilder.resolvedScope(.currentPage, question: "总结全文", hasSelection: true), .currentPage)
        try XCTAssertEqual(ChatContextBuilder.resolvedScope(.selection, question: "比较全文", hasSelection: true), .selection)
        let chunks = (0..<5).map { SourceChunk(id: "p\($0+1)b1", page: $0, text: "Page \($0+1) evidence") }
        let broad = ChatContextBuilder.sources(chunks: chunks, scope: .automatic, page: 3, selection: [], question: "主要贡献是什么？")
        try XCTAssertEqual(Set(broad.map(\.page)), Set(0..<5))
        let local = ChatContextBuilder.sources(chunks: chunks, scope: .automatic, page: 3, selection: [], question: "只解释这一页")
        try XCTAssertEqual(local.map(\.page), [3])
        let selected = [SourceChunk(id: "p2s1", page: 1, text: "pinned passage", characterOffset: 40)]
        let exact = ChatContextBuilder.sources(chunks: chunks, scope: .automatic, page: 4, selection: selected, question: "解释这段选区")
        try XCTAssertEqual(exact, selected)
        let related = ChatContextBuilder.sources(chunks: chunks, scope: .automatic, page: 4, selection: selected,
            question: "这段选区和整篇论文是什么关系？", budget: 300)
        try XCTAssertTrue(related.contains { $0.id == "p2s1" && $0.characterOffset == 40 })
        try XCTAssertTrue(related.contains { $0.page == 0 })
        try XCTAssertTrue(related.contains { $0.page == 4 })
        try XCTAssertLessThanOrEqual(related.reduce(0) { $0 + $1.text.count }, 300)
    }

    func testDocumentRetrievalCoversDistantEvidenceAndFollowups() throws {
        var chunks = (0..<30).map { SourceChunk(id: "p\($0+1)b1", page: $0,
            text: "Page \($0+1). " + String(repeating: "Background discussion. ", count: 60), characterOffset: 12) }
        chunks[24].text = "Experiments and evaluation: ablation benchmark results. " + chunks[24].text
        chunks[26].text = "Conclusion: our contribution and objective. " + chunks[26].text
        let result = ChatContextBuilder.sources(chunks: chunks, scope: .automatic, page: 3, selection: [], question: "比较方法与实验结果，讨论主要贡献", budget: 12_000)
        try XCTAssertTrue(result.contains { $0.page == 0 })
        try XCTAssertTrue(result.contains { $0.page == 29 })
        try XCTAssertTrue(result.contains { $0.page == 24 })
        try XCTAssertTrue(result.contains { $0.page == 26 })
        try XCTAssertLessThanOrEqual(result.reduce(0) { $0 + $1.text.count }, 12_000)
        try XCTAssertEqual(Set(result.map(\.id)).count, result.count)
        for source in result {
            let original = try XCTUnwrap(chunks.first { $0.id == source.id })
            try XCTAssertTrue(original.text.hasPrefix(source.text))
            try XCTAssertEqual(source.characterOffset, original.characterOffset)
        }
        chunks[22].text = "Distinctive QuasarTopology evidence " + chunks[22].text
        let history = [ChatMessage(documentID: "fixture", role: "user", content: "Explain QuasarTopology",
            context: ChatContext(scope: .currentPage, page: 22, sourcePages: [22]))]
        let followup = ChatContextBuilder.sources(chunks: chunks, scope: .automatic, page: 1, selection: [], question: "为什么这样？", budget: 4_000, history: history)
        try XCTAssertTrue(followup.contains { $0.page == 22 })
        try XCTAssertTrue(followup.contains { $0.page != 22 })
        try XCTAssertTrue(ContextBuilder.select(chunks: chunks, question: "q", currentPage: 0, budget: 0).isEmpty)
        let tiny = ContextBuilder.select(chunks: chunks, question: "q", currentPage: 0, budget: 5)
        try XCTAssertEqual(tiny.reduce(0) { $0 + $1.text.count }, 5)
    }

    func testAutomaticContextPersistenceAndPrompt() throws {
        let context = ChatContext(scope: .document, page: 4, sourcePages: [0, 9], automaticallySelected: true)
        let data = try JSONEncoder().encode(context)
        try XCTAssertEqual(try JSONDecoder().decode(ChatContext.self, from: data), context)
        let old = try JSONDecoder().decode(ChatContext.self, from: Data(#"{"scope":"currentPage","page":3,"sourcePages":[3]}"#.utf8))
        try XCTAssertTrue(old.automaticallySelected == nil)
        try XCTAssertEqual(old.label, "第 4 页")
        try XCTAssertEqual(context.label, "自动 · 全文相关内容")
        let payload = AIClient.messages(question: "主要贡献是什么？", title: "Fixture",
            sources: [SourceChunk(id: "p1b1", page: 0, text: "Abstract"), SourceChunk(id: "p10b1", page: 9, text: "Conclusion")],
            selectedText: "", history: [], context: context)
        try XCTAssertTrue(payload[0]["content"]?.contains("不要默认把所有问题限制在这一页") == true)
        try XCTAssertTrue(payload.last?["content"]?.contains("第 5 页（仅供定位，不自动限定问题范围）") == true)
        try XCTAssertTrue(payload.last?["content"]?.contains("证据页码：1、10") == true)
        try XCTAssertTrue(payload.last?["content"]?.contains("[p10b1] PDF 第 10 页") == true)
    }
}
