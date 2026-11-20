import SwiftUI
import PaperDeskCore

struct InspectorPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                tab("阅读助手", icon: "sparkles", id: "assistant")
                tab("我的笔记", icon: "square.and.pencil", id: "notes")
                Spacer(minLength: 0)
                Button { model.showFloatingChat() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("在浮窗中打开对话").accessibilityLabel("在浮窗中打开对话")
            }.padding(.horizontal, 20).frame(height: 70)
            Divider()
            if model.inspectorTab == "assistant" {
                if model.isChatFloating {
                    VStack(spacing: 16) {
                        Image(systemName: "macwindow.on.rectangle").font(.system(size: 26)).foregroundStyle(Palette.accent)
                        Text("对话已在浮窗中打开").font(.system(size: 14, weight: .medium))
                        Button("显示对话浮窗") { model.showFloatingChat() }
                        Button("回到侧栏") { model.closeFloatingChat() }
                        Spacer()
                    }.padding(.top, 40).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { AssistantPane(model: model) }
            }
            else { NotesPane(model: model) }
        }.background(.background)
    }
    private func tab(_ title: String, icon: String, id: String) -> some View {
        Button { model.inspectorTab = id } label: {
            VStack(spacing: 0) {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    Text(title)
                    if id == "notes" && !model.notes.isEmpty {
                        Text("\(model.notes.count)").font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Palette.accent.opacity(0.09), in: Capsule())
                    }
                }.font(.system(size: 12, weight: model.inspectorTab == id ? .semibold : .regular))
                    .foregroundStyle(model.inspectorTab == id ? Palette.accent : .secondary)
                Spacer()
                Capsule().fill(model.inspectorTab == id ? Palette.accent : .clear).frame(height: 2)
            }
        }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
    }
}

