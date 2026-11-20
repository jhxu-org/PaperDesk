import Foundation
import CryptoKit
import PaperDeskCore

extension PaperDeskCoreTests {
    @MainActor
    func testFoldersAndLegacyLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try DocumentRepository(root: root)
        let pdf = root.appending(path: "sample.pdf"); try makePDF(at: pdf, pages: ["Folder persistence"])
        let doc = try repo.importPDF(from: pdf)
        let note = ReadingNote(documentID: doc.id, page: 0, quote: "Folder persistence", body: "Keep me")
        try repo.database.save(note)
        var folder = LibraryFolder(name: "  Research  "); try repo.database.save(folder)
        try XCTAssertEqual(try repo.database.folders().first?.name, "Research")
        try XCTAssertThrowsError(try repo.database.save(LibraryFolder(name: "research")))
        try XCTAssertThrowsError(try repo.database.save(LibraryFolder(name: " \n ")))
        try repo.database.moveDocument(id: doc.id, to: folder.id)
        folder.name = "新课题"; try repo.database.save(folder)
        let reopened = try DocumentRepository(root: root)
        try XCTAssertEqual(try reopened.database.documents().first?.folderID, folder.id)
        try XCTAssertEqual(try reopened.database.folders().first?.name, "新课题")
        try reopened.database.deleteFolder(id: folder.id)
        try XCTAssertEqual(try reopened.database.documents().first?.folderID, nil)
        try XCTAssertEqual(try reopened.database.notes(documentID: doc.id), [note])
        try XCTAssertTrue(FileManager.default.fileExists(atPath: repo.url(for: doc).path))
        try XCTAssertThrowsError(try repo.database.moveDocument(id: doc.id, to: "missing"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as? [String: Any])
        json.removeValue(forKey: "folderID")
        let legacy = try JSONDecoder().decode(LibraryDocument.self, from: JSONSerialization.data(withJSONObject: json))
        try XCTAssertEqual(legacy.folderID, nil)
    }

