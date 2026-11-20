import Foundation
import CryptoKit

public struct BaiduToken: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }
}
public struct BaiduDeviceCode: Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresIn: Int
    public let interval: Int
}
public struct BaiduFile: Identifiable, Sendable {
    public let id: Int64
    public let path: String
    public let name: String
    public let size: Int
    public let isDirectory: Bool
    public let modifiedAt: Date
    public init(id: Int64, path: String, name: String, size: Int, isDirectory: Bool, modifiedAt: Date) {
        self.id = id; self.path = path; self.name = name; self.size = size; self.isDirectory = isDirectory; self.modifiedAt = modifiedAt
    }
}
public enum BaiduError: Error, LocalizedError {
    case api(Int), oauth(String), invalidResponse, network(Int)
    public var errorDescription: String? {
        switch self {
        case .api(let code):
            switch code {
            case -6, 110, 111, 31045: return "百度网盘授权已失效，请重新登录。"
            case -7, 6, 31024: return "网盘目录没有访问权限，请检查应用权限及 /apps/ 后的应用目录名。"
            case -8: return "百度网盘中已有同名文件或目录。"
            case -9, 31066: return "百度网盘中找不到此文件或目录。"
            case 31112: return "百度网盘剩余空间不足。"
            default: return "百度网盘请求失败（错误码 \(code)）。请检查应用权限或稍后重试。"
            }
        case .oauth(let code):
            switch code {
            case "authorization_pending": return "等待你在百度页面完成授权。"
            case "slow_down": return "百度要求稍后重试授权。"
            case "expired_token": return "登录码已过期，请重新登录。"
            case "authorization_declined", "access_denied": return "百度网盘授权已取消。"
            default: return "百度授权失败，请检查 AppKey、SecretKey 和应用权限，再重新登录。"
            }
        case .invalidResponse: return "百度网盘返回了无法识别的数据。"
        case .network(let code): return "无法连接百度网盘（网络错误 \(code)），请检查网络后重试。"
        }
    }
}

public enum BaiduPath {
    public static func root(_ value: String) throws -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.first == "apps", parts.count <= 12, path.utf8.count <= 500,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw PaperDeskError.message("请填写应用专属路径，例如 /apps/你的应用目录名/PaperDesk。")
        }
        return "/" + path
    }
    public static func allowedURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "baidu.com" || host.hasSuffix(".baidu.com") || host == "baidupcs.com" || host.hasSuffix(".baidupcs.com")
    }
}
private final class BaiduRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(BaiduPath.allowedURL) == true ? request : nil)
    }
}

