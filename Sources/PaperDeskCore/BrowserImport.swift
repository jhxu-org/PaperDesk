import Foundation
import PDFKit

public struct BrowserImportMetadata: Codable, Sendable {
    public let id: String
    public let title: String
    public let sourceURL: String
    public let byteCount: Int
}

public struct BrowserImportReceipt: Codable, Sendable {
    public let ok: Bool
    public let message: String
    public init(ok: Bool, message: String) { self.ok = ok; self.message = message }
}

/// Only an opaque UUID crosses the URL handler. Paths and network requests never do.
public struct BrowserImportInbox: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.appending(path: "BrowserInbox", directoryHint: .isDirectory) }
    public static func libraryRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appending(path: "PaperDesk", directoryHint: .isDirectory)
    }
    public func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id)?.uuidString == id else { throw PaperDeskError.message("无效的浏览器导入编号。") }
        return root.appending(path: id, directoryHint: .isDirectory)
    }
    public func metadata(_ id: String) throws -> BrowserImportMetadata {
        let folder = try directory(id)
        let result = try JSONDecoder().decode(BrowserImportMetadata.self, from: Data(contentsOf: folder.appending(path: "ready.json")))
        guard result.id == id else { throw PaperDeskError.message("浏览器导入信息不一致。") }
        return result
    }
    public func pendingIDs() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && FileManager.default.fileExists(atPath: $0.appending(path: "ready.json").path) }
            .map(\.lastPathComponent).sorted()
    }
    public func receiptURL(_ id: String) throws -> URL { _ = try directory(id); return root.appending(path: id + ".receipt.json") }
    public func finish(_ id: String, receipt: BrowserImportReceipt) throws {
        try JSONEncoder().encode(receipt).write(to: receiptURL(id), options: .atomic)
        try FileManager.default.removeItem(at: directory(id))
    }
    public static func importID(from url: URL) throws -> String {
        guard url.scheme == "paperdesk", url.host == "browser-import", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil,
              url.pathComponents.count == 2, let id = url.pathComponents.last,
              UUID(uuidString: id)?.uuidString == id else { throw PaperDeskError.message("无法识别此 PaperDesk 导入链接。") }
        return id
    }
    public static func sourceURL(_ text: String) throws -> String {
        guard var parts = URLComponents(string: text), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil else {
            throw PaperDeskError.message("仅支持 HTTP 或 HTTPS 的 PDF 来源。")
        }
        // Do not retain signed-download tokens, query credentials or fragments in the library.
        parts.query = nil; parts.fragment = nil
        return parts.url!.absoluteString
    }
}

/// A single native port owns a single bounded, ordered transfer. Unfinished transfers are removed on disconnect.
public final class BrowserPDFTransfer {
    public static let maximumBytes = 100 * 1024 * 1024
    public static let chunkBytes = 192 * 1024
    public let inbox: BrowserImportInbox
    public private(set) var id: String?
    private var folder: URL?
    private var handle: FileHandle?
    private var received = 0
    private var nextSequence = 0
    private var title = ""
    private var sourceURL = ""
    public init(inbox: BrowserImportInbox) { self.inbox = inbox }
    deinit { cancel() }

    public func begin(title: String, sourceURL: String) throws -> String {
        guard id == nil else { throw PaperDeskError.message("上一份 PDF 尚未传输完成。") }
        self.sourceURL = try BrowserImportInbox.sourceURL(sourceURL)
        let cleaned = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let candidate = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = String((candidate.isEmpty ? "网页 PDF" : candidate).prefix(160))
        let id = UUID().uuidString
        let folder = try inbox.directory(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.id = id; self.folder = folder
        let file = folder.appending(path: "document.pdf")
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            cancel(); throw PaperDeskError.message("无法创建临时 PDF。")
        }
        handle = try FileHandle(forWritingTo: file)
        return id
    }
    public func append(sequence: Int, base64: String) throws {
        guard let handle, sequence == nextSequence, base64.utf8.count <= Self.chunkBytes * 4 / 3,
              let data = Data(base64Encoded: base64), !data.isEmpty, data.count <= Self.chunkBytes,
              received + data.count <= Self.maximumBytes else {
            throw PaperDeskError.message("PDF 分块无效、顺序错误，或文件超过 100 MB。")
        }
        try handle.write(contentsOf: data)
        received += data.count; nextSequence += 1
    }
    public func prepare(byteCount: Int) throws -> String {
        guard let id, let folder, received > 0, byteCount == received else {
            throw PaperDeskError.message("PDF 传输不完整，请重新导入。")
        }
        try handle?.close(); handle = nil
        let file = folder.appending(path: "document.pdf")
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil,
              let pdf = PDFDocument(url: file), !pdf.isLocked, pdf.pageCount > 0 else {
            throw PaperDeskError.message("返回内容不是可阅读的 PDF；请检查是否需要登录，或先下载并解锁文件。")
        }
        let metadata = BrowserImportMetadata(id: id, title: title, sourceURL: sourceURL, byteCount: received)
        try JSONEncoder().encode(metadata).write(to: folder.appending(path: "ready.json"), options: .atomic)
        // Prepared jobs survive a failed launch and are consumed on the app's next activation.
        self.folder = nil; self.id = nil; received = 0; nextSequence = 0
        return id
    }
    public func cancel() {
        try? handle?.close(); handle = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil; id = nil; received = 0; nextSequence = 0
    }
}

public enum NativeMessageFraming {
    public static let maximumMessageBytes = 512 * 1024
    public static func read(from input: FileHandle) throws -> Data? {
        func exact(_ length: Int, allowEOF: Bool = false) throws -> Data? {
            var bytes = Data()
            while bytes.count < length {
                let part = try input.read(upToCount: length - bytes.count) ?? Data()
                if part.isEmpty {
                    if bytes.isEmpty && allowEOF { return nil }
                    throw PaperDeskError.message("浏览器传输意外中断。")
                }
                bytes.append(part)
            }
            return bytes
        }
        guard let header = try exact(4, allowEOF: true) else { return nil }
        let count = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard count > 0, count <= maximumMessageBytes else { throw PaperDeskError.message("浏览器消息大小无效。") }
        return try exact(Int(count))
    }
    public static func write(_ data: Data, to output: FileHandle) throws {
        guard data.count <= maximumMessageBytes else { throw PaperDeskError.message("回复过长。") }
        var count = UInt32(data.count)
        try withUnsafeBytes(of: &count) { try output.write(contentsOf: Data($0)) }
        try output.write(contentsOf: data)
    }
}
