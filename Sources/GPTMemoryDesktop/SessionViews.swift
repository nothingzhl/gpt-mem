import SwiftUI
import GPTSessionKit

enum SessionWorkspaceSection: String, CaseIterable {
    case projects, statistics, sessions
    var title: String {
        switch self {
        case .projects: return "项目概览"
        case .statistics: return "统计图表"
        case .sessions: return "会话浏览"
        }
    }
}

/// The observed workspace lives below this stable host, so memory sampling updates
/// don't rebuild a long transcript. Its own model/state changes still redraw it.
struct SessionWorkspaceHost: View, Equatable {
    let model: SessionDesktopModel
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model }
    var body: some View { SessionsContent(model: model) }
}

struct SessionsContent: View {
    @ObservedObject var model: SessionDesktopModel
    @State private var expandedMessageIDs: Set<String>
    @State private var section: SessionWorkspaceSection
    @State private var messageRangeStart: Int
    @State private var showTokenDetails = false
    private let initiallyExpandedWarnings: Bool

    init(model: SessionDesktopModel, initiallyExpandedMessageIDs: Set<String> = [],
         initialSection: SessionWorkspaceSection = .projects, initiallyExpandedWarnings: Bool = false) {
        self.model = model
        self.initiallyExpandedWarnings = initiallyExpandedWarnings
        _expandedMessageIDs = State(initialValue: initiallyExpandedMessageIDs)
        _section = State(initialValue: initialSection)
        _messageRangeStart = State(initialValue: SessionMessagePage.latestStart(messageCount: model.transcript?.messages.count ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("查看", selection: $section) {
                    ForEach(SessionWorkspaceSection.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }.pickerStyle(.segmented).frame(width: 360)
                Spacer()
                if model.isFiltering {
                    ProgressView().controlSize(.small)
                    Text("更新筛选…").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }
            }
            controls
            if let error = model.errorMessage {
                SessionWarningsDisclosure(title: "读取失败", warnings: [error], initiallyExpanded: true)
            }
            if !model.catalogWarnings.isEmpty {
                SessionWarningsDisclosure(title: "读取提示", warnings: model.catalogWarnings,
                                          initiallyExpanded: initiallyExpandedWarnings)
            }
            if section != .sessions {
                SessionProjectsContent(model: model, showStatistics: section == .statistics,
                                       onShowStatistics: { section = .statistics }) { project in
                    model.selectedProject = project.id
                    section = .sessions
                }
            } else {
                DisclosureGroup("会话与 Token 统计（\(model.filteredSessions.count) 个会话 · 总 Token \(model.total(\.effectiveTotal).displayValue)）",
                                isExpanded: $showTokenDetails) {
                    statistics.padding(.top, 8)
                }.font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                HStack(alignment: .top, spacing: 14) {
                    sessionList.frame(width: 290)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.frame(maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .disclosureGroupStyle(WideDisclosureGroupStyle())
            .task { model.loadIfNeeded() }
            .onChange(of: model.selectedSessionID) { _, _ in expandedMessageIDs.removeAll() }
            .onChange(of: model.transcript?.summary.id) { _, _ in
                messageRangeStart = SessionMessagePage.latestStart(messageCount: model.transcript?.messages.count ?? 0)
            }
            .onChange(of: model.transcript?.messages.count) { _, _ in
                // A cached same-ID reload can complete within one render frame;
                // count changes must still move the page into the new valid range.
                messageRangeStart = SessionMessagePage.latestStart(messageCount: model.transcript?.messages.count ?? 0)
            }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(MemoryStyle.secondary)
                    TextField("搜索标题、用户消息、会话 ID 或项目", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(MemoryStyle.secondary)
                            .help("清除搜索").accessibilityLabel("清除搜索")
                    }
                }
                Picker("项目", selection: $model.selectedProject) {
                    Text("全部项目").tag(Optional<String>.none)
                    ForEach(model.projectPaths, id: \.self) { path in
                        Text(path == SessionProjectSummary.unknownID ? "未记录项目" : path).tag(Optional(path))
                    }
                }.frame(maxWidth: 230)
                Toggle("包含归档", isOn: $model.includeArchived).toggleStyle(.checkbox)
                Button { model.refresh() } label: {
                    Label(model.isLoading ? "读取中" : "刷新", systemImage: "arrow.clockwise")
                }.disabled(model.isLoading)
            }
            Text("本地只读 · 用量按完整会话汇总，缓存属于输入、推理属于输出；数据缺失时显示已知合计。")
                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                .textSelection(.enabled).lineLimit(2)
        }
    }

    private var statistics: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            metric(title: "会话", value: "\(model.filteredSessions.count)",
                   detail: "当前筛选 / 共 \(model.sessions.count) 个本地会话", icon: "bubble.left.and.bubble.right")
            tokenMetric("总 Token", keyPath: \.effectiveTotal, icon: "sum")
            tokenMetric("输入 Token", keyPath: \.input, icon: "arrow.right.circle")
            tokenMetric("输出 Token", keyPath: \.output, icon: "arrow.left.circle")
            tokenMetric("缓存输入 Token", keyPath: \.cachedInput, icon: "externaldrive")
            tokenMetric("推理输出 Token", keyPath: \.reasoningOutput, icon: "lightbulb")
        }
    }