    @MainActor
    func testCloudMergeAndRepair() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try DocumentRepository(root: root.appending(path: "source"))
        let input = root.appending(path: "paper.pdf"); try makePDF(at: input, pages: ["Cloud original", "Page two"])
        var doc = try source.importPDF(from: input)
        let folder = LibraryFolder(name: "研究"); try source.database.save(folder)
        doc.folderID = folder.id; doc.currentPage = 1; try source.database.save(doc)
        let note = ReadingNote(documentID: doc.id, page: 1, quote: "Page two", body: "Cloud note")
        try source.database.save(note)
        try source.database.save(ChatMessage(documentID: doc.id, role: "user", content: "PRIVATE CHAT NEVER UPLOADED"))
        let snapshot = try CloudArchive.capture(repository: source)
        let encoded = try snapshot.encoded()
        try XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE CHAT"))
        try XCTAssertTrue(String(decoding: snapshot.markdownNotes(), as: UTF8.self).contains("Cloud note"))
        let decoded = try CloudArchive.decode(encoded)
        let files = [doc.fingerprint: source.url(for: doc)]
        let destination = try DocumentRepository(root: root.appending(path: "destination"))
        try XCTAssertEqual(try CloudArchive.restore(decoded, files: files, into: destination), 1)
        var restored = try XCTUnwrap(destination.database.documents().first)
        try XCTAssertEqual(restored.currentPage, 1)
        try XCTAssertEqual(try destination.database.folders().first?.name, "研究")
        var localNote = try XCTUnwrap(destination.database.notes(documentID: restored.id).first)
        localNote.body = "Local changes survive"; try destination.database.save(localNote)
        restored.currentPage = 0; restored.folderID = nil; try destination.database.save(restored)
        try XCTAssertEqual(try CloudArchive.restore(decoded, files: files, into: destination), 0)
        try XCTAssertEqual(try CloudArchive.restore(decoded, files: files, into: destination), 0)
        try XCTAssertEqual(try destination.database.notes(documentID: restored.id).count, 2)
        try XCTAssertEqual(try destination.database.documents().first?.currentPage, 0)
        try XCTAssertEqual(try destination.database.documents().first?.folderID, nil)
        try XCTAssertTrue(try destination.database.messages(documentID: restored.id).isEmpty)
        try Data("damaged".utf8).write(to: destination.url(for: restored))
        try XCTAssertEqual(try CloudArchive.restore(decoded, files: files, into: destination), 0)
        let repaired = try XCTUnwrap(destination.database.documents().first)
        try CloudArchive.validatePDF(destination.url(for: repaired), paper: decoded.papers[0])
        try XCTAssertNotEqual(repaired.filename, restored.filename)
        try XCTAssertEqual(try destination.database.notes(documentID: restored.id).count, 2)
    }

    @MainActor
    func testCloudInvalidArchiveIsAtomic() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try DocumentRepository(root: root)
        let input = root.appending(path: "paper.pdf"); try makePDF(at: input, pages: ["Verified original"])
        let doc = try repo.importPDF(from: input)
        let snapshot = try CloudArchive.capture(repository: repo)
        let destination = try DocumentRepository(root: root.appending(path: "target"))
        let corrupt = root.appending(path: "corrupt.pdf"); try Data("broken".utf8).write(to: corrupt)
        try XCTAssertThrowsError(try CloudArchive.restore(snapshot, files: [doc.fingerprint: corrupt], into: destination))
        try XCTAssertTrue(try destination.database.documents().isEmpty)
        var invalid = snapshot; invalid.papers[0].document.fingerprint = "../../outside"
        try XCTAssertThrowsError(try CloudArchive.decode(invalid.encoded()))
        invalid = snapshot; invalid.papers[0].document.sourceURL = "file:///private/unsafe"
        try XCTAssertThrowsError(try invalid.validate())
        invalid = snapshot; invalid.papers[0].document.folderID = "missing"
        try XCTAssertThrowsError(try invalid.validate())
        invalid = snapshot; invalid.createdAt = Date(timeIntervalSince1970: 1e100)
        try XCTAssertThrowsError(try invalid.validate())
        invalid = snapshot; invalid.schemaVersion = 99
        try XCTAssertThrowsError(try invalid.validate())
        // Malformed folder names must leave the entire library unchanged.
        invalid = snapshot; invalid.folders = [LibraryFolder(name: "Good"), LibraryFolder(name: "\n")]
        try XCTAssertThrowsError(try CloudArchive.restore(invalid, files: [doc.fingerprint: input], into: destination))
        try XCTAssertTrue(try destination.database.folders().isEmpty)
        try XCTAssertTrue(try destination.database.documents().isEmpty)
    }

    @MainActor
    func testCloudTransferCommitAndRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try DocumentRepository(root: root)
        let input = root.appending(path: "paper.pdf"); try makePDF(at: input, pages: ["Transfer original"])
        let doc = try repo.importPDF(from: input)
        let parent = LibraryFolder(name: "项目"), child = LibraryFolder(name: "精读")
        try repo.database.save(parent)
        var nested = child; nested.parentID = parent.id; try repo.database.save(nested)
        try repo.database.moveDocument(id: doc.id, to: nested.id)
        let snapshot = try CloudArchive.capture(repository: repo)
        let storage = MemoryCloud()
        let files = [doc.fingerprint: repo.url(for: doc)]
        try await CloudTransfer.save(snapshot, files: files, root: "/apps/测试/PaperDesk", storage: storage) { _, _ in }
        let uploads = await storage.uploads
        try XCTAssertTrue(uploads.last?.hasSuffix(".json") == true)
        try XCTAssertEqual(uploads.filter { $0.hasSuffix(".pdf") }.count, 1)
        var second = snapshot; second.id = UUID().uuidString
        try await CloudTransfer.save(second, files: files, root: "/apps/测试/PaperDesk", storage: storage) { _, _ in }
        let allUploads = await storage.uploads
        try XCTAssertEqual(allUploads.filter { $0.hasSuffix(".pdf") }.count, 1)
        let versions = try await CloudTransfer.snapshots(root: "/apps/测试/PaperDesk", storage: storage)
        try XCTAssertEqual(versions.count, 2)
        let (recovered, recoveredFiles) = try await CloudTransfer.fetch(versions[0], root: "/apps/测试/PaperDesk", into: root.appending(path: "download"), localFiles: [:], storage: storage) { _, _ in }
        let target = try DocumentRepository(root: root.appending(path: "restore"))
        try XCTAssertEqual(try CloudArchive.restore(recovered, files: recoveredFiles, into: target), 1)
        try XCTAssertEqual(FolderHierarchy(try target.database.folders()).path(for: nested.id), "项目 / 精读")
        try XCTAssertEqual(try target.database.documents().first?.folderID, nested.id)
        let failing = MemoryCloud(failPDF: true)
        do {
            try await CloudTransfer.save(snapshot, files: files, root: "/apps/测试", storage: failing) { _, _ in }
            try XCTFail("Expected interrupted upload")
        } catch is CheckFailure { throw CheckFailure(description: "Upload should have failed") } catch { }
        let partial = await failing.uploads
        try XCTAssertFalse(partial.contains { $0.hasSuffix(".json") })
        let canceled = MemoryCloud()
        let task = Task {
            try await CloudTransfer.save(snapshot, files: files, root: "/apps/测试", storage: canceled) { _, _ in }
        }
        task.cancel()
        do { try await task.value; try XCTFail("Expected cancellation") } catch is CancellationError { }
        let canceledUploads = await canceled.uploads
        try XCTAssertFalse(canceledUploads.contains { $0.hasSuffix(".json") })
    }

    func testBaiduPathsAndCredentialsEncoding() throws {
        try XCTAssertEqual(try BaiduPath.root(" /apps/我的应用/PaperDesk/ "), "/apps/我的应用/PaperDesk")
        for path in ["/outside", "/apps/a/../b", "/apps//b", "/apps/a\\b", "/apps/a\nb"] {
            try XCTAssertThrowsError(try BaiduPath.root(path))
        }
        for url in ["http://pan.baidu.com/x", "https://baidu.com.evil.test/x", "https://evil.test/x", "https://x:secret@pan.baidu.com/x", "https://pan.baidu.com:123/x"] {
            try XCTAssertFalse(BaiduPath.allowedURL(URL(string: url)!))
        }
        try XCTAssertTrue(BaiduPath.allowedURL(URL(string: "https://d.pcs.baidu.com/x")!))
        try XCTAssertTrue(BaiduPath.allowedURL(URL(string: "https://d.baidupcs.com/x")!))
        let form = BaiduNetdiskClient.form(["client_secret": "s+&=秘密", "path": "/apps/A B"])
        try XCTAssertTrue(String(decoding: form, as: UTF8.self).contains("s%2B%26%3D"))
        let query = URLComponents(string: "https://example.test/?" + String(decoding: form, as: UTF8.self))!
        try XCTAssertEqual(query.queryItems?.first { $0.name == "client_secret" }?.value, "s+&=秘密")
    }
}

