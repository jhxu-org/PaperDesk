import Foundation
import PaperDeskCore

extension PaperDeskCoreTests {
    @MainActor
    func testBackgroundQueueProgressAndDestinations() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DocumentRepository(root: root)
        let folder = LibraryFolder(name: "研究"), child = LibraryFolder(name: "精读")
        try repository.database.save(folder)
        var nested = child; nested.parentID = folder.id; try repository.database.save(nested)
        let a = testArticle("2101.00001", "Queue first"), b = testArticle("2101.00002", "Queue second")
        let sourceA = root.appending(path: "a.pdf"), sourceB = root.appending(path: "b.pdf")
        try makePDF(at: sourceA, pages: ["First original queue fixture."])
        try makePDF(at: sourceB, pages: ["Second original queue fixture."])
        let transfer = ControlledPaperDownload(data: [a.id: try Data(contentsOf: sourceA), b.id: try Data(contentsOf: sourceB)])
        let queue = PaperImportQueue(downloader: transfer); queue.configure(repository: repository)
        var completions = [LibraryDocument](); queue.onImported = { completions.append($0) }
        let first = try queue.enqueue(a, folderID: nested.id)
        let duplicate = try queue.enqueue(testArticle(a.id + "v2", "same identity"), folderID: nil)
        try XCTAssertEqual(first, duplicate)
        let second = try queue.enqueue(b, folderID: folder.id)
        try XCTAssertEqual(queue.activeCount, 2)
        try XCTAssertEqual(queue.jobs.last?.state, .queued)
        try await waitForQueue { queue.jobs.first?.progress.receivedBytes ?? 0 > 0 }
        try XCTAssertTrue(queue.jobs.first?.progress.fraction != nil)
        try XCTAssertEqual(queue.jobs.first?.folderPath, "研究 / 精读")
        // The main actor continues to execute unrelated library reads while a download is suspended.
        try XCTAssertTrue(try repository.database.documents().isEmpty)
        queue.cancel(second)
        try XCTAssertEqual(queue.jobs.last?.state, .cancelled)
        try XCTAssertEqual(queue.activeCount, 1)
        await transfer.release(a.id)
        try await waitForQueue { queue.jobs.first?.state == .completed }
        try XCTAssertEqual(completions.count, 1)
        try XCTAssertEqual(completions.first?.folderID, nested.id)
        try XCTAssertEqual(completions.first?.arxiv, a)
        queue.retry(second)
        try await waitForQueue { queue.jobs.last?.progress.receivedBytes ?? 0 > 0 }
        await transfer.release(b.id)
        try await waitForQueue { queue.activeCount == 0 }
        try XCTAssertEqual(queue.jobs.map(\.state), [.completed, .completed])
        try XCTAssertEqual(completions.last?.folderID, folder.id)
        try XCTAssertEqual(try repository.database.documents().count, 2)
        let stats = await transfer.stats()
        try XCTAssertEqual(stats.maximum, 1)
        try XCTAssertEqual(stats.ids, [a.id, b.id])
        try XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Documents/.import-\(first).pdf").path))
        queue.clearFinished()
        try XCTAssertTrue(queue.jobs.isEmpty)
        try XCTAssertEqual(try repository.database.documents().count, 2)
    }

    @MainActor
    func testBackgroundQueueFailureCancelRetryAndDeletedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DocumentRepository(root: root)
        let folder = LibraryFolder(name: "Temporary target"); try repository.database.save(folder)
        let a = testArticle("2102.00001", "Retry fixture"), b = testArticle("2102.00002", "Cancel fixture"), c = testArticle("2102.00003", "Deleted destination")
        let source = root.appending(path: "source.pdf"); try makePDF(at: source, pages: ["Cancellation must leave no partial library file."])
        let data = try Data(contentsOf: source)
        let transfer = ControlledPaperDownload(data: [a.id: data, b.id: data, c.id: data], failures: [a.id], unknown: [b.id])
        let queue = PaperImportQueue(downloader: transfer); queue.configure(repository: repository)
        let first = try queue.enqueue(a, folderID: nil), second = try queue.enqueue(b, folderID: nil), third = try queue.enqueue(c, folderID: folder.id)
        try await waitForQueue { queue.jobs.first?.progress.receivedBytes ?? 0 > 0 }
        await transfer.release(a.id)
        try await waitForQueue { queue.jobs.first?.state == .failed && queue.jobs[1].progress.receivedBytes > 0 }
        try XCTAssertEqual(queue.failedCount, 1)
        try XCTAssertTrue(queue.jobs[1].progress.fraction == nil)
        queue.cancel(second)
        try repository.database.deleteFolder(id: folder.id)
        try await waitForQueue { queue.activeCount == 0 }
        try XCTAssertEqual(queue.jobs.map(\.state), [.failed, .cancelled, .failed])
        try XCTAssertTrue(queue.jobs.last?.error?.contains("文件夹已删除") == true)
        try XCTAssertTrue(try repository.database.documents().isEmpty)
        for id in [first, second, third] {
            let temp = FileManager.default.temporaryDirectory.appending(path: "PaperDesk-import-\(id).pdf")
            try XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        }
        let before = await transfer.stats()
        try XCTAssertEqual(before.ids, [a.id, b.id])
        await transfer.clearFailure(a.id)
        queue.retry(first)
        try await waitForQueue { queue.jobs.first?.state == .completed }
        try XCTAssertEqual(try repository.database.documents().count, 1)
        let oldCount = (await transfer.stats()).ids.count
        _ = try queue.enqueue(a, folderID: nil)
        try XCTAssertEqual(queue.jobs.last?.state, .completed)
        let after = await transfer.stats()
        try XCTAssertEqual(after.ids.count, oldCount)
        try XCTAssertEqual(try repository.database.documents().count, 1)
    }
}

private func testArticle(_ id: String, _ title: String) -> ArxivArticle {
    ArxivArticle(id: id, title: title, authors: [], summary: "", published: "", category: "")
}

@MainActor
private func waitForQueue(_ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CheckFailure(description: "Timed out waiting for import queue")
}

private actor ControlledPaperDownload: PaperDownloading {
    var data: [String: Data]
    var failures: Set<String>
    var unknown: Set<String>
    var released = Set<String>()
    var ids = [String](), active = 0, maximum = 0
    init(data: [String: Data], failures: Set<String> = [], unknown: Set<String> = []) {
        self.data = data; self.failures = failures; self.unknown = unknown
    }
    func release(_ id: String) { released.insert(id) }
    func clearFailure(_ id: String) { failures.remove(id) }
    func stats() -> (ids: [String], maximum: Int) { (ids, maximum) }
    func download(_ article: ArxivArticle, to destination: URL, progress: @escaping @Sendable (PaperDownloadProgress) async -> Void) async throws {
        ids.append(article.id); active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        let bytes = data[article.id]!
        let total = unknown.contains(article.id) ? nil : bytes.count
        try bytes.prefix(bytes.count / 2).write(to: destination)
        await progress(.init(receivedBytes: bytes.count / 2, totalBytes: total))
        while !released.contains(article.id) { try await Task.sleep(for: .milliseconds(10)) }
        try Task.checkCancellation()
        if failures.contains(article.id) { throw URLError(.networkConnectionLost) }
        try bytes.write(to: destination)
        await progress(.init(receivedBytes: bytes.count, totalBytes: total))
    }
}