public struct BaiduNetdiskClient: Sendable {
    public static let blockSize = 4 * 1024 * 1024
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 1_800
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config, delegate: BaiduRedirectGuard(), delegateQueue: nil)
        }
    }
    public static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    private func url(_ endpoint: String, query: [String: String]) -> URL {
        var parts = URLComponents(string: endpoint)!
        parts.percentEncodedQuery = query.isEmpty ? nil : String(data: Self.form(query), encoding: .utf8)
        return parts.url!
    }
    private func request(_ endpoint: String, query: [String: String], body: Data? = nil, contentType: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url(endpoint, query: query))
        request.setValue("pan.baidu.com PaperDesk/0.4", forHTTPHeaderField: "User-Agent")
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue(contentType ?? "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw BaiduError.network((error as NSError).code) }
        try Task.checkCancellation()
        guard data.count <= 8 * 1024 * 1024, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BaiduError.invalidResponse }
        if let error = object["error"] as? String { throw BaiduError.oauth(error) }
        if let number = object["errno"] as? Int, number != 0 { throw BaiduError.api(number) }
        if let number = object["error_code"] as? Int, number != 0 { throw BaiduError.api(number) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw BaiduError.invalidResponse }
        return object
    }
    private func fileAPI(_ method: String, token: String, query: [String: String] = [:], body: [String: String]? = nil) async throws -> [String: Any] {
        var query = query; query["method"] = method; query["access_token"] = token
        return try await request("https://pan.baidu.com/rest/2.0/xpan/file", query: query, body: body.map(Self.form))
    }
    public func deviceCode(appKey: String) async throws -> BaiduDeviceCode {
        let object = try await request("https://openapi.baidu.com/oauth/2.0/device/code", query: ["response_type": "device_code", "client_id": appKey, "scope": "basic,netdisk"])
        guard let code = object["device_code"] as? String, !code.isEmpty,
              let userCode = object["user_code"] as? String,
              let address = object["verification_url"] as? String, var url = URLComponents(string: address),
              url.scheme == "https", url.host == "openapi.baidu.com", url.user == nil, url.password == nil, let verified = url.url, BaiduPath.allowedURL(verified) else { throw BaiduError.invalidResponse }
        var items = url.queryItems ?? []; items.append(.init(name: "code", value: userCode)); url.queryItems = items
        return BaiduDeviceCode(deviceCode: code, userCode: userCode, verificationURL: url.url!, expiresIn: min(1_800, max(30, object["expires_in"] as? Int ?? 300)), interval: min(30, max(5, object["interval"] as? Int ?? 5)))
    }
    public func token(appKey: String, secret: String, deviceCode: String) async throws -> BaiduToken {
        try await exchange(["grant_type": "device_token", "code": deviceCode, "client_id": appKey, "client_secret": secret])
    }
    public func refresh(appKey: String, secret: String, refreshToken: String) async throws -> BaiduToken {
        try await exchange(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": appKey, "client_secret": secret])
    }
    private func exchange(_ query: [String: String]) async throws -> BaiduToken {
        let object = try await request("https://openapi.baidu.com/oauth/2.0/token", query: [:], body: Self.form(query))
        guard let access = object["access_token"] as? String, !access.isEmpty,
              let refresh = object["refresh_token"] as? String, !refresh.isEmpty,
              let lifetime = object["expires_in"] as? Double, lifetime > 0 else { throw BaiduError.invalidResponse }
        return BaiduToken(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(lifetime))
    }
    public func accountName(token: String) async throws -> String {
        let object = try await request("https://pan.baidu.com/rest/2.0/xpan/nas", query: ["method": "uinfo", "access_token": token])
        guard let name = object["netdisk_name"] as? String ?? object["baidu_name"] as? String else { throw BaiduError.invalidResponse }
        return name
    }
    public func list(path: String, token: String) async throws -> [BaiduFile] {
        var files: [BaiduFile] = []
        for page in 0..<100 {
            try Task.checkCancellation()
            let object = try await fileAPI("list", token: token, query: ["dir": path, "start": String(page * 1000), "limit": "1000", "order": "name", "desc": "1"])
            guard let entries = object["list"] as? [[String: Any]] else { throw BaiduError.invalidResponse }
            for item in entries {
                guard let id = item["fs_id"] as? NSNumber, let name = item["server_filename"] as? String,
                      let filePath = item["path"] as? String, let size = item["size"] as? Int, let isdir = item["isdir"] as? Int,
                      !name.contains("/"), filePath == path + "/" + name, size >= 0 else { throw BaiduError.invalidResponse }
                files.append(BaiduFile(id: id.int64Value, path: filePath, name: name, size: size, isDirectory: isdir == 1,
                    modifiedAt: Date(timeIntervalSince1970: item["server_mtime"] as? Double ?? 0)))
            }
            if entries.count < 1000 { return files }
        }
        throw PaperDeskError.message("云端目录文件过多，请使用单独的 PaperDesk 保存目录。")
    }
    public func ensureDirectory(_ path: String, token: String) async throws {
        do {
            let result = try await fileAPI("create", token: token, body: ["path": path, "isdir": "1", "rtype": "0"])
            guard result["isdir"] as? Int == 1, result["path"] as? String == path else { throw BaiduError.invalidResponse }
        } catch BaiduError.api(-8) {
            _ = try await list(path: path, token: token) // A same-name file must not be accepted as a directory.
        }
    }
    public func upload(_ file: URL, to path: String, token: String) async throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= CloudArchive.maximumPDFBytes else { throw PaperDeskError.message("云端保存支持 500 MB 以内的单个文件。") }
        var hashes: [String] = []
        for start in stride(from: 0, to: data.count, by: Self.blockSize) {
            try Task.checkCancellation()
            hashes.append(Insecure.MD5.hash(data: data[start..<min(start + Self.blockSize, data.count)]).map { String(format: "%02x", $0) }.joined())
        }
        let hashList = String(data: try JSONEncoder().encode(hashes), encoding: .utf8)!
        var body = ["path": path, "size": String(data.count), "isdir": "0", "autoinit": "1", "rtype": "0", "block_list": hashList]
        let pre = try await fileAPI("precreate", token: token, body: body)
        if pre["return_type"] as? Int == 2 { return }
        guard let uploadID = pre["uploadid"] as? String, !uploadID.isEmpty, let blocks = pre["block_list"] as? [Int],
              Set(blocks).count == blocks.count, blocks.allSatisfy({ hashes.indices.contains($0) }) else { throw BaiduError.invalidResponse }
        for index in blocks {
            try Task.checkCancellation()
            let start = index * Self.blockSize
            let boundary = "PaperDesk-" + UUID().uuidString
            var part = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"block\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
            part.append(data[start..<min(start + Self.blockSize, data.count)])
            part.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let result = try await request("https://d.pcs.baidu.com/rest/2.0/pcs/superfile2", query: ["method": "upload", "type": "tmpfile", "access_token": token, "path": path, "uploadid": uploadID, "partseq": String(index)], body: part, contentType: "multipart/form-data; boundary=\(boundary)")
            guard let md5 = result["md5"] as? String, md5.lowercased() == hashes[index] else { throw PaperDeskError.message("百度网盘上传分片校验失败，请重试。") }
        }
        body.removeValue(forKey: "autoinit"); body["uploadid"] = uploadID
        let result = try await fileAPI("create", token: token, body: body)
        guard result["path"] as? String == path, result["size"] as? Int == data.count else { throw BaiduError.invalidResponse }
    }
    public func download(_ file: BaiduFile, to destination: URL, token: String, limit: Int) async throws {
        guard !file.isDirectory, file.size > 0, file.size <= limit else { throw PaperDeskError.message("云端文件大小不符合限制。") }
        let meta = try await request("https://pan.baidu.com/rest/2.0/xpan/multimedia", query: ["method": "filemetas", "access_token": token, "fsids": "[\(file.id)]", "dlink": "1"])
        guard let entry = (meta["list"] as? [[String: Any]])?.first, (entry["fs_id"] as? NSNumber)?.int64Value == file.id,
              let link = entry["dlink"] as? String, let remote = URL(string: link), BaiduPath.allowedURL(remote),
              var parts = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { throw BaiduError.invalidResponse }
        var query = parts.queryItems ?? []; query.removeAll { $0.name == "access_token" }; query.append(.init(name: "access_token", value: token)); parts.queryItems = query
        var request = URLRequest(url: parts.url!); request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent")
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: destination)
        var completed = false
        defer { try? output.close(); if !completed { try? FileManager.default.removeItem(at: destination) } }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= limit else { throw BaiduError.invalidResponse }
            var buffer = Data(); buffer.reserveCapacity(65_536); var count = 0
            try await withTaskCancellationHandler {
                for try await byte in bytes {
                    try Task.checkCancellation(); buffer.append(byte); count += 1
                    guard count <= limit, count <= file.size else { throw BaiduError.invalidResponse }
                    if buffer.count == 65_536 { try output.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
                }
            } onCancel: { bytes.task.cancel() }
            try output.write(contentsOf: buffer)
            guard count == file.size else { throw PaperDeskError.message("云端下载不完整，请重试。") }
            completed = true
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? BaiduError { throw error }
            if let error = error as? PaperDeskError { throw error }
            throw BaiduError.network((error as NSError).code)
        }
    }
}
