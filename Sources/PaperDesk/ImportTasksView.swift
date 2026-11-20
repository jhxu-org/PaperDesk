import SwiftUI
import PaperDeskCore

struct ImportQueueButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: PaperImportQueue
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            Label("后台导入 \(queue.activeCount)", systemImage: queue.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .foregroundStyle(queue.failedCount > 0 ? Color.orange : Palette.accent)
        }.accessibilityLabel("后台导入 \(queue.activeCount) 个任务，查看进度")
            .help("查看导入进度、取消或重试任务")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ImportTasksView(queue: queue) { id in
                    showing = false
                    model.openDocument(id: id)
                    model.showPaperSearch = false
                }
            }
    }
}

struct ImportTasksView: View {
    @ObservedObject var queue: PaperImportQueue
    let open: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("后台导入").font(.title3.weight(.semibold))
                    Text("\(queue.activeCount) 个进行中 · \(queue.jobs.filter { $0.state == .completed }.count) 个已完成 · \(queue.failedCount) 个失败")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("清除已结束") { queue.clearFinished() }.disabled(queue.jobs.allSatisfy { $0.state.isActive })
                    .help("仅清除任务记录，保留论文和笔记")
            }.padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if queue.jobs.isEmpty {
                        Text("还没有导入任务。\n在搜索结果中选择论文和保存文件夹即可开始。")
                            .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(6)
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                    ForEach(queue.jobs.sorted { $0.state.isActive && !$1.state.isActive }) { job in
                        taskRow(job)
                    }
                }.padding(16)
            }
            Divider()
            Text("关闭搜索窗口后任务仍会继续，导入完成不会打断当前阅读。")
                .font(.caption).foregroundStyle(.secondary).padding(16)
        }.frame(width: 580, height: 440)
    }
    private func taskRow(_ job: PaperImportJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.article.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Label(job.folderPath, systemImage: "folder").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                if job.state.isActive {
                    Button("取消") { queue.cancel(job.id) }.disabled(job.state == .cancelling)
                        .accessibilityLabel("取消导入：" + job.article.title)
                } else if [.failed, .cancelled].contains(job.state) {
                    Button("重试") { queue.retry(job.id) }.accessibilityLabel("重试导入：" + job.article.title)
                } else if let id = job.documentID {
                    Button("打开") { open(id) }.accessibilityLabel("打开导入的论文：" + job.article.title)
                }
            }
            HStack {
                Text(status(job)).font(.caption).foregroundStyle(job.state == .failed ? Color.red : .secondary)
                Spacer()
                if job.state == .downloading || job.state == .importing {
                    Text(bytes(job.progress)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if job.state == .downloading {
                if let fraction = job.progress.fraction {
                    ProgressView(value: fraction).accessibilityLabel("下载进度 \(Int(fraction * 100))%")
                } else {
                    HStack { ProgressView().controlSize(.small); Text("正在接收文件…").font(.caption).foregroundStyle(.secondary) }
                }
            } else if job.state == .importing { ProgressView().controlSize(.small) }
            if let error = job.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(14).background(Palette.subtle, in: RoundedRectangle(cornerRadius: 10))
    }
    private func status(_ job: PaperImportJob) -> String {
        if job.state == .downloading, let fraction = job.progress.fraction { return "下载中 · \(Int(fraction * 100))%" }
        if job.state == .downloading && job.progress.receivedBytes == 0 { return "连接中，等待下载…" }
        return job.state.title
    }
    private func bytes(_ progress: PaperDownloadProgress) -> String {
        let received = ByteCountFormatter.string(fromByteCount: Int64(progress.receivedBytes), countStyle: .file)
        guard let total = progress.totalBytes else { return "已下载 \(received)" }
        return received + " / " + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}
