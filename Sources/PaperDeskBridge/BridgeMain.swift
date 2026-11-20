import Foundation
import AppKit
import PaperDeskCore

struct Request: Decodable {
    let type: String
    let title: String?
    let sourceURL: String?
    let sequence: Int?
    let data: String?
    let byteCount: Int?
}

@main
struct BridgeMain {
    @MainActor
    static func main() async {
        // Chrome supplies the caller origin. The manifest independently restricts allowed_origins.
        guard CommandLine.arguments.dropFirst().first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == BrowserIntegration.origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return }
        do {
            let inbox = BrowserImportInbox(root: try BrowserImportInbox.libraryRoot())
            let transfer = BrowserPDFTransfer(inbox: inbox)
            while let data = try NativeMessageFraming.read(from: .standardInput) {
                do {
                    let request = try JSONDecoder().decode(Request.self, from: data)
                    var response: [String: Any] = ["ok": true]
                    switch request.type {
                    case "ping": response["version"] = "0.3.0"
                    case "begin":
                        guard let title = request.title, let url = request.sourceURL else { throw PaperDeskError.message("缺少 PDF 信息。") }
                        response["id"] = try transfer.begin(title: title, sourceURL: url)
                    case "chunk":
                        guard let sequence = request.sequence, let bytes = request.data else { throw PaperDeskError.message("缺少 PDF 分块。") }
                        try transfer.append(sequence: sequence, base64: bytes)
                    case "cancel": transfer.cancel()
                    case "finish":
                        let id = try transfer.prepare(byteCount: request.byteCount ?? -1)
                        let receiptURL = try inbox.receiptURL(id)
                        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                        guard app.pathExtension == "app" else { throw PaperDeskError.message("请使用 PaperDesk 应用内的浏览器桥接程序。") }
                        let config = NSWorkspace.OpenConfiguration()
                        config.activates = true
                        _ = try await NSWorkspace.shared.open([URL(string: "paperdesk://browser-import/\(id)")!], withApplicationAt: app, configuration: config)
                        var receipt: BrowserImportReceipt?
                        for _ in 0..<300 {
                            if let data = try? Data(contentsOf: receiptURL) {
                                receipt = try JSONDecoder().decode(BrowserImportReceipt.self, from: data); break
                            }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        guard let receipt else { throw PaperDeskError.message("PDF 已保存到待导入队列。请退出并重新打开最新版 PaperDesk。") }
                        try? FileManager.default.removeItem(at: receiptURL)
                        response["ok"] = receipt.ok; response["message"] = receipt.message
                    default: throw PaperDeskError.message("不支持的浏览器消息。")
                    }
                    try NativeMessageFraming.write(JSONSerialization.data(withJSONObject: response), to: .standardOutput)
                } catch {
                    transfer.cancel()
                    try NativeMessageFraming.write(JSONSerialization.data(withJSONObject: ["ok": false, "message": error.localizedDescription]), to: .standardOutput)
                }
            }
        } catch {
            // stdout is exclusively the native messaging protocol.
            try? FileHandle.standardError.write(contentsOf: Data("PaperDesk browser connection ended.\n".utf8))
        }
    }
}
