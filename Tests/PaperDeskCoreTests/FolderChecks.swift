import Foundation
import PaperDeskCore

extension PaperDeskCoreTests {
    @MainActor
    func testNestedFoldersAndSafeRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try DocumentRepository(root: root)
        let a = LibraryFolder(name: "研究 A"), b = LibraryFolder(name: "研究 B")
        var child = LibraryFolder(name: "阅读", parentID: a.id)
        let otherChild = LibraryFolder(name: "阅读", parentID: b.id)
        let leaf = LibraryFolder(name: "方法", parentID: child.id)
        for folder in [a, b, child, otherChild, leaf] { try repo.database.save(folder) }
        try XCTAssertThrowsError(try repo.database.save(LibraryFolder(name: "阅读", parentID: a.id)))
        let original = try repo.database.folders()
        var invalid = a; invalid.parentID = leaf.id
        try XCTAssertThrowsError(try repo.database.save(invalid))
        invalid = child; invalid.parentID = child.id
        try XCTAssertThrowsError(try repo.database.save(invalid))
        invalid.parentID = UUID().uuidString
        try XCTAssertThrowsError(try repo.database.save(invalid))
        invalid = child; invalid.parentID = b.id
        try XCTAssertThrowsError(try repo.database.save(invalid))
        try XCTAssertEqual(try repo.database.folders(), original)

