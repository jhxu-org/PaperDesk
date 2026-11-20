import Foundation
import PaperDeskCore

extension PaperDeskCoreTests {
    func testLocalFixtureTransport(baseURL: String) async throws {
        guard URL(string: baseURL)?.host == "127.0.0.1" else { throw CheckFailure(description: "Fixture must be a loopback server") }
        let client = AIClient()
        let config = APIConfiguration(baseURL: baseURL, model: "paperdesk-local-fixture", apiKey: "")
        let models = try await client.listModels(configuration: config)
        try XCTAssertEqual(models, ["paperdesk-local-fixture"])
        try await client.testConnection(configuration: config)
        let recorder = UpdateRecorder()
        let context = ChatContext(scope: .currentPage, page: 1, sourcePages: [1])
        let question = "Explain this page"
        let answer = try await client.reply(configuration: config, question: question, title: "Synthetic fixture",
            sources: [SourceChunk(id: "p2b1", page: 1, text: "Synthetic second page")], selectedText: "", history: [],
            context: context) { text in await recorder.append(text) }
        try XCTAssertTrue(answer.contains("第 2 页"))
        try XCTAssertTrue(answer.contains("历史对话 0 条"))
        let updates = await recorder.count()
        try XCTAssertGreaterThan(updates, 1)
        let followup = try await client.reply(configuration: config, question: "And this page?", title: "Synthetic fixture",
            sources: [SourceChunk(id: "p3b1", page: 2, text: "Synthetic third page")], selectedText: "",
            history: [ChatMessage(documentID: "fixture", role: "user", content: question, context: context),
                      ChatMessage(documentID: "fixture", role: "assistant", content: answer, context: context)],
            context: ChatContext(scope: .currentPage, page: 2, sourcePages: [2])) { _ in }
        try XCTAssertTrue(followup.contains("第 3 页"))
        try XCTAssertTrue(followup.contains("历史对话 2 条"))
        try XCTAssertTrue(followup.contains("[p3b1]"))
        let cancelled = Task {
            try await client.reply(configuration: config, question: "q", title: "Synthetic fixture", sources: [], selectedText: "",
                history: [], context: context) { _ in }
        }
        try await Task.sleep(for: .milliseconds(150))
        cancelled.cancel()
        do { _ = try await cancelled.value; try XCTFail("Cancelled request completed") }
        catch is CancellationError { }
        catch let error as URLError { try XCTAssertEqual(error.code, .cancelled) }
    }

    func testCurrentPageIsolationAndSelectionProvenance() throws {
        let chunks = [SourceChunk(id: "p1b1", page: 0, text: "Page one: quantum"),
                      SourceChunk(id: "p2b1", page: 1, text: "Page two: evidence"),
                      SourceChunk(id: "p2b2", page: 1, text: "Current page continuation", characterOffset: 20),
                      SourceChunk(id: "p3b1", page: 2, text: "Page three: quantum")]
        let page = ChatContextBuilder.sources(chunks: chunks, scope: .currentPage, page: 1,
            selection: [], question: "quantum", budget: 100)
        try XCTAssertEqual(page.map(\.id), ["p2b1", "p2b2"])
        try XCTAssertTrue(ChatContextBuilder.sources(chunks: chunks, scope: .currentPage, page: 9, selection: [], question: "quantum").isEmpty)
        let selection = [SourceChunk(id: "p2s1", page: 1, text: "Selected range", characterOffset: 9),
                         SourceChunk(id: "p3s1", page: 2, text: "Another range", characterOffset: 80)]
        let selected = ChatContextBuilder.sources(chunks: chunks, scope: .selection, page: 0,
            selection: selection, question: "translate", budget: 17)
        try XCTAssertEqual(selected.map(\.id), ["p2s1", "p3s1"])
        try XCTAssertEqual(selected.last?.characterOffset, 80)
        try XCTAssertEqual(selected.reduce(0) { $0 + $1.text.count }, 17)
        let context = ChatContext(scope: .currentPage, page: 1, sourcePages: [1])
        let history = [ChatMessage(documentID: "doc", role: "user", content: "previous question",
            context: ChatContext(scope: .currentPage, page: 0, sourcePages: [0]))]
        let messages = AIClient.messages(question: "what does this mean", title: "test", sources: page,
            selectedText: "", history: history, context: context)
        try XCTAssertTrue(messages[1]["content"]?.contains("第 1 页") == true)
        try XCTAssertTrue(messages.last?["content"]?.contains("当前阅读位置：PDF 第 2 页") == true)
        try XCTAssertFalse(messages.last?["content"]?.contains("Page one") == true)
    }

