import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GPTAnalysisKit
import GPTSessionKit

struct KnowledgeWorkspaceHost: View, Equatable {
    let model: KnowledgeDesktopModel
    let ai: DesktopAIModel
    let sessions: SessionDesktopModel
    let onOpenSessions: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.ai === rhs.ai && lhs.sessions === rhs.sessions }
    var body: some View { KnowledgeWorkspace(model: model, ai: ai, sessions: sessions, onOpenSessions: onOpenSessions) }
}
private struct ExtractionRequest: Identifiable { let id = UUID(); let transcript: SessionTranscript }
private struct BundleRequest: Identifiable { let id = UUID(); let catalog: KnowledgeCatalog; let ids: Set<String> }

struct KnowledgeWorkspace: View {
    @ObservedObject var model: KnowledgeDesktopModel
    @ObservedObject var ai: DesktopAIModel
    @ObservedObject var sessions: SessionDesktopModel
    let onOpenSessions: () -> Void
    @State private var sourceTab = false
    @State private var selected: String?
    @State private var checked: Set<String> = []
    @State private var extraction: ExtractionRequest?
    @State private var bundle: BundleRequest?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("记忆来源", selection: $sourceTab) { Text("我的记忆库").tag(false); Text("Codex 本地记忆（只读）").tag(true) }.pickerStyle(.segmented).frame(width: 370)
                Spacer()
                Button("刷新") { Task { if sourceTab { await model.readSources() } else { await model.reload() } } }.disabled(model.isLoading || model.isReadingSources)
                Button("新建记忆") { model.editor = .init(draft: .init(), expected: nil) }.disabled(!model.hasLoaded || model.loadError != nil)
            }
            HStack {
                TextField("搜索标题、正文和来源", text: $model.query).textFieldStyle(.roundedBorder)
                TextField(sourceTab ? "正文中的项目关键词" : "项目路径筛选", text: $model.projectFilter).textFieldStyle(.roundedBorder).frame(width: 220)
                if model.isFiltering { ProgressView().controlSize(.small) }
            }
            if let error = model.loadError ?? model.operationError ?? model.sourceError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let status = model.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if sourceTab { sources } else { library }
        }
        .task { await model.loadIfNeeded() }
        .onChange(of: sourceTab) { _, value in selected = nil; if value { Task { await model.readSources() } } }
        .sheet(item: $model.editor) { request in KnowledgeEditor(model: model, request: request) }
        .sheet(item: $bundle) { request in KnowledgeBundleView(request: request) }
        .sheet(item: $extraction) { request in
            KnowledgeExtractionView(ai: ai, transcript: request.transcript) { draft in
                extraction = nil
                // Present the review editor only after the extraction sheet dismisses.
                Task { @MainActor in try? await Task.sleep(nanoseconds: 250_000_000); model.editor = .init(draft: draft, expected: nil) }
            }
        }
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("状态", selection: $model.stateFilter) { Text("全部状态").tag(Optional<KnowledgeState>.none); ForEach(KnowledgeState.allCases, id: \.self) { Text($0.title).tag(Optional($0)) } }.frame(width: 190)
                Picker("来源", selection: $model.originFilter) { Text("全部来源").tag(Optional<KnowledgeOrigin>.none); ForEach(KnowledgeOrigin.allCases, id: \.self) { Text($0.title).tag(Optional($0)) } }.frame(width: 190)
                Toggle("含归档", isOn: $model.includeArchived)
                Spacer()
            }
            HStack {
                Button("预览并复用所选（\(checked.count)）") { bundle = .init(catalog: model.catalog, ids: checked) }.disabled(checked.isEmpty)
                Button("审核合并两条") { model.beginMerge(model.catalog.entries.filter { checked.contains($0.id) }) }.disabled(checked.count != 2 || model.isSaving)
                Spacer()
                Button("从已打开会话提取") { if let transcript = sessions.transcript { extraction = .init(transcript: transcript) } else { onOpenSessions() } }
            }
            Text("仅已启用且匹配范围的记忆可复用。提取前请到 Codex 工作区打开会话；所有 AI 草稿须人工审核，不会自动同步到 Codex 或 ChatGPT。")
                .font(.caption).foregroundStyle(.secondary)
            HSplitView {
                List(selection: $selected) {
                    ForEach(model.filteredEntries) { entry in
                        HStack(alignment: .top) {
                            Toggle("选择 \(entry.current.title)", isOn: Binding(get: { checked.contains(entry.id) }, set: { if $0 { checked.insert(entry.id) } else { checked.remove(entry.id) } })).labelsHidden()
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.current.title).fontWeight(.medium)
                                Text("\(entry.current.scope.title) · \(entry.current.state.title) · v\(entry.revision)").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).tag(entry.id)
                    }
                }.frame(minWidth: 260, idealWidth: 310, maxWidth: 390)
                if let entry = model.catalog.entries.first(where: { $0.id == selected }) {
                    KnowledgeEntryDetail(model: model, entry: entry).padding(12)
                } else {
                    VStack(spacing: 12) { Text(model.catalog.entries.isEmpty ? "还没有自己的记忆" : "选择一条记忆查看正文和历史版本").font(.title3); Text("可以人工创建，或从 Codex 记忆和会话中导入待审核草稿。").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxHeight: .infinity)
        }
    }
    private var sources: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.sourceRoot.path).font(.caption).textSelection(.enabled)
                Spacer()
                Button("选择记忆目录") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let root = panel.url { Task { await model.readSources(root: root) } }
                }.disabled(model.isReadingSources)
                if model.isReadingSources { ProgressView().controlSize(.small) }
            }
            Text("文件保持只读；导入会创建 GPT Manager 的独立草稿。文件中的历史指令是资料，导入不会执行它们。").font(.caption).foregroundStyle(.secondary)
            if !model.sourceCatalog.warnings.isEmpty {
                DisclosureGroup("读取提示（\(model.sourceCatalog.warnings.count)）") { Text(model.sourceCatalog.warnings.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
            }
            HSplitView {
                List(selection: $selected) {
                    ForEach(model.filteredSources) { source in
                        VStack(alignment: .leading, spacing: 4) { Text(source.title).lineLimit(2); Text(source.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(2) }.padding(.vertical, 5).tag(source.id)
                    }
                }.frame(minWidth: 260, idealWidth: 310, maxWidth: 390)
                if let source = model.sourceCatalog.documents.first(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(source.title).font(.title3); Spacer(); Button("导入副本并审核") { model.editor = .init(draft: source.importedDraft(), expected: nil) }.disabled(model.loadError != nil) }
                        ScrollView { Text(source.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding(12)
                } else { Text(model.isReadingSources ? "正在读取本地 Markdown 记忆…" : "选择文件查看；搜索覆盖已读取的正文").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(maxHeight: .infinity)
        }
    }
}

private struct KnowledgeEntryDetail: View {
    @ObservedObject var model: KnowledgeDesktopModel
    let entry: KnowledgeEntry
    @State private var version: Int?
    private var revision: KnowledgeRevision { entry.versions.first { $0.number == version } ?? entry.versions.last! }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.current.title).font(.title3)
            HStack {
                Button("编辑") { model.editor = .init(draft: entry.current, expected: entry) }
                Button(entry.current.state == .active ? "停用" : "审核启用") {
                    if entry.current.state == .active { Task { await model.changeState(entry, to: .disabled) } }
                    else { var draft = entry.current; draft.state = .active; model.editor = .init(draft: draft, expected: entry, reason: "审核启用") }
                }
                if entry.current.state == .archived {
                    Button("恢复为草稿") { Task { await model.changeState(entry, to: .draft) } }
                } else { Button("归档") { Task { await model.changeState(entry, to: .archived) } } }
            }.disabled(model.isSaving || model.loadError != nil)
            Text("\(entry.current.scope.title) · \(entry.current.projectPath) \(entry.current.sessionID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Picker("完整版本", selection: $version) {
                    Text("当前版本").tag(Optional<Int>.none)
                    ForEach(entry.versions.reversed()) { Text("v\($0.number) · \($0.reason)").tag(Optional($0.number)) }
                }
                Button("以此版本创建恢复草稿") {
                    var draft = revision.draft; draft.state = .draft
                    model.editor = .init(draft: draft, expected: entry, reason: "恢复自 v\(revision.number)")
                }.disabled(model.isSaving || model.loadError != nil)
                Button("导出全部版本") { exportHistory() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(revision.draft.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Text("保存时间：\(revision.savedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                    ForEach(revision.draft.sources) { source in Text("来源：\(source.origin.title) · \(source.label)\n\(source.locator)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }.id(entry.id).onChange(of: entry.id) { _, _ in version = nil }
    }
    private func exportHistory() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "memory-history.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(entry).write(to: url, options: .atomic) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}

private struct KnowledgeEditor: View {
    @ObservedObject var model: KnowledgeDesktopModel
    let request: KnowledgeEditRequest
    @State private var draft: KnowledgeDraft
    @State private var error: String?
    @State private var discard = false
    @Environment(\.dismiss) private var dismiss
    init(model: KnowledgeDesktopModel, request: KnowledgeEditRequest) { self.model = model; self.request = request; _draft = State(initialValue: request.draft) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.mergeSource == nil ? "审核记忆" : "审核合并记忆").font(.title2)
            Text("保存到 GPT Manager；草稿不会用于复用。启用前请核对正文、范围和来源。").font(.caption).foregroundStyle(.secondary)
            TextField("标题（最多 120 字）", text: $draft.title).textFieldStyle(.roundedBorder)
            HStack {
                Picker("范围", selection: $draft.scope) { ForEach(KnowledgeScope.allCases, id: \.self) { Text($0.title).tag($0) } }.disabled(request.mergeSource != nil)
                Picker("状态", selection: $draft.state) { ForEach(KnowledgeState.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            if draft.scope != .personal { TextField("项目绝对路径（会话范围可留空）", text: $draft.projectPath).textFieldStyle(.roundedBorder).disabled(request.mergeSource != nil) }
            if draft.scope == .session { TextField("会话 ID", text: $draft.sessionID).textFieldStyle(.roundedBorder).disabled(request.mergeSource != nil) }
            TextEditor(text: $draft.body).font(.system(size: 13)).frame(minHeight: 220).border(Color.secondary.opacity(0.2))
            Text("正文 \(draft.body.utf8.count) / 32768 字节 · 修改和状态变化都会保留完整版本").font(.caption).foregroundStyle(.secondary)
            if !model.catalog.duplicates(of: draft).isEmpty { Text("同范围存在相同正文，建议先返回列表选择两条并审核合并。").font(.caption).foregroundStyle(.orange) }
            if !draft.sources.isEmpty { DisclosureGroup("来源（\(draft.sources.count)）") { ScrollView { ForEach(draft.sources) { Text("\($0.label)\n\($0.locator)").font(.caption).textSelection(.enabled) } }.frame(maxHeight: 90) } }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("取消") { if draft != request.draft { discard = true } else { dismiss() } }
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button("保存审核结果") {
                    do { try draft.validate(); var save = request; save.draft = draft; error = nil; Task { if await model.save(save) { dismiss() } else { error = model.operationError } } }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 700, height: 650).disabled(model.isSaving)
        .interactiveDismissDisabled()
        .onChange(of: draft.scope) { _, scope in if scope == .personal { draft.projectPath = "" }; if scope != .session { draft.sessionID = "" } }
        .confirmationDialog("放弃未保存的修改？", isPresented: $discard) { Button("放弃修改", role: .destructive) { dismiss() }; Button("继续编辑", role: .cancel) {} }
    }
}

private struct KnowledgeBundleView: View {
    let request: BundleRequest
    @State private var project = ""
    @State private var session = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var text: String { request.catalog.bundle(ids: request.ids, project: project, session: session) }
    private var oversized: Bool { text.utf8.count > 131_072 }
    private var count: Int { request.catalog.entries.filter { request.ids.contains($0.id) && $0.current.applies(project: project, session: session) }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预览可复用记忆").font(.title2)
            TextField("目标项目绝对路径", text: $project).textFieldStyle(.roundedBorder)
            TextField("目标会话 ID（可选）", text: $session).textFieldStyle(.roundedBorder)
            Text("匹配 \(count) 条 / 所选 \(request.ids.count) 条；草稿、停用、归档或范围不匹配的条目不会复制。内容仅作为参考，请按当前事实核对。").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(oversized ? "内容超过 128 KiB，请减少选择后再复用。" : (text.isEmpty ? "没有已启用且范围匹配的记忆" : text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button("关闭") { dismiss() }; Spacer()
                Button("导出 Markdown") {
                    let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "reference-memories.md"
                    if panel.runModal() == .OK, let url = panel.url { do { try Data(text.utf8).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription } }
                }.disabled(text.isEmpty || oversized)
                Button("复制参考记忆") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }.disabled(text.isEmpty || oversized)
            }
        }.padding(24).frame(width: 720, height: 580)
    }
}