struct AssistantPane: View {
    @ObservedObject var model: AppModel
    var isFloating = false
    @State private var showFullSelection = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "doc.text.viewfinder").foregroundStyle(Palette.accent)
                    Picker("分析范围", selection: Binding(get: { model.chatScope }, set: { model.setChatScope($0) })) {
                        Text("自动识别问题范围").tag(ChatScope.automatic)
                        Text("仅当前页 · 第 \(model.currentPage + 1) 页").tag(ChatScope.currentPage)
                        Text("仅选中内容").tag(ChatScope.selection)
                        Text("全文相关内容").tag(ChatScope.document)
                    }.labelsHidden().pickerStyle(.menu).accessibilityLabel("分析范围")
                    Spacer(minLength: 0)
                    Button {
                        model.ask("请图文并茂地解读这篇论文：结合相关图表说明研究问题、方法、实验结果与局限，在对应解释后展示原文配图，并标注原文依据。", scope: .document)
                    } label: { Image(systemName: "doc.richtext") }
                        .buttonStyle(.plain).foregroundStyle(Palette.accent)
                        .help("图文解读整篇论文").accessibilityLabel("图文解读整篇论文")
                        .disabled(model.isAsking || model.isIndexing)
                }
                Button { model.openSettings() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(model.isConfigured ? Palette.accent : .secondary).frame(width: 5, height: 5)
                        Text(model.isConfigured ? model.modelName : "选择并连接大模型").lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "slider.horizontal.3")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel("配置对话模型")
            }.padding(.horizontal, 18).padding(.vertical, 13)
            Divider()
            if isFloating && model.showsChatSelection {
                selectionCard.padding(.top, 12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if model.messages.isEmpty { introduction }
                        else {
                            ForEach(model.messages) { message in
                                ChatBubble(message: message, model: model, isFloating: isFloating).id(message.id)
                            }
                        }
                        if let partial = model.streamingMessage {
                            ChatBubble(message: partial, model: model, isFloating: isFloating)
                            Text(model.isAsking ? "正在生成…" : "未完成的回答")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        } else if model.isAsking {
                            HStack(spacing: 9) { ProgressView().controlSize(.small); Text("正在分析，等待模型回答…").font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        if let error = model.chatError {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    if model.canRetryAnswer { Button("重试这个问题") { model.retryAnswer() } }
                                    Button("模型设置") { model.openSettings() }
                                }.controlSize(.small)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(20)
                }
                .onChange(of: model.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.isAsking) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.streamingMessage?.content.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { if !model.messages.isEmpty || model.isAsking { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            Spacer(minLength: 0)
            if !isFloating && model.showsChatSelection {
                selectionCard
            }
            if !model.isConfigured {
                Button { model.openSettings() } label: {
                    HStack { Image(systemName: "key.horizontal"); Text("连接 AI 模型"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 11, weight: .medium)).padding(12)
                        .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).foregroundStyle(Palette.accent).padding(.horizontal, 16).padding(.bottom, 10)
            }
            VStack(alignment: .leading, spacing: 10) {
                ChatInputView(text: $model.draftQuestion,
                    placeholder: model.chatScope == .currentPage ? "关于第 \(model.currentPage + 1) 页，问点什么…" : "关于这篇论文，问点什么…也可以接着追问",
                    canSubmit: !model.isAsking && !model.isIndexing,
                    onSubmit: { model.ask() })
                    .id(model.selectedID)
                    .frame(height: 76)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.isIndexing ? "正在提取正文" : model.chatScopeLabel)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("Enter 发送 · Shift+Enter 换行")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if model.isAsking {
                        Button { model.cancelAnswer() } label: { Image(systemName: "stop.fill").frame(width: 26, height: 24) }.help("停止生成")
                    } else {
                        Button { model.ask() } label: { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 24) }
                            .buttonStyle(.borderedProminent).disabled(model.draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isIndexing)
                            .help("Enter 或 ⌘Enter 发送，Shift+Enter 换行").accessibilityLabel("发送问题")
                    }
                }
            }.padding(12).background(Palette.subtle, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.separator)).padding(.horizontal, 16)
            Text(model.sendPageImages ? "提问时发送相关正文和最多 3 页图片至模型服务" : "提问时发送相关正文；模型设置中可开启读图")
                .font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 14)
        }
    }
    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.pinnedChatSelection.isEmpty ? "text.quote" : "pin.fill")
                Text(model.chatSelectionLabel)
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if let source = model.pinnedChatSelection.first {
                    Button("原文") { model.jump(to: source) }.help("返回选区原文")
                }
                Button { showFullSelection.toggle() } label: { Image(systemName: showFullSelection ? "chevron.up" : "chevron.down") }
                    .help(showFullSelection ? "收起选区原文" : "展开选区原文")
                    .accessibilityLabel(showFullSelection ? "收起选区原文" : "展开选区原文")
                Button { model.clearChatSelection() } label: { Image(systemName: "xmark") }
                    .help("移除讨论选区").accessibilityLabel("移除讨论选区")
            }.font(.system(size: 10)).foregroundStyle(Palette.accent).buttonStyle(.plain)
            if showFullSelection {
                ScrollView {
                    Text(model.chatSelectionText).font(.system(size: isFloating ? 13 : 11))
                        .lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: isFloating ? 140 : 100)
            } else {
                Text(String(model.chatSelectionText.prefix(600))).font(.system(size: isFloating ? 13 : 11))
                    .lineSpacing(4).lineLimit(3).foregroundStyle(.secondary)
            }
            if isFloating {
                HStack {
                    Text(model.pinnedChatSelection.isEmpty ? "选中原文后，可固定选区再追问" : "选区已固定，可继续翻阅 PDF").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("使用新选区") { model.discussSelection() }
                        .disabled(model.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isAsking)
                }.font(.system(size: 10)).buttonStyle(.plain)
            } else {
                Button { model.showFloatingChat() } label: { Label("在浮窗中讨论", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
            }
        }.padding(12).background(Palette.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16).padding(.bottom, 10)
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "sparkles").font(.system(size: 25, weight: .light)).foregroundStyle(Palette.accent)
                .frame(width: 52, height: 52).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 15)).padding(.top, 14).padding(.bottom, 20)
            Text(model.showsChatSelection ? "从这一段，继续深入。" : "读懂，也读深。")
                .font(.system(size: 21, weight: .semibold)).padding(.bottom, 11)
            Text(model.showsChatSelection ? "可以围绕选区讨论，也可以追问整篇论文。自动模式会根据问题选择范围。" : "直接提问，自动结合论文查找相关内容。问到这一页或选区时会聚焦分析，也可以跨章节讨论和连续追问。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 27)
            if model.showsChatSelection {
                suggestion("questionmark.bubble", "解释这段内容", "拆解概念与推理过程", "请解释选中内容的含义和关键概念，并标注原文依据。", scope: .selection)
                suggestion("text.magnifyingglass", "检查论证依据", "有哪些证据，哪些仍需核对", "请分析选中内容的论证和证据，区分原文结论与推断，并标注原文依据。", scope: .selection)
            } else {
                suggestion("doc.richtext", "图文解读论文", "结合原文图表，理解方法与证据", "请图文并茂地解读这篇论文：说明研究问题，结合相关图表解释方法、实验结果与局限。在解释对应内容时展示提供的原文配图，说明如何读图，并标注原文依据。", scope: .document)
                suggestion("questionmark.bubble", "分析当前页", "核心观点、依据与疑问", "请分析当前页：概括核心观点，解释关键概念，列出值得追问的问题，并标注原文依据。", scope: .currentPage)
                suggestion("text.alignleft", "梳理整篇文献", "结合全文相关片段总结", "请基于提供的文献内容，总结研究问题、主要观点、证据和局限，并标注原文依据。", scope: .document)
            }
            suggestion("character.bubble", "翻译选中内容", "保留术语，理解原意", "请翻译选中的内容，保留关键学术术语并标注原文依据。", scope: .selection)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "arrow.turn.up.left").padding(.top, 2)
                Text("回答中的来源标记可以带你回到原文。核对上下文，让每个理解都有依据。")
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 22)
        }
    }
    private func suggestion(_ icon: String, _ title: String, _ detail: String, _ prompt: String, scope: ChatScope) -> some View {
        Button {
            if scope == .selection && model.chatSelectionText.isEmpty { model.notify("先在 PDF 中选中需要讨论的文字") }
            else { model.ask(prompt, scope: scope) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15, weight: .light)).foregroundStyle(Palette.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(14).background(Palette.subtle.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.separator))
        }.buttonStyle(.plain).padding(.bottom, 9).disabled(model.isAsking || model.isIndexing)
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    @ObservedObject var model: AppModel
    var isFloating = false
    private var formatted: AttributedString {
        var content = message.content
        if message.role == "assistant" {
            for source in message.sources {
                content = content.replacingOccurrences(of: "[\(source.id)]", with: "[第 \(source.page + 1) 页](paperdesk://source/\(source.id))")
            }
        }
        return (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: message.role == "user" ? "person.crop.circle" : "sparkles")
                Text(message.role == "user" ? "你" : "阅读助手")
                Spacer()
                if let context = message.context { Text(context.label).font(.system(size: 9)).foregroundStyle(.secondary) }
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(message.role == "user" ? .secondary : Palette.accent)
            if message.role == "assistant" {
                ChatRichText(message: message, fontSize: isFloating ? 14 : 12,
                    documentURL: model.documentURL(for: message.documentID), onVisualPDF: { model.showVisualInPDF($0) }) { model.jump(to: $0) }
            } else {
                Text(formatted).font(.system(size: isFloating ? 14 : 12))
                    .lineSpacing(isFloating ? 7 : 6).textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "paperdesk", let source = message.sources.first(where: { $0.id == url.lastPathComponent }) else { return .discarded }
                        model.jump(to: source); return .handled
                    })
            }
            if !message.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(message.sources) { source in
                            Button { model.jump(to: source) } label: {
                                Label("第 \(source.page + 1) 页", systemImage: "doc.text.magnifyingglass")
                                    .font(.system(size: 10)).padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(Palette.accent.opacity(0.08), in: Capsule())
                            }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(message.role == "user" ? 12 : 0)
            .background(message.role == "user" ? Palette.subtle : .clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct NotesPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if model.notes.isEmpty {
                VStack(alignment: .leading, spacing: 15) {
                    Image(systemName: "highlighter").font(.system(size: 26, weight: .light)).foregroundStyle(Palette.accent)
                    Text("把思考留在页边。").font(.system(size: 20, weight: .semibold))
                    Text("选中一段原文，点击“高亮”或按 ⌘⇧H，即可在这里补充笔记。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(6)
                }.padding(24).padding(.top, 18)
                Spacer()
            } else {
                HStack {
                    Text("\(model.notes.count) 条高亮与笔记").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.exportNotes() } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.plain).help("导出 Markdown 笔记")
                }.padding(18)
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.notes) { note in NoteCard(note: note, model: model) }
                    }.padding(.horizontal, 16).padding(.bottom, 20)
                }
            }
        }
    }
}