    func testLegacyConversationAndContextRoundTrip() throws {
        let legacy = Data(#"{"id":"old","documentID":"d","role":"user","content":"old question","sources":[],"createdAt":0}"#.utf8)
        let old = try JSONDecoder().decode(ChatMessage.self, from: legacy)
        try XCTAssertTrue(old.context == nil)
        let context = ChatContext(scope: .selection, page: 3, sourcePages: [3, 4])
        let message = ChatMessage(documentID: "d", role: "user", content: "why", context: context)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        try XCTAssertEqual(decoded.context, context)
    }

    func testSSEDecodingAndIncompleteStream() throws {
        var stream = ChatStreamDecoder()
        try stream.consume(": keep-alive")
        try stream.consume("event: message")
        try stream.consume(#"data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#)
        try stream.consume(#"data: {"choices":[{"index":0,"delta":{"reasoning_content":"internal"}}]}"#)
        try stream.consume(#"data: {"choices":[{"index":0,"delta":{"content":"依据原文 "}}]}"#)
        try stream.consume("")
        try stream.consume(#"data: {"choices": ["#)
        try stream.consume(#"data: {"index":0,"delta":{"content":"[p2b1]"},"finish_reason":"stop"}]}"#)
        try stream.consume(#"data: {"choices":[],"usage":{"total_tokens":3}}"#)
        try stream.consume("data: [DONE]")
        try XCTAssertEqual(try stream.finish(), "依据原文 [p2b1]")
        var partial = ChatStreamDecoder()
        try partial.consume(#"data: {"choices":[{"delta":{"content":"partial"}}]}"#)
        try XCTAssertThrowsError(try partial.finish())
        var failure = ChatStreamDecoder()
        try XCTAssertThrowsError(try failure.consume(#"data: {"error":{"message":"provider-secret"}}"#))
    }

    func testStreamingTransportAndModelDiscovery() async throws {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [StreamingFixtureProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let client = AIClient(session: session)
        let configuration = APIConfiguration(baseURL: "https://stream.example/v1/", model: "fixture", apiKey: "")
        let ids = try await client.listModels(configuration: configuration)
        try XCTAssertEqual(ids, ["fixture", "other"])
        let recorder = UpdateRecorder()
        let answer = try await client.reply(configuration: configuration, question: "question", title: "sample",
            sources: [SourceChunk(id: "p2b1", page: 1, text: "Only page two")], selectedText: "", history: [],
            context: ChatContext(scope: .currentPage, page: 1, sourcePages: [1])) { text in await recorder.append(text) }
        try XCTAssertEqual(answer, "分析第二页 [p2b1]")
        let finalUpdate = await recorder.last()
        try XCTAssertEqual(finalUpdate, answer)
        try await client.testConnection(configuration: configuration)
        var fallback = configuration; fallback.baseURL = "https://json.example/v1"
        let jsonAnswer = try await client.reply(configuration: fallback, question: "q", title: "sample", sources: [],
            selectedText: "", history: [], context: ChatContext(scope: .currentPage, page: 0, sourcePages: [])) { _ in }
        try XCTAssertEqual(jsonAnswer, "JSON fallback")
    }

    func testConnectionPayloadContainsNoDocument() async throws {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [StreamingFixtureProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        try await AIClient(session: session).testConnection(configuration: APIConfiguration(
            baseURL: "https://test-only.example/v1", model: "fixture", apiKey: "", streamResponses: false))
        let a = APIConfiguration(baseURL: "https://example.com/v1/", model: "m", apiKey: "").credentialAccount
        let b = APIConfiguration(baseURL: "https://example.com/v1/chat/completions/", model: "n", apiKey: "").credentialAccount
        try XCTAssertEqual(a, b)
        try XCTAssertNotEqual(a, APIConfiguration(baseURL: "https://another.example/v1", model: "m", apiKey: "").credentialAccount)
        try XCTAssertEqual(try APIConfiguration(baseURL: "https://example.com/", model: "m", apiKey: "").endpoint().absoluteString,
                          "https://example.com/chat/completions")
    }

    func testCancellationStopsPendingStream() async throws {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [StreamingFixtureProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let task = Task {
            try await AIClient(session: session).reply(configuration: APIConfiguration(baseURL: "https://pending.example/v1", model: "fixture", apiKey: ""),
                question: "q", title: "test", sources: [], selectedText: "", history: [],
                context: ChatContext(scope: .currentPage, page: 0, sourcePages: [])) { _ in }
        }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do { _ = try await task.value; try XCTFail("Cancelled stream unexpectedly completed") }
        catch is CancellationError { }
        catch let error as URLError { try XCTAssertEqual(error.code, .cancelled) }
    }
}

private actor UpdateRecorder {
    var values: [String] = []
    func append(_ text: String) { values.append(text) }
    func last() -> String? { values.last }
    func count() -> Int { values.count }
}

private final class StreamingFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var mime = "text/event-stream"
        var code = 200
        var body = ""
        if url.path.hasSuffix("/models") {
            mime = "application/json"
            body = #"{"data":[{"id":"other"},{"id":"fixture"},{"id":"fixture"}]}"#
        } else if url.host == "test-only.example" {
            var input = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; input.append(buffer, count: count)
                }
            }
            let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
            let messages = payload?["messages"] as? [[String: String]]
            if messages?.count != 1 || messages?.first?["content"] != "Connection test. Reply with only OK." { code = 400 }
            mime = "application/json"; body = #"{"choices":[{"message":{"content":"OK"}}]}"#
        } else if url.host == "json.example" {
            mime = "application/json"; body = #"{"choices":[{"message":{"content":"JSON fallback"}}]}"#
        } else {
            body = ": keepalive\n\n" +
                #"data: {"choices":[{"index":0,"delta":{"content":"分析"}}]}"# + "\n\n" +
                #"data: {"choices":[{"index":0,"delta":{"content":"第二页 [p2b1]"},"finish_reason":"stop"}]}"# + "\n\n" +
                "data: [DONE]\n\n"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!, cacheStoragePolicy: .notAllowed)
        if url.host == "pending.example" {
            client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n".utf8))
            return
        }
        let bytes = Array(body.utf8)
        // Deliberately split multibyte Unicode characters and SSE boundaries across transport chunks.
        for start in stride(from: 0, to: bytes.count, by: 7) {
            client?.urlProtocol(self, didLoad: Data(bytes[start..<min(start + 7, bytes.count)]))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
