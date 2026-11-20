import Foundation
import PaperDeskCore

extension PaperDeskCoreTests {
    @MainActor func testStorageMigrationPreservesWholeLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try DocumentRepository(root: root.appending(path: "Original"))
        let pdf = root.appending(path: "paper.pdf")
        try makePDF(at: pdf, pages: ["Persistent notes and conversations.", "The second page."])
        let parent = LibraryFolder(name: "一级目录")
        let child = LibraryFolder(name: "二级目录", parentID: parent.id)
        try original.database.save(parent); try original.database.save(child)
        var paper = try original.importPDF(from: pdf)
        paper.folderID = child.id; paper.currentPage = 1
        try original.database.save(paper)
        let note = ReadingNote(documentID: paper.id, page: 1, quote: "second", body: "中文笔记")
        let message = ChatMessage(documentID: paper.id, role: "assistant", content: "A saved conversation.", sources: [])
        try original.database.save(note); try original.database.save(message)
        // Source remains open with committed WAL writes while the migration snapshot is created.
        let transfer = try LibraryTransfer(repository: original, destination: root.appending(path: "新位置"))
        defer { transfer.discardStaging() }
        try await transfer.copyFiles { _, _ in }
        let migrated = try transfer.commit()
        try XCTAssertEqual(try migrated.database.documents(), [paper])
        try XCTAssertEqual(try migrated.database.folders(), try original.database.folders())
        try XCTAssertEqual(try migrated.database.notes(documentID: paper.id), [note])
        try XCTAssertEqual(try migrated.database.messages(documentID: paper.id), [message])
        try XCTAssertEqual(try Data(contentsOf: migrated.url(for: paper)), try Data(contentsOf: original.url(for: paper)))
        // Future writes target the new location; the original copy remains readable and unchanged.
        try migrated.database.deleteNote(id: note.id)
        try XCTAssertEqual(try original.database.notes(documentID: paper.id), [note])
        try FileManager.default.removeItem(at: original.url(for: paper))
        try XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.url(for: paper).path))
    }

    @MainActor func testStorageMigrationFailureAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try DocumentRepository(root: root.appending(path: "Original"))
        let pdf = root.appending(path: "paper.pdf")
        try makePDF(at: pdf, pages: ["Keep original data safe."])
        let paper = try original.importPDF(from: pdf)
        try XCTAssertThrowsError(LibraryTransfer(repository: original, destination: original.root))
        try XCTAssertThrowsError(LibraryTransfer(repository: original, destination: original.root.appending(path: "Nested")))
        try XCTAssertThrowsError(LibraryTransfer(repository: original, destination: root))
        let occupied = root.appending(path: "Occupied")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        try Data("existing user file".utf8).write(to: occupied.appending(path: "keep.txt"))
        try XCTAssertThrowsError(LibraryTransfer(repository: original, destination: occupied))
        try XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.appending(path: "keep.txt").path))

        let cancelled = try LibraryTransfer(repository: original, destination: root.appending(path: "Cancelled"))
        let task = Task { try await cancelled.copyFiles { _, _ in } }
        task.cancel()
        do { try await task.value; try XCTFail("Cancellation must stop the transfer") }
        catch is CancellationError { }
        cancelled.discardStaging()
        try XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.destination.path))
        try XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.staging.path))

        // A corrupted/missing source must never activate an incomplete new library.
        try Data("damaged".utf8).write(to: original.url(for: paper))
        let broken = try LibraryTransfer(repository: original, destination: root.appending(path: "Broken"))
        var failed = false
        do { try await broken.copyFiles { _, _ in } } catch { failed = true }
        try XCTAssertTrue(failed)
        broken.discardStaging()
        try XCTAssertFalse(FileManager.default.fileExists(atPath: broken.destination.path))
        try XCTAssertEqual(try original.database.documents().count, 1)
    }

    @MainActor func testStorageLocationPersistenceAndUnavailableDisk() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "paperdesk.storage.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let defaultRoot = root.appending(path: "Default")
        let location = LibraryLocation(defaultRoot: defaultRoot, defaults: defaults)
        try XCTAssertEqual(try location.resolve(), defaultRoot)
        let repository = try DocumentRepository(root: root.appending(path: "自选位置"))
        try location.use(repository.root)
        let reopened = LibraryLocation(defaultRoot: defaultRoot, defaults: defaults)
        try XCTAssertEqual(try reopened.resolve().resolvingSymlinksInPath().path, repository.root.resolvingSymlinksInPath().path)
        try XCTAssertTrue(reopened.isCustom)
        try FileManager.default.removeItem(at: repository.root)
        try XCTAssertThrowsError(reopened.resolve())
        try XCTAssertFalse(FileManager.default.fileExists(atPath: repository.root.path))
        try XCTAssertFalse(FileManager.default.fileExists(atPath: defaultRoot.path))
        try XCTAssertEqual(reopened.configuredPath, repository.root.path)
        let unrelated = root.appending(path: "Other")
        try FileManager.default.createDirectory(at: unrelated.appending(path: "Documents"), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: unrelated.appending(path: "library.sqlite"))
        try XCTAssertThrowsError(location.use(unrelated))
        try XCTAssertEqual(location.configuredPath, repository.root.path)
    }

    @MainActor func testBrowserInboxWithCustomStorage() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = try DocumentRepository(root: root.appending(path: "Custom"))
        let inbox = BrowserImportInbox(root: root.appending(path: "ApplicationSupport"))
        let pdf = root.appending(path: "browser.pdf")
        try makePDF(at: pdf, pages: ["Browser imports follow the chosen library."])
        let data = try Data(contentsOf: pdf)
        let transfer = BrowserPDFTransfer(inbox: inbox)
        let id = try transfer.begin(title: "Browser paper", sourceURL: "https://example.org/paper.pdf")
        try transfer.append(sequence: 0, base64: data.base64EncodedString())
        _ = try transfer.prepare(byteCount: data.count)
        let metadata = try inbox.metadata(id)
        let imported = try custom.importPDF(from: inbox.directory(id).appending(path: "document.pdf"), title: metadata.title, sourceURL: metadata.sourceURL)
        try inbox.finish(id, receipt: .init(ok: true, message: "Imported"))
        try XCTAssertTrue(custom.url(for: imported).path.hasPrefix(custom.root.path + "/"))
        try XCTAssertTrue(FileManager.default.fileExists(atPath: custom.url(for: imported).path))
        try XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "ApplicationSupport/library.sqlite").path))
        try XCTAssertTrue(inbox.pendingIDs().isEmpty)
    }
}
