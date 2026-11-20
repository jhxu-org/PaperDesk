import Foundation

public enum ChatContextBuilder {
    /// Automatic mode only narrows the evidence when the question explicitly identifies a local target.
    /// Ambiguous questions keep document-wide evidence so the answering model can interpret the intent.
    public static func resolvedScope(_ scope: ChatScope, question: String, hasSelection: Bool) -> ChatScope {
        guard scope == .automatic else { return scope }
        let question = question.lowercased()
        func matches(_ pattern: String) -> Bool { question.range(of: pattern, options: .regularExpression) != nil }
        if matches("整篇|全文|全篇|跨页|跨章节|跨章|整体|总体|这篇|这项研究|不局限|不要局限|不限于|不只|不仅|别只|不要只|对比|比较|其他页|其它页|后面|前面|摘要.*结论|\\b(whole|entire|overall|throughout|across|compare|comparison|beyond)\\b|not (just|only|limited)") {
            return .document
        }
        if matches("选中|选区|划选|这段|这一段|上述段落|这句话|这个公式|该公式|\\b(selected|selection|this passage|this paragraph|this sentence|this equation)\\b") {
            return hasSelection ? .selection : (matches("选中|选区|划选|\\b(selected|selection)\\b") ? .selection : .currentPage)
        }
        if matches("当前页|这一页|这页|本页|此页|这张图|这幅图|这个图|这张表|这个表|\\b(this page|current page|this figure|this chart|this table)\\b") { return .currentPage }
        if hasSelection && matches("^(请|帮我)?(解释|翻译|分析|总结)(一下|下)?[。？?!！ ]*$|^\\s*(explain|translate|explain this|translate this)[.?! ]*$") {
            return .selection
        }
        return .document
    }

    public static func sources(chunks: [SourceChunk], scope: ChatScope, page: Int,
                               selection: [SourceChunk], question: String, budget: Int = 24_000,
                               history: [ChatMessage] = []) -> [SourceChunk] {
        switch resolvedScope(scope, question: question, hasSelection: !selection.isEmpty) {
        case .currentPage: return bounded(chunks.filter { $0.page == page }, budget: budget)
        case .selection: return bounded(selection, budget: min(budget, 8_000))
        case .automatic, .document:
            var retrievalQuestion = question
            // Resolve short follow-ups against their recent topic, without inheriting a single-page restriction.
            if question.count < 100, question.range(of: "为什么|为何|这个|那个|它|上述|前者|后者|继续|具体|\\b(why|that|it|those|more|continue)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                if let previous = history.last(where: { $0.role == "user" }) { retrievalQuestion += "\n" + previous.content.prefix(1_000) }
                if let previous = history.last(where: { $0.role == "assistant" }) { retrievalQuestion += "\n" + previous.content.prefix(1_000) }
            }
            let focus = scope == .automatic ? bounded(selection, budget: min(4_000, max(0, budget / 4))) : []
            let used = focus.reduce(0) { $0 + $1.text.count }
            let focusIDs = Set(focus.map(\.id))
            let evidence = ContextBuilder.select(chunks: chunks.filter { !focusIDs.contains($0.id) },
                question: retrievalQuestion, currentPage: page, budget: budget - used)
            return focus + evidence
        }
    }
    private static func bounded(_ sources: [SourceChunk], budget: Int) -> [SourceChunk] {
        var remaining = max(0, budget)
        var result: [SourceChunk] = []
        for var source in sources where remaining > 0 {
            source.text = String(source.text.prefix(remaining))
            remaining -= source.text.count
            if !source.text.isEmpty { result.append(source) }
        }
        return result
    }
}

public struct ModelPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public static let all: [ModelPreset] = [
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com"),
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1"),
        .init(id: "ollama", name: "Ollama（本机）", baseURL: "http://localhost:11434/v1"),
        .init(id: "custom", name: "自定义兼容接口", baseURL: "")
    ]
}
