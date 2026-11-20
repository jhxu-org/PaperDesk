import Foundation
import CSQLite

/// Main-actor confinement keeps the one SQLite connection serialized.
@MainActor
public final class LibraryDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            let description = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle); handle = nil
            throw PaperDeskError.message(description)
        }
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, data BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS notes (id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE, data BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE, data BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY, data BLOB NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS notes_document ON notes(document_id)")
            try execute("CREATE INDEX IF NOT EXISTS messages_document ON messages(document_id)")
            try execute("PRAGMA user_version = 2")
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }

    /// SQLite's backup API includes committed WAL changes in a standalone, consistent database.
    public func backup(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw PaperDeskError.message("备份目标已存在。") }
        var target: OpaquePointer?
        guard sqlite3_open(url.path, &target) == SQLITE_OK else {
            sqlite3_close(target); throw PaperDeskError.message("无法创建书库副本。")
        }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", handle, "main") else {
            throw PaperDeskError.message("无法读取书库快照。")
        }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw PaperDeskError.message("书库快照未完成，请稍后重试。") }
        // The snapshot must be movable as one file, without depending on WAL sidecars.
        guard sqlite3_exec(target, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw PaperDeskError.message("无法完成独立的书库快照。")
        }
    }

    public static func validateBackup(at url: URL) throws {
        var handle: OpaquePointer?
        // No CREATE flag: a missing library must never become a new empty database.
        // Existing WAL databases may need writable sidecars even for an integrity read.
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(handle); throw PaperDeskError.message("无法读取此文件夹中的书库。")
        }
        defer { sqlite3_close(handle) }
        for sql in ["PRAGMA quick_check", "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('documents','notes','messages','folders')"] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0) else {
                throw PaperDeskError.message("无法校验书库：\(String(cString: sqlite3_errmsg(handle)))")
            }
            guard String(cString: text) == (sql.hasPrefix("PRAGMA") ? "ok" : "4") else {
                throw PaperDeskError.message("书库校验失败：\(String(cString: text))")
            }
        }
    }

    public func documents() throws -> [LibraryDocument] {
        try query("SELECT data FROM documents").map { try JSONDecoder().decode(LibraryDocument.self, from: $0) }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }
    public func notes(documentID: String) throws -> [ReadingNote] {
        try query("SELECT data FROM notes WHERE document_id = ?", strings: [documentID])
            .map { try JSONDecoder().decode(ReadingNote.self, from: $0) }.sorted { $0.createdAt < $1.createdAt }
    }
    public func messages(documentID: String) throws -> [ChatMessage] {
        try query("SELECT data FROM messages WHERE document_id = ?", strings: [documentID])
            .map { try JSONDecoder().decode(ChatMessage.self, from: $0) }.sorted { $0.createdAt < $1.createdAt }
    }
    public func save(_ document: LibraryDocument) throws {
        try execute("INSERT INTO documents (id, fingerprint, data) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET fingerprint=excluded.fingerprint, data=excluded.data",
                    strings: [document.id, document.fingerprint], data: JSONEncoder().encode(document))
    }
    public func save(_ note: ReadingNote) throws {
        try execute("INSERT INTO notes (id, document_id, data) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
                    strings: [note.id, note.documentID], data: JSONEncoder().encode(note))
    }
    public func save(_ message: ChatMessage) throws {
        try execute("INSERT INTO messages (id, document_id, data) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
                    strings: [message.id, message.documentID], data: JSONEncoder().encode(message))
    }
    public func deleteNote(id: String) throws { try execute("DELETE FROM notes WHERE id = ?", strings: [id]) }

    public func folders() throws -> [LibraryFolder] {
        try query("SELECT data FROM folders").map { try JSONDecoder().decode(LibraryFolder.self, from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }
    public func save(_ folder: LibraryFolder) throws {
        var folder = folder
        folder.name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = try folders().filter { $0.id != folder.id } + [folder]
        try FolderHierarchy(updated).validate()
        try execute("INSERT INTO folders (id, data) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", strings: [folder.id], data: JSONEncoder().encode(folder))
    }
    public func moveDocument(id: String, to folderID: String?) throws {
        if let folderID, try !folders().contains(where: { $0.id == folderID }) { throw PaperDeskError.message("目标文件夹已不存在。") }
        guard var document = try documents().first(where: { $0.id == id }) else { throw PaperDeskError.message("找不到这篇论文。") }
        document.folderID = folderID; try save(document)
    }
    /// Removing an organizational folder never removes papers, annotations or conversations.
    public func deleteFolder(id: String) throws {
        try transaction {
            let removed = FolderHierarchy(try folders()).descendantIDs(of: id)
            for var document in try documents() where document.folderID.map(removed.contains) == true {
                document.folderID = nil; try save(document)
            }
            for folderID in removed { try execute("DELETE FROM folders WHERE id = ?", strings: [folderID]) }
        }
    }
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String, strings: [String], data: Data? = nil) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        for (index, value) in strings.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(statement); throw failure()
            }
        }
        if let data {
            let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(strings.count + 1), $0.baseAddress, Int32(data.count), transient) }
            guard result == SQLITE_OK else { sqlite3_finalize(statement); throw failure() }
        }
        return statement
    }
    private func execute(_ sql: String, strings: [String] = [], data: Data? = nil) throws {
        let statement = try prepare(sql, strings: strings, data: data)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
    }
    private func query(_ sql: String, strings: [String] = []) throws -> [Data] {
        let statement = try prepare(sql, strings: strings)
        defer { sqlite3_finalize(statement) }
        var rows: [Data] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            if let bytes = sqlite3_column_blob(statement, 0) {
                rows.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            }
        }
    }
    private func failure() -> PaperDeskError {
        .message("本地数据库：" + String(cString: sqlite3_errmsg(handle)))
    }
}
