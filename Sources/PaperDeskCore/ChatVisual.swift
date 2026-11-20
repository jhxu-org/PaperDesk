import Foundation
import AppKit
import PDFKit

/// Only provenance is persisted in chat history. Images are regenerated from the library PDF.
public struct ChatVisual: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var page: Int
    public var caption: String
    public var source: SourceChunk?
    public init(page: Int, caption: String, source: SourceChunk? = nil) {
        self.id = "p\(page + 1)"; self.page = page; self.caption = caption; self.source = source
    }
    public var marker: String { "[visual:\(id)]" }
}

public struct ChatPageImage: Sendable {
    public let visual: ChatVisual
    public let jpeg: Data
    public init(visual: ChatVisual, jpeg: Data) { self.visual = visual; self.jpeg = jpeg }
    public var dataURL: String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }
}

public enum ChatVisualBuilder {
    /// Whole-page previews preserve the figure's context; no inferred bounding boxes are presented as figures.
    public static func candidates(chunks: [SourceChunk], sources: [SourceChunk], scope: ChatScope,
                                  page: Int, question: String, pageCount: Int) -> [ChatVisual] {
        let allowedPages = scope == .currentPage ? Set([page]) : scope == .selection ? Set(sources.map(\.page)) : nil
        let eligible = chunks.filter { allowedPages?.contains($0.page) ?? true }
        let evidenceIDs = Set(sources.map(\.id))
        let pattern = #"(?im)^\s*(?:(?:fig(?:ure)?\.?|table)\s*\d+[a-z]?|[图表]\s*\d+)\s*[:.：、]?[^\n]*"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let requested = try! NSRegularExpression(pattern: #"(?i)(?:fig(?:ure)?\.?|table|图|表)\s*(\d+[a-z]?)"#)
        func labels(_ text: String) -> Set<String> {
            Set(requested.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                // Keep figure/table distinct; normalize Chinese/English spelling.
                let value = (text as NSString).substring(with: $0.range).lowercased()
                let kind = value.hasPrefix("table") || value.hasPrefix("表") ? "table" : "figure"
                return kind + (text as NSString).substring(with: $0.range(at: 1)).lowercased()
            })
        }
        let targets = labels(question)
        let words = question.lowercased().components(separatedBy: .alphanumerics.inverted).filter { $0.count > 2 }
        var ranked: [(ChatVisual, Int)] = []
        for chunk in eligible {
            for match in regex.matches(in: chunk.text, range: NSRange(chunk.text.startIndex..., in: chunk.text)) {
                let caption = (chunk.text as NSString).substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
                var source = chunk
                source.text = caption; source.characterOffset += match.range.location
                // The match may include leading whitespace; retain the exact range for PDF selection.
                source.text = (chunk.text as NSString).substring(with: match.range)
                var score = evidenceIDs.contains(chunk.id) ? 20 : 0
                if !targets.isDisjoint(with: labels(caption)) { score += 100 }
                score += words.filter { caption.lowercased().contains($0) }.count * 5
                if chunk.page == page { score += 1 }
                ranked.append((ChatVisual(page: chunk.page, caption: String(caption.prefix(240)), source: source), score))
            }
        }
        ranked.sort { $0.1 == $1.1 ? $0.0.page < $1.0.page : $0.1 > $1.1 }
        var result: [ChatVisual] = []
        var seen = Set<Int>()
        for (visual, _) in ranked where seen.insert(visual.page).inserted {
            result.append(visual)
            if result.count == 3 { break }
        }
        // A local question can still inspect an uncaptioned diagram or scanned page.
        if result.isEmpty {
            let pages = scope == .document ? Array(Set(sources.map(\.page))).sorted() :
                scope == .selection ? Array(Set(sources.map(\.page))).sorted() : [page]
            for candidate in pages.prefix(2) where candidate >= 0 && candidate < pageCount {
                result.append(ChatVisual(page: candidate, caption: "原文页面", source: sources.first { $0.page == candidate }))
            }
        }
        return result
    }

    public static func cited(in answer: String, candidates: [ChatVisual]) -> [ChatVisual] {
        candidates.filter { answer.contains($0.marker) }
    }

    /// Runs off the UI thread with an independently owned PDFDocument.
    public static func render(url: URL, visuals: [ChatVisual], maxDimension: Int = 1600) throws -> [ChatPageImage] {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw PaperDeskError.message("无法读取原文配图。") }
        return try visuals.prefix(3).map { visual in
            try Task.checkCancellation()
            guard let page = pdf.page(at: visual.page) else { throw PaperDeskError.message("原文配图页码无效。") }
            return try autoreleasepool {
                let size = CGFloat(min(max(maxDimension, 256), 2400))
                let image = page.thumbnail(of: NSSize(width: size, height: size), for: .cropBox)
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]),
                      data.count <= 3_000_000 else { throw PaperDeskError.message("无法生成原文配图，请在 PDF 中查看。") }
                return ChatPageImage(visual: visual, jpeg: data)
            }
        }
    }
}