private actor MemoryCloud: CloudStorage {
    var bytes: [String: Data] = [:]
    var uploads: [String] = []
    let failPDF: Bool
    init(failPDF: Bool = false) { self.failPDF = failPDF }
    func ensureDirectory(_ path: String) async throws { }
    func list(_ path: String) async throws -> [BaiduFile] {
        bytes.keys.sorted().enumerated().compactMap { index, key in
            guard (key as NSString).deletingLastPathComponent == path else { return nil }
            return BaiduFile(id: Int64(index + 1), path: key, name: (key as NSString).lastPathComponent, size: bytes[key]!.count, isDirectory: false, modifiedAt: Date())
        }
    }
    func upload(_ file: URL, to path: String) async throws {
        try Task.checkCancellation()
        if failPDF && path.hasSuffix(".pdf") { throw BaiduError.network(-1005) }
        uploads.append(path); bytes[path] = try Data(contentsOf: file)
    }
    func download(_ file: BaiduFile, to destination: URL, limit: Int) async throws {
        guard let data = bytes[file.path], data.count <= limit else { throw BaiduError.invalidResponse }
        try data.write(to: destination)
    }
}

extension PaperDeskCoreTests {
    func testBaiduOAuthAndTransferProtocol() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BaiduFixtureProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = BaiduNetdiskClient(session: session)
        let code = try await client.deviceCode(appKey: "key+&中文")
        try XCTAssertEqual(code.userCode, "ABCD-1234")
        try XCTAssertEqual(code.verificationURL.host, "openapi.baidu.com")
        let token = try await client.token(appKey: "key+&中文", secret: "secret+&=", deviceCode: code.deviceCode)
        try XCTAssertEqual(token.accessToken, "access")
        try XCTAssertGreaterThan(token.expiresAt.timeIntervalSinceNow, 3500)
        let rotated = try await client.refresh(appKey: "key+&中文", secret: "secret+&=", refreshToken: token.refreshToken)
        try XCTAssertEqual(rotated.refreshToken, "refresh-rotated")
        let account = try await client.accountName(token: "access")
        try XCTAssertEqual(account, "测试用户")
        let listed = try await client.list(path: "/apps/测试", token: "access")
        try XCTAssertEqual(listed.first?.id, 9_007_199_254_740_993)
        try await client.ensureDirectory("/apps/测试", token: "access")
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "upload.bin")
        // A two-part upload; Baidu requests only the missing second part.
        try Data(repeating: 65, count: BaiduNetdiskClient.blockSize + 3).write(to: source)
        try await client.upload(source, to: "/apps/测试/upload.bin", token: "access")
        try await client.upload(source, to: "/apps/测试/upload.bin", token: "rapid")
        let remote = BaiduFile(id: 77, path: "/apps/测试/file", name: "file", size: 5, isDirectory: false, modifiedAt: Date())
        let output = root.appending(path: "download.bin")
        try await client.download(remote, to: output, token: "access", limit: 10)
        try XCTAssertEqual(try Data(contentsOf: output), Data("hello".utf8))
    }
    func testBaiduRejectsUnsafeAndFailedResponses() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BaiduFixtureProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = BaiduNetdiskClient(session: session)
        do { _ = try await client.token(appKey: "key+&中文", secret: "secret+&=", deviceCode: "pending"); try XCTFail("Expected pending") }
        catch BaiduError.oauth("authorization_pending") { }
        do { _ = try await client.accountName(token: "denied"); try XCTFail("Expected denial") }
        catch let error as BaiduError { try XCTAssertFalse(error.localizedDescription.contains("provider-secret")) }
        do { _ = try await client.deviceCode(appKey: "unsafe"); try XCTFail("Expected unsafe auth URL rejection") }
        catch BaiduError.invalidResponse { }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "file"); try Data("AAA".utf8).write(to: source)
        do { try await client.upload(source, to: "/apps/测试/upload.bin", token: "bad-blocks"); try XCTFail("Expected invalid part rejection") }
        catch BaiduError.invalidResponse { }
        let output = root.appending(path: "output")
        let remote = BaiduFile(id: 77, path: "/apps/测试/file", name: "file", size: 5, isDirectory: false, modifiedAt: Date())
        do { try await client.download(remote, to: output, token: "unsafe", limit: 10); try XCTFail("Expected external dlink rejection") }
        catch BaiduError.invalidResponse { }
        try XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        do { try await client.download(remote, to: output, token: "truncated", limit: 10); try XCTFail("Expected incomplete download rejection") }
        catch is PaperDeskError { }
        try XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}