    private func tokenMetric(_ title: String, keyPath: KeyPath<CodexTokenUsage, Int?>, icon: String) -> some View {
        let total = model.total(keyPath)
        return metric(title: title, value: total.displayValue, detail: total.detail, icon: icon)
    }

    private func metric(title: String, value: String, detail: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(MemoryStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                    Spacer(minLength: 5)
                    Text(value).font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                }
                Text(detail).font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary).lineLimit(1)
            }
        }.padding(12).background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MemoryStyle.border))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Codex 会话").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                else { MemoryBadge(text: "\(model.filteredSessions.count)") }
            }.padding(14)
            Rectangle().fill(MemoryStyle.border).frame(height: 1)
            if model.filteredSessions.isEmpty {
                MemoryEmptyState(icon: "bubble.left", title: emptyListTitle, detail: emptyListDetail)
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.filteredSessions) { session in
                            Button { model.select(session.id) } label: { row(session) }.buttonStyle(.plain)
                                .disabled(model.isFiltering)
                        }
                    }.padding(8)
                }
            }
            Spacer(minLength: 0)
        }.frame(maxHeight: .infinity, alignment: .topLeading)
            .background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MemoryStyle.border))
    }

    private var emptyListTitle: String {
        if model.isLoading { return "正在读取本地会话" }
        if model.errorMessage != nil && model.sessions.isEmpty { return "无法读取会话" }
        return model.sessions.isEmpty ? "暂无 Codex 会话" : "没有匹配的会话"
    }

    private var emptyListDetail: String {
        if model.isLoading { return "会话索引在后台读取。" }
        if model.sessions.isEmpty { return "使用 Codex 后点击刷新；读取 sessions 和 archived_sessions 中的本地 JSONL。" }
        return "调整搜索词、项目筛选，或打开“包含归档”。"
    }

    private func row(_ session: CodexSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if session.isArchived { MemoryBadge(text: "归档", color: MemoryStyle.secondary) }
            }
            Text(session.projectPath ?? "项目未记录").font(.system(size: 10))
                .foregroundStyle(MemoryStyle.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                Text(MemoryFormat.date(session.updatedAt))
                Spacer()
                Text("\(session.messageCount) 条消息 · \(session.toolCallCount) 次工具")
            }.font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
            Text("总 Token：\(tokenText(session.tokens.effectiveTotal))")
                .font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedSessionID == session.id ? MemoryStyle.accentBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
    }

    @ViewBuilder private var detail: some View {
        if let summary = model.selectedSession {
            VStack(alignment: .leading, spacing: 12) {
                if let latest = model.transcript?.summary, latest.id == summary.id { metadata(latest) }
                else { metadata(summary) }
                if model.isLoadingTranscript {
                    HStack { ProgressView().controlSize(.small); Text("正在读取会话内容…").font(.system(size: 12)) }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if let error = model.transcriptErrorMessage {
                    SessionWarningsDisclosure(title: "会话内容读取失败", warnings: [error], initiallyExpanded: true)
                    Button("重新读取内容") { model.select(summary.id, forceReload: true) }
                } else if let transcript = model.transcript {
                    transcriptView(transcript)
                }
            }.frame(maxHeight: .infinity, alignment: .topLeading)
        } else {
            MemoryEmptyState(icon: "text.bubble", title: "选择一个会话", detail: "查看完整消息、工具调用和日志记录的 Token 用量。所有内容只在本机读取。")
                .frame(maxHeight: .infinity).background(MemoryStyle.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(MemoryStyle.border))
        }
    }

    private func metadata(_ summary: CodexSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(summary.title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                Spacer()
                if summary.isArchived { MemoryBadge(text: "已归档", color: MemoryStyle.secondary) }
            }
            Text(summary.projectPath ?? "项目未记录").font(.system(size: 10))
                .foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
            HStack {
                Text("模型：\(summary.model ?? "未记录")")
                Spacer()
                Text("开始：\(summary.startedAt.map(MemoryFormat.date) ?? "未记录")")
                Text("更新：\(MemoryFormat.date(summary.updatedAt))")
            }.font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            Text("ID：\(summary.sessionID)").font(.system(size: 10, design: .monospaced))
                .foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
            Text("输入 \(tokenText(summary.tokens.input)) · 输出 \(tokenText(summary.tokens.output)) · 缓存输入 \(tokenText(summary.tokens.cachedInput)) · 推理输出 \(tokenText(summary.tokens.reasoningOutput)) · 总计 \(tokenText(summary.tokens.effectiveTotal))")
                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MemoryStyle.border))
    }

    private func transcriptView(_ transcript: SessionTranscript) -> some View {
        let index = model.transcriptIndex
        let prompts = index?.prompts ?? []
        return ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                if let firstMatch = model.firstMatchingUserMessageID, !model.isFiltering {
                    Button("跳到首条匹配的用户消息") {
                        jump(to: firstMatch, in: transcript, using: proxy)
                    }.font(.system(size: 11))
                }
                if !prompts.isEmpty {
                    DisclosureGroup("用户消息目录（\(prompts.count)）") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 7) {
                                ForEach(Array(prompts.enumerated()), id: \.offset) { _, prompt in
                                    Button {
                                        jump(to: prompt.id, in: transcript, using: proxy)
                                    } label: {
                                        Text(prompt.text.prefix(90)).font(.system(size: 11)).lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 6)
                        }.frame(maxHeight: 120)
                    }.font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                }
                if transcript.messages.count > SessionMessagePage.size {
                    HStack {
                        Button("更早的消息") {
                            showPage(startingAt: max(0, messageRangeStart - SessionMessagePage.size), using: proxy)
                        }.disabled(messageRangeStart == 0)
                        Text("\(messageRangeStart + 1)–\(min(transcript.messages.count, messageRangeStart + SessionMessagePage.size)) / \(transcript.messages.count) 条")
                            .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                        Button("更近的消息") {
                            showPage(startingAt: min(SessionMessagePage.latestStart(messageCount: transcript.messages.count),
                                                    messageRangeStart + SessionMessagePage.size), using: proxy)
                        }.disabled(messageRangeStart + SessionMessagePage.size >= transcript.messages.count)
                        Spacer()
                        Button("最新") {
                            showPage(startingAt: SessionMessagePage.latestStart(messageCount: transcript.messages.count), using: proxy)
                        }
                    }.font(.system(size: 10)).buttonStyle(.bordered)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Color.clear.frame(height: 1).id("session-page-top")
                        if !transcript.warnings.isEmpty {
                            SessionWarningsDisclosure(title: "会话读取提示", warnings: transcript.warnings,
                                                      initiallyExpanded: initiallyExpandedWarnings)
                        }
                        if transcript.messages.isEmpty {
                            MemoryEmptyState(icon: "text.alignleft", title: "未记录消息内容", detail: "会话日志可能只有元数据或尚未完成写入。")
                        }
                        ForEach(Array(transcript.messages.dropFirst(messageRangeStart).prefix(SessionMessagePage.size))) { message in
                            SessionMessageCard(message: message, relatedMessages: index?.relatedMessages(for: message) ?? [],
                                matchesSearch: !model.isFiltering && model.matchingUserMessageIDs.contains(message.id),
                                isExpanded: Binding(get: { expandedMessageIDs.contains(message.id) }, set: { expanded in
                                    if expanded { expandedMessageIDs.insert(message.id) }
                                    else { expandedMessageIDs.remove(message.id) }
                                }), onJump: { id in
                                    jump(to: id, in: transcript, using: proxy)
                                })
                                .id(message.id)
                        }
                    }.padding(.bottom, 12)
                }
            }
        }.id(transcript.summary.id)
    }

    private func jump(to id: String, in transcript: SessionTranscript, using proxy: ScrollViewProxy) {
        guard let index = model.transcriptIndex?.index(of: id) else { return }
        if index < messageRangeStart || index >= messageRangeStart + SessionMessagePage.size {
            messageRangeStart = SessionMessagePage.start(containing: index)
        }
        expandedMessageIDs.insert(id)
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
    }

    private func showPage(startingAt start: Int, using proxy: ScrollViewProxy) {
        messageRangeStart = start
        DispatchQueue.main.async { proxy.scrollTo("session-page-top", anchor: .top) }
    }

    private func tokenText(_ value: Int?) -> String {
        value.map { $0.formatted(.number.locale(Locale(identifier: "zh_CN"))) } ?? "未记录"
    }

    private func warning(_ message: String) -> some View {
        Text(message).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Large warning sets stay inside a bounded scroll area. The disclosure title
/// remains outside it, and transcript warnings stay below the fixed page controls.
private struct SessionWarningsDisclosure: View {
    let title: String
    let warnings: [String]
    @State private var isExpanded: Bool

    init(title: String, warnings: [String], initiallyExpanded: Bool = false) {
        self.title = title
        self.warnings = warnings
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup("\(title)（\(warnings.count)）", isExpanded: $isExpanded) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, message in
                        Text(message).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.vertical, 7)
            }.frame(height: min(120, max(40, CGFloat(warnings.count) * 26)))
        }.font(.system(size: 11)).foregroundStyle(MemoryStyle.orange)
    }
}