struct NoteCard: View {
    let note: ReadingNote
    @ObservedObject var model: AppModel
    @State private var bodyText: String
    @State private var confirmDelete = false
    init(note: ReadingNote, model: AppModel) {
        self.note = note; self.model = model; _bodyText = State(initialValue: note.body)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.jump(to: note) } label: { Label("第 \(note.page + 1) 页", systemImage: "arrow.up.left").font(.system(size: 10, weight: .medium)) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                Spacer()
                Button { confirmDelete = true } label: { Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.tertiary) }.buttonStyle(.plain).help("删除此高亮与笔记")
            }
            Text(note.quote).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).lineLimit(8)
                .padding(.leading, 10).overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color.yellow.opacity(0.65)).frame(width: 3) }
                .textSelection(.enabled)
            TextField("添加你的思考…", text: $bodyText, axis: .vertical).lineLimit(2...8)
                .textFieldStyle(.plain).font(.system(size: 12)).accessibilityLabel("笔记内容")
            if bodyText != note.body {
                HStack { Spacer(); Button("保存笔记") { model.updateNote(note, body: bodyText) }.buttonStyle(.borderedProminent).controlSize(.small) }
            } else if !note.body.isEmpty {
                Label("已保存", systemImage: "checkmark").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }.padding(14).background(Palette.subtle.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.separator))
            .alert("删除这条高亮与笔记？", isPresented: $confirmDelete) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) { model.deleteNote(note) }
            } message: { Text("原始 PDF 不会被修改。") }
    }
}