private final class BaiduFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            let params = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let body = requestBody()
            let form = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://fixture.test/?" + String(decoding: body, as: UTF8.self))?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let method = params["method"] ?? "", token = params["access_token"] ?? ""
            var object: [String: Any] = ["errno": 0]
            var raw: Data?
            if url.path == "/oauth/2.0/device/code" {
                try XCTAssertEqual(params["scope"], "basic,netdisk")
                try XCTAssertEqual(params["response_type"], "device_code")
                object = ["device_code": "device", "user_code": "ABCD-1234", "verification_url": params["client_id"] == "unsafe" ? "https://evil.test/login" : "https://openapi.baidu.com/device", "expires_in": 300, "interval": 5]
                if params["client_id"] != "unsafe" { try XCTAssertEqual(params["client_id"], "key+&中文") }
            } else if url.path == "/oauth/2.0/token" {
                try XCTAssertTrue(params.isEmpty)
                try XCTAssertEqual(request.httpMethod, "POST")
                try XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                let params = form
                try XCTAssertEqual(params["client_secret"], "secret+&=")
                try XCTAssertEqual(params["client_id"], "key+&中文")
                if params["code"] == "pending" { object = ["error": "authorization_pending", "error_description": "provider-secret"] }
                else {
                    let refresh = params["grant_type"] == "refresh_token"
                    if refresh { try XCTAssertEqual(params["refresh_token"], "refresh") }
                    else { try XCTAssertEqual(params["grant_type"], "device_token"); try XCTAssertEqual(params["code"], "device") }
                    object = ["access_token": "access", "refresh_token": refresh ? "refresh-rotated" : "refresh", "expires_in": 3600]
                }
            } else if token == "denied" { object = ["errno": -6, "errmsg": "provider-secret"] }
            else if method == "uinfo" { object["netdisk_name"] = "测试用户" }
            else if method == "list" {
                try XCTAssertEqual(params["dir"], "/apps/测试")
                object["list"] = [["fs_id": Int64(9_007_199_254_740_993), "path": "/apps/测试/a.pdf", "server_filename": "a.pdf", "size": 5, "isdir": 0, "server_mtime": 1_700_000_000]]
            } else if method == "precreate" {
                try XCTAssertEqual(request.httpMethod, "POST")
                try XCTAssertEqual(form["path"], "/apps/测试/upload.bin")
                try XCTAssertEqual(form["rtype"], "0")
                if token == "bad-blocks" { object.merge(["uploadid": "upload", "block_list": [1000], "return_type": 1]) { _, n in n } }
                else {
                    try XCTAssertEqual(form["size"], String(BaiduNetdiskClient.blockSize + 3))
                    let hashes = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(form["block_list"]).utf8))
                    try XCTAssertEqual(hashes.count, 2)
                    try XCTAssertEqual(hashes[1], "e1faffb3e614e6c2fba74296962386b7")
                    object.merge(["uploadid": "upload", "block_list": [1], "return_type": token == "rapid" ? 2 : 1]) { _, n in n }
                }
            } else if method == "upload" {
                try XCTAssertEqual(url.host, "d.pcs.baidu.com")
                try XCTAssertEqual(params["partseq"], "1"); try XCTAssertEqual(params["type"], "tmpfile")
                try XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("\r\n\r\nAAA\r\n--"))
                object["md5"] = "e1faffb3e614e6c2fba74296962386b7"
            } else if method == "create" {
                try XCTAssertEqual(request.httpMethod, "POST")
                if form["isdir"] == "1" { object["errno"] = -8 }
                else {
                    try XCTAssertEqual(form["uploadid"], "upload"); try XCTAssertEqual(form["rtype"], "0")
                    object["path"] = "/apps/测试/upload.bin"; object["size"] = BaiduNetdiskClient.blockSize + 3
                }
            } else if method == "filemetas" {
                try XCTAssertEqual(params["fsids"], "[77]"); try XCTAssertEqual(params["dlink"], "1")
                object["list"] = [["fs_id": 77, "dlink": token == "unsafe" ? "https://evil.test/stolen" : "https://d.baidupcs.com/download"]]
            } else if url.path == "/download" {
                try XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "pan.baidu.com")
                raw = Data((token == "truncated" ? "hi" : "hello").utf8)
            } else { throw CheckFailure(description: "Unexpected Baidu request: \(url.path)") }
            let data = try raw ?? JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func requestBody() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
        return data
    }
    override func stopLoading() { }
}