        child.name = "精读"; child.parentID = b.id; try repo.database.save(child)
        let reopened = try DocumentRepository(root: root)
        let hierarchy = FolderHierarchy(try reopened.database.folders())
        try XCTAssertEqual(hierarchy.path(for: leaf.id), "研究 B / 精读 / 方法")
        try XCTAssertEqual(hierarchy.descendantIDs(of: b.id), Set([b.id, child.id, otherChild.id, leaf.id]))
        try XCTAssertEqual(hierarchy.entries.first(where: { $0.id == leaf.id })?.depth, 2)
        try XCTAssertEqual(hierarchy.ancestorIDs(of: leaf.id), [child.id, b.id])
        // Old folder JSON without parentID remains a top-level folder.
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(child)) as? [String: Any])
        legacyJSON.removeValue(forKey: "parentID")
        let legacy = try JSONDecoder().decode(LibraryFolder.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        try XCTAssertEqual(legacy.parentID, nil)

        let pdf = root.appending(path: "inside.pdf"), outside = root.appending(path: "outside.pdf")
        try makePDF(at: pdf, pages: ["Nested paper"]); try makePDF(at: outside, pages: ["Other project"])
        let doc = try repo.importPDF(from: pdf), other = try repo.importPDF(from: outside)
        try repo.database.moveDocument(id: doc.id, to: leaf.id)
        try repo.database.moveDocument(id: other.id, to: a.id)
        let note = ReadingNote(documentID: doc.id, page: 0, quote: "Nested paper", body: "Preserve nested notes")
        let message = ChatMessage(documentID: doc.id, role: "user", content: "Preserve nested conversation")
        try repo.database.save(note); try repo.database.save(message)
        let bytes = try Data(contentsOf: repo.url(for: doc))
        try repo.database.deleteFolder(id: b.id)
        try XCTAssertEqual(try repo.database.folders(), [a])
        try XCTAssertEqual(try repo.database.documents().first(where: { $0.id == doc.id })?.folderID, nil)
        try XCTAssertEqual(try repo.database.documents().first(where: { $0.id == other.id })?.folderID, a.id)
        try XCTAssertEqual(try repo.database.notes(documentID: doc.id), [note])
        try XCTAssertEqual(try repo.database.messages(documentID: doc.id), [message])
        try XCTAssertEqual(try Data(contentsOf: repo.url(for: doc)), bytes)
    }

    @MainActor
    func testNestedCloudRestoreAndValidation() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try DocumentRepository(root: root.appending(path: "source"))
        let a = LibraryFolder(name: "Alpha"), b = LibraryFolder(name: "Beta")
        let ac = LibraryFolder(name: "Shared", parentID: a.id), bc = LibraryFolder(name: "Shared", parentID: b.id)
        let leaf = LibraryFolder(name: "Methods", parentID: ac.id)
        for folder in [a, ac, leaf, b, bc] { try source.database.save(folder) }
        let one = root.appending(path: "one.pdf"), two = root.appending(path: "two.pdf")
        try makePDF(at: one, pages: ["Alpha methods"]); try makePDF(at: two, pages: ["Beta methods"])
        let da = try source.importPDF(from: one), db = try source.importPDF(from: two)
        try source.database.moveDocument(id: da.id, to: leaf.id); try source.database.moveDocument(id: db.id, to: bc.id)
        var snapshot = try CloudArchive.capture(repository: source)
        try XCTAssertEqual(snapshot.schemaVersion, 2)
        snapshot.folders.reverse() // Restore must not depend on manifest order.
        snapshot = try CloudArchive.decode(snapshot.encoded())
        try XCTAssertTrue(String(decoding: snapshot.markdownNotes(), as: UTF8.self).contains("Alpha / Shared / Methods"))
        let files = [da.fingerprint: source.url(for: da), db.fingerprint: source.url(for: db)]
        let target = try DocumentRepository(root: root.appending(path: "target"))
        let localA = LibraryFolder(name: "Alpha"), localB = LibraryFolder(name: "Beta")
        let localAC = LibraryFolder(name: "Shared", parentID: localA.id), localBC = LibraryFolder(name: "Shared", parentID: localB.id)
        let topLevelShared = LibraryFolder(name: "Shared")
        for folder in [localA, localAC, localB, localBC, topLevelShared] { try target.database.save(folder) }
        try XCTAssertEqual(try CloudArchive.restore(snapshot, files: files, into: target), 2)
        let restoredFolders = try target.database.folders()
        try XCTAssertEqual(restoredFolders.count, 6)
        try XCTAssertEqual(restoredFolders.first(where: { $0.id == leaf.id })?.parentID, localAC.id)
        let restoredDocs = try target.database.documents()
        try XCTAssertEqual(restoredDocs.first(where: { $0.fingerprint == da.fingerprint })?.folderID, leaf.id)
        try XCTAssertEqual(restoredDocs.first(where: { $0.fingerprint == db.fingerprint })?.folderID, localBC.id)
        try XCTAssertEqual(try CloudArchive.restore(snapshot, files: files, into: target), 0)
        try XCTAssertEqual(try target.database.folders(), restoredFolders)

        var localLeaf = try XCTUnwrap(restoredFolders.first(where: { $0.id == leaf.id }))
        localLeaf.name = "Local rename"; localLeaf.parentID = nil; try target.database.save(localLeaf)
        try XCTAssertEqual(try CloudArchive.restore(snapshot, files: files, into: target), 0)
        try XCTAssertEqual(try target.database.folders().first(where: { $0.id == leaf.id }), localLeaf)
        let beforeInvalid = try target.database.folders()
        for parent in [UUID().uuidString, ac.id, leaf.id] {
            var invalid = snapshot
            let index = try XCTUnwrap(invalid.folders.firstIndex(where: { $0.id == ac.id }))
            invalid.folders[index].parentID = parent
            try XCTAssertThrowsError(try CloudArchive.restore(invalid, files: files, into: target))
        }
        var duplicate = snapshot; duplicate.folders.append(LibraryFolder(name: "SHARED", parentID: a.id))
        try XCTAssertThrowsError(try CloudArchive.decode(duplicate.encoded()))
        try XCTAssertEqual(try target.database.folders(), beforeInvalid)
        try XCTAssertEqual(try target.database.documents(), restoredDocs)
        var legacy = CloudSnapshot(folders: [LibraryFolder(name: "Legacy")], papers: [])
        legacy.schemaVersion = 1
        let decodedLegacy = try CloudArchive.decode(legacy.encoded())
        try XCTAssertEqual(decodedLegacy.folders[0].parentID, nil)
        let legacyTarget = try DocumentRepository(root: root.appending(path: "legacy"))
        try XCTAssertEqual(try CloudArchive.restore(decodedLegacy, files: [:], into: legacyTarget), 0)
        try XCTAssertEqual(try legacyTarget.database.folders().count, 1)
        var badLegacy = snapshot; badLegacy.schemaVersion = 1
        try XCTAssertThrowsError(try CloudArchive.decode(badLegacy.encoded()))
    }
}
