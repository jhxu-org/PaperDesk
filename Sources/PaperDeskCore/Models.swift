import Foundation

public struct LibraryDocument: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var filename: String
    public var fingerprint: String
    public var pageCount: Int
    public var currentPage: Int
    public var addedAt: Date
    public var lastOpenedAt: Date
    public var sourceURL: String?
    public var folderID: String?
    public var arxiv: ArxivArticle?

    public init(id: String = UUID().uuidString, title: String, filename: String, fingerprint: String,
                pageCount: Int, currentPage: Int = 0, addedAt: Date = Date(), lastOpenedAt: Date = Date(), sourceURL: String? = nil, folderID: String? = nil) {
        self.id = id; self.title = title; self.filename = filename; self.fingerprint = fingerprint
        self.pageCount = pageCount; self.currentPage = currentPage
        self.addedAt = addedAt; self.lastOpenedAt = lastOpenedAt
        self.sourceURL = sourceURL
        self.folderID = folderID
    }
}

public struct LibraryFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var parentID: String?
    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), parentID: String? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.parentID = parentID
    }
}

public struct PageRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct ReadingNote: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var documentID: String
    public var page: Int
    public var quote: String
    public var body: String
    public var rects: [PageRect]
    public var createdAt: Date
    public init(id: String = UUID().uuidString, documentID: String, page: Int, quote: String,
                body: String = "", rects: [PageRect] = [], createdAt: Date = Date()) {
        self.id = id; self.documentID = documentID; self.page = page; self.quote = quote
        self.body = body; self.rects = rects; self.createdAt = createdAt
    }
}

public struct SourceChunk: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var page: Int // zero-based, always the physical PDF page
    public var text: String
    public var characterOffset: Int
    public init(id: String, page: Int, text: String, characterOffset: Int = 0) {
        self.id = id; self.page = page; self.text = text; self.characterOffset = characterOffset
    }
}

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var documentID: String
    public var role: String
    public var content: String
    public var sources: [SourceChunk]
    public var createdAt: Date
    public var context: ChatContext?
    public var visuals: [ChatVisual]?
    public init(id: String = UUID().uuidString, documentID: String, role: String, content: String,
                sources: [SourceChunk] = [], createdAt: Date = Date(), context: ChatContext? = nil, visuals: [ChatVisual]? = nil) {
        self.id = id; self.documentID = documentID; self.role = role; self.content = content
        self.sources = sources; self.createdAt = createdAt
        self.context = context
        self.visuals = visuals
    }
}

public enum ChatScope: String, Codable, CaseIterable, Sendable {
    case automatic, currentPage, selection, document
    public var title: String {
        switch self {
        case .automatic: return "自动识别"
        case .currentPage: return "当前页"
        case .selection: return "选中内容"
        case .document: return "全文相关内容"
        }
    }
}

public struct ChatContext: Codable, Equatable, Sendable {
    public var scope: ChatScope
    public var page: Int
    public var sourcePages: [Int]
    public var automaticallySelected: Bool?
    public init(scope: ChatScope, page: Int, sourcePages: [Int], automaticallySelected: Bool = false) {
        self.scope = scope; self.page = page; self.sourcePages = sourcePages.sorted()
        self.automaticallySelected = automaticallySelected ? true : nil
    }
    public var label: String {
        let prefix = automaticallySelected == true ? "自动 · " : ""
        switch scope {
        case .automatic: return "自动识别"
        case .currentPage: return prefix + "第 \(page + 1) 页"
        case .selection:
            let pages = sourcePages.map { String($0 + 1) }.joined(separator: "、")
            return prefix + "选区 · 第 \(pages.isEmpty ? String(page + 1) : pages) 页"
        case .document: return prefix + "全文相关内容"
        }
    }
}

public struct APIConfiguration: Sendable {
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var streamResponses: Bool
    public init(baseURL: String, model: String, apiKey: String, streamResponses: Bool = true) {
        self.baseURL = baseURL; self.model = model; self.apiKey = apiKey
        self.streamResponses = streamResponses
    }

    public func rootURL() throws -> URL {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw PaperDeskError.message("请输入有效的 API 基础地址。") }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard url.scheme == "https" || (url.scheme == "http" && local) else {
            throw PaperDeskError.message("远程 API 请使用 HTTPS；本机服务可以使用 HTTP。")
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/chat/completions") { path.removeLast("/chat/completions".count) }
        components.path = path
        guard let normalized = components.url else { throw PaperDeskError.message("API 地址无效。") }
        return normalized
    }
    public func endpoint() throws -> URL {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PaperDeskError.message("请先填写模型名称。")
        }
        return try rootURL().appending(path: "chat/completions")
    }
    public var credentialAccount: String? {
        guard let url = try? rootURL() else { return nil }
        return "endpoint:" + url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public enum PaperDeskError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
