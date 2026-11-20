import SwiftUI
import AppKit
import PaperDeskCore

struct BrowserExtensionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var isError = false
    private var extensionURL: URL { Bundle.main.bundleURL.appending(path: "Contents/Resources/BrowserExtension", directoryHint: .isDirectory) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "arrow.down.doc").font(.system(size: 25)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("从 Chrome 带回文献").font(.system(size: 21, weight: .semibold))
                    Text("网页 PDF → PaperDesk → 阅读与对话").foregroundStyle(.secondary).font(.system(size: 12))
                }
            }
            Divider()
            step("1", "连接这台 Mac", "启用后，只有 PaperDesk 扩展可以通过本机通道发送 PDF。")
            Button("启用连接") {
                do {
                    try BrowserIntegration.install(appBundle: Bundle.main.bundleURL)
                    isError = false; message = "连接已启用。接下来在 Chrome 中加载扩展。"
                } catch { isError = true; message = error.localizedDescription }
            }.buttonStyle(.borderedProminent)
            step("2", "在 Chrome 中加载扩展", "打开 chrome://extensions，启用「开发者模式」，点击「加载已解压的扩展程序」。")
            HStack {
                Button("显示扩展文件夹") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: extensionURL.path) }
                Button("复制文件夹路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(extensionURL.path, forType: .string); message = "路径已复制；在文件选择窗口按 ⌘⇧G 后粘贴。"; isError = false }
            }
            step("3", "打开 PDF，点击导入", "扩展会查找当前 PDF、网页内嵌 PDF 和 PDF 链接。也可以在链接上右键选择「导入 PDF 到 PaperDesk」。")
            Text("扩展会在导入时申请对应网站权限。需要登录的文献仍受网站下载限制；blob 地址请先下载为文件。普通网页暂不转换成 PDF。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(isError ? Color.red : Palette.accent).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 540)
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent)
                .frame(width: 23, height: 23).background(Palette.accent.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
        }
    }
}
