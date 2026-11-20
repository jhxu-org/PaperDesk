import Foundation

public enum BrowserIntegration {
    public static let extensionID = "cmahkelbeldefdjkebioakmadgmbfbod"
    public static let hostName = "com.paperdesk.browser"
    public static var origin: String { "chrome-extension://\(extensionID)/" }
}

extension BrowserIntegration {
    @discardableResult
    public static func install(appBundle: URL, applicationSupport: URL? = nil) throws -> URL {
        let helper = appBundle.appending(path: "Contents/MacOS/PaperDeskBridge")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw PaperDeskError.message("请打开完整的 PaperDesk.app 后设置扩展。") }
        let support = try applicationSupport ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appending(path: "Google/Chrome/NativeMessagingHosts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": hostName, "description": "Import browser PDFs into PaperDesk", "path": helper.path, "type": "stdio", "allowed_origins": [origin]]
        let url = directory.appending(path: hostName + ".json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        return url
    }
}
