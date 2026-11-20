import Foundation
import CryptoKit

/// Preferences contain only the library location; credentials remain in Keychain or process memory.
@MainActor
public final class LibraryLocation {
    public let defaultRoot: URL
    private let defaults: UserDefaults
    private var accessedURL: URL?
    private let preference = "libraryStorageLocation"
    public init(defaultRoot: URL, defaults: UserDefaults) { self.defaultRoot = defaultRoot; self.defaults = defaults }
    public var configuredPath: String { defaults.dictionary(forKey: preference)?["path"] as? String ?? defaultRoot.path }
    public var isCustom: Bool { defaults.dictionary(forKey: preference) != nil }
    public func resolve() throws -> URL {
        guard let setting = defaults.dictionary(forKey: preference) else { return defaultRoot }
        var stale = false
        let url: URL
        if let bookmark = setting["bookmark"] as? Data {
            url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        } else { throw PaperDeskError.message("存储位置记录无效，请重新选择书库文件夹。") }
        let accessing = url.startAccessingSecurityScopedResource()
        do { try Self.validate(url) }
        catch { if accessing { url.stopAccessingSecurityScopedResource() }; throw error }
        if let old = accessedURL { old.stopAccessingSecurityScopedResource() }
        accessedURL = accessing ? url : nil
        if stale { try use(url) }
        return url
    }
    public func use(_ url: URL) throws {
        try Self.validate(url)
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let accessing = url.startAccessingSecurityScopedResource()
        if let old = accessedURL { old.stopAccessingSecurityScopedResource() }
        accessedURL = accessing ? url : nil
        defaults.set(["path": url.path, "bookmark": bookmark], forKey: preference)
    }
    public static func validate(_ root: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.appending(path: "Documents").path, isDirectory: &directory), directory.boolValue else {
            throw PaperDeskError.message("书库文件夹不可用。请连接原来的磁盘，或选择已有的 PaperDesk 书库；不会自动创建空书库。")
        }
        try LibraryDatabase.validateBackup(at: root.appending(path: "library.sqlite"))
    }
}

/// A new sibling staging directory makes failed/cancelled copies disposable without touching either library.
public struct LibraryTransfer: Sendable {
    public let staging: URL
    public let destination: URL
    private let source: URL
    private let documents: [LibraryDocument]

    @MainActor public init(repository: DocumentRepository, destination: URL) throws {
        let source = repository.root.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !target.path.hasPrefix(source.path + "/"), target != source,
              !source.path.hasPrefix(target.path + "/") else {
            throw PaperDeskError.message("请选择当前书库之外的文件夹。")
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw PaperDeskError.message("目标位置已有“\(destination.lastPathComponent)”。请选择其他位置，或使用“打开已有书库”。")
        }
        self.source = source
        self.destination = destination
        documents = try repository.database.documents()
        staging = destination.deletingLastPathComponent().appending(path: ".paperdesk-transfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do { try repository.database.backup(to: staging.appending(path: "library.sqlite")) }
        catch { try? FileManager.default.removeItem(at: staging); throw error }
    }

    public func copyFiles(progress: @Sendable (Int, Int) async -> Void) async throws {
        let directory = staging.appending(path: "Documents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for (index, document) in documents.enumerated() {
            try Task.checkCancellation()
            guard document.filename == URL(fileURLWithPath: document.filename).lastPathComponent,
                  document.filename.lowercased().hasSuffix(".pdf") else { throw PaperDeskError.message("书库中的文献路径无效。") }
            let original = source.appending(path: "Documents").appending(path: document.filename)
            let copy = directory.appending(path: document.filename)
            let attributes = try original.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                throw PaperDeskError.message("“\(document.title)”不是独立的 PDF 文件，无法迁移。")
            }
            try FileManager.default.copyItem(at: original, to: copy)
            let file = try FileHandle(forReadingFrom: copy)
            defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation(); hash.update(data: data)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == document.fingerprint else {
                throw PaperDeskError.message("“\(document.title)”的文件校验未通过，原书库保持不变。")
            }
            await progress(index + 1, documents.count)
        }
        try Task.checkCancellation()
    }

    @MainActor public func commit() throws -> DocumentRepository {
        try LibraryLocation.validate(staging)
        // moveItem refuses to overwrite a destination created since the initial check.
        try FileManager.default.moveItem(at: staging, to: destination)
        return try DocumentRepository(root: destination)
    }
    public func discardStaging() { try? FileManager.default.removeItem(at: staging) }
}
