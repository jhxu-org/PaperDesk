import SwiftUI
import PaperDeskCore

actor PDFVisualCache {
    static let shared = PDFVisualCache()
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    func images(url: URL, visuals: [ChatVisual], size: Int = 1600) async throws -> [ChatPageImage] {
        var result: [ChatPageImage] = []
        for visual in visuals {
            try Task.checkCancellation()
            let key = url.path + "|\(visual.page)|\(size)"
            if let jpeg = cache[key] { result.append(ChatPageImage(visual: visual, jpeg: jpeg)); continue }
            let worker = Task.detached(priority: .utility) { try ChatVisualBuilder.render(url: url, visuals: [visual], maxDimension: size) }
            let rendered = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            if let image = rendered.first {
                cache[key] = image.jpeg; order.removeAll { $0 == key }; order.append(key)
                while order.count > 18 { cache.removeValue(forKey: order.removeFirst()) }
                result.append(image)
            }
        }
        return result
    }
}

struct PDFVisualPreview: View {
    let visual: ChatVisual
    let documentURL: URL?
    let onShowPDF: (ChatVisual) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var error: String?
    @State private var zoom = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("第 \(visual.page + 1) 页 · 原文配图", systemImage: "doc.richtext")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(visual.caption).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
            GeometryReader { geometry in
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                            .accessibilityLabel("第 \(visual.page + 1) 页原始 PDF 图片")
                    }
                } else if let error {
                    ContentUnavailableView("预览暂不可用", systemImage: "doc", description: Text(error))
                } else { ProgressView("正在载入原文图片…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 1...3).frame(width: 130).accessibilityLabel("配图缩放")
                Text("\(Int(zoom * 100))%").font(.system(size: 11)).monospacedDigit()
                Spacer()
                Button("在 PDF 中展示") { dismiss(); onShowPDF(visual) }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 640, height: 700)
            .task {
                guard let documentURL else { error = "请打开对应文献后重试。"; return }
                do {
                    let loaded = try await PDFVisualCache.shared.images(url: documentURL, visuals: [visual], size: 2400)
                    guard !Task.isCancelled else { return }
                    image = loaded.first.flatMap { NSImage(data: $0.jpeg) }
                    if image == nil { error = "请点击“在 PDF 中展示”查看原文。" }
                } catch { self.error = error.localizedDescription }
            }
    }
}