private struct SessionMessageCard: View {
    let message: SessionMessage
    let relatedMessages: [SessionMessage]
    let matchesSearch: Bool
    @Binding var isExpanded: Bool
    let onJump: (String) -> Void
    @State private var showFullText = false

    private var shortenedText: String { String(message.text.prefix(2_000)) }
    private var isLongText: Bool { message.text.utf8.count > 2_000 && shortenedText.utf8.count < message.text.utf8.count }

    private var isCollapsed: Bool {
        switch message.kind {
        case .toolCall, .toolResult, .reasoning, .system, .other: return true
        case .user, .assistant: return false
        }
    }

    private var roleTitle: String {
        switch message.kind {
        case .user: return "用户"
        case .assistant: return "Codex"
        case .toolCall: return "工具调用 · \(message.toolName ?? "名称未记录")"
        case .toolResult: return "工具结果"
        case .reasoning: return "思考记录"
        case .system: return "系统记录"
        case .other: return "其他记录"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCollapsed {
                DisclosureGroup(isExpanded: $isExpanded) {
                    content.padding(.top, 8)
                } label: { heading }
            } else {
                heading
                content
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(message.kind == .user ? MemoryStyle.accent.opacity(0.04) : MemoryStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(MemoryStyle.border))
    }

    private var heading: some View {
        HStack(spacing: 8) {
            Text(roleTitle).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(message.kind == .user ? MemoryStyle.accent : MemoryStyle.text)
            if matchesSearch { MemoryBadge(text: "搜索命中") }
            Spacer(minLength: 4)
            if let timestamp = message.timestamp {
                Text(MemoryFormat.time(timestamp)).font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let callID = message.callID {
                Text("调用 ID：\(callID)").font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                if relatedMessages.isEmpty {
                    Text(message.kind == .toolCall ? "日志中未找到对应工具结果。" : "日志中未找到对应工具调用。")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.orange)
                } else {
                    ForEach(Array(relatedMessages.enumerated()), id: \.offset) { _, related in
                        Button(message.kind == .toolCall ? "查看对应工具结果" : "查看对应调用：\(related.toolName ?? "工具名称未记录")") {
                            onJump(related.id)
                        }.font(.system(size: 10)).buttonStyle(.link)
                    }
                }
            }
            Text(message.text.isEmpty ? "（日志未记录文本）"
                 : (isLongText && !showFullText ? shortenedText + "\n…" : message.text))
                .font(.system(size: 12, design: message.kind == .toolCall || message.kind == .toolResult ? .monospaced : .default))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isLongText {
                Button(showFullText ? "收起长消息" : "展开全文") { showFullText.toggle() }
                    .font(.system(size: 10)).buttonStyle(.link)
            }
        }
    }
}
