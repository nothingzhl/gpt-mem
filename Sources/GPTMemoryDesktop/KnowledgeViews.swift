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
    @Bindable var model: KnowledgeDesktopModel
    let ai: DesktopAIModel
    let sessions: SessionDesktopModel
    let onOpenSessions: () -> Void
    @State private var sourceTab = false
    @State private var selected: String?
    @State private var checked: Set<String> = []
    @State private var extraction: ExtractionRequest?
    @State private var bundle: BundleRequest?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("记忆来源", selection: $sourceTab) { Text("我的记忆库").tag(false); Text("Codex 原始记忆").tag(true) }.pickerStyle(.segmented).frame(width: 370)
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
                Toggle("回收站", isOn: $model.showTrash)
                Spacer()
            }
            HStack {
                Button("预览并复用所选（\(checked.count)）") { bundle = .init(catalog: model.catalog, ids: checked) }.disabled(checked.isEmpty)
                Button("审核合并两条") { model.beginMerge(model.catalog.entries.filter { checked.contains($0.id) }) }.disabled(checked.count != 2 || model.isSaving || model.showTrash)
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
                                Text("\(entry.deletedAt == nil ? entry.current.scope.title : "回收站") · \(entry.current.state.title) · v\(entry.revision)").font(.caption).foregroundStyle(.secondary)
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
            Text("MEMORY.md 支持单条编辑和删除，确认后直接修改原文件并备份；其余文件只读。Codex 可能重新生成记忆，请避免与生成任务同时写入。").font(.caption).foregroundStyle(.secondary)
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
                        if source.relativePath == "MEMORY.md" { CodexOriginalControls(model: model, source: source) }
                        KnowledgeTextView(text: source.text, monospaced: true).equatable()
                    }.padding(12)
                } else { Text(model.isReadingSources ? "正在读取本地 Markdown 记忆…" : "选择文件查看；搜索覆盖已读取的正文").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(maxHeight: .infinity)
        }
    }
}

private struct KnowledgeEntryDetail: View {
    @Bindable var model: KnowledgeDesktopModel
    let entry: KnowledgeEntry
    @State private var version: Int?
    @State private var confirmDelete = false
    private var revision: KnowledgeRevision { entry.versions.first { $0.number == version } ?? entry.versions.last! }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.current.title).font(.title3)
            HStack {
                if entry.deletedAt != nil {
                    Button("恢复（删除前状态）") { Task { await model.trash(entry, restore: true) } }
                    Button("永久删除…", role: .destructive) { confirmDelete = true }
                } else {
                Button("编辑") { model.editor = .init(draft: entry.current, expected: entry) }
                Button(entry.current.state == .active ? "停用" : "审核启用") {
                    if entry.current.state == .active { Task { await model.changeState(entry, to: .disabled) } }
                    else { var draft = entry.current; draft.state = .active; model.editor = .init(draft: draft, expected: entry, reason: "审核启用") }
                }
                if entry.current.state == .archived {
                    Button("恢复为草稿") { Task { await model.changeState(entry, to: .draft) } }
                } else { Button("归档") { Task { await model.changeState(entry, to: .archived) } } }
                Button("移入回收站") { Task { await model.trash(entry) } }
                }
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
                }.disabled(model.isSaving || model.loadError != nil || entry.deletedAt != nil)
                Button("导出全部版本") { exportHistory() }
            }
            KnowledgeTextView(text: revision.draft.body).equatable()
            Text("保存时间：\(revision.savedAt.formatted())").font(.caption).foregroundStyle(.secondary)
            if !revision.draft.sources.isEmpty {
                ScrollView { VStack(alignment: .leading, spacing: 8) {
                    ForEach(revision.draft.sources) { source in Text("来源：\(source.origin.title) · \(source.label)\n\(source.locator)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
            }
        }.id(entry.id).onChange(of: entry.id) { _, _ in version = nil; confirmDelete = false }
        .alert("永久删除这条记忆？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) { Task { await model.trash(entry, permanently: true) } }
        } message: { Text("将删除“" + entry.current.title + "”及全部 " + String(entry.versions.count) + " 个版本，无法恢复。可以先导出全部版本。Codex 原始文件不受影响。") }
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
    @Bindable var model: KnowledgeDesktopModel
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
    private var count: Int { request.catalog.entries.filter { request.ids.contains($0.id) && $0.deletedAt == nil && $0.current.applies(project: project, session: session) }.count }
    var body: some View {
        let text = request.catalog.bundle(ids: request.ids, project: project, session: session)
        let oversized = text.utf8.count > 131_072
        VStack(alignment: .leading, spacing: 12) {
            Text("预览可复用记忆").font(.title2)
            TextField("目标项目绝对路径", text: $project).textFieldStyle(.roundedBorder)
            TextField("目标会话 ID（可选）", text: $session).textFieldStyle(.roundedBorder)
            Text("匹配 \(count) 条 / 所选 \(request.ids.count) 条；草稿、停用、归档或范围不匹配的条目不会复制。内容仅作为参考，请按当前事实核对。").font(.caption).foregroundStyle(.secondary)
            KnowledgeTextView(text: oversized ? "内容超过 128 KiB，请减少选择后再复用。" : (text.isEmpty ? "没有已启用且范围匹配的记忆" : text)).equatable()
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

private struct CodexOriginalRequest: Identifiable {
    let id = UUID()
    let source: KnowledgeSourceDocument
    let item: CodexMemoryItem
    let deleting: Bool
}
private struct CodexOriginalControls: View {
    @Bindable var model: KnowledgeDesktopModel
    let source: KnowledgeSourceDocument
    @State private var selectedItem: Int?
    @State private var request: CodexOriginalRequest?
    @State private var restore: CodexMemoryBackup?
    @State private var showBackups = false
    @State private var removingBackup: CodexMemoryBackup?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let items = source.items
            Picker("原始记忆条目", selection: $selectedItem) {
                Text("选择顶层列表项（\(items.count) 条）").tag(Optional<Int>.none)
                ForEach(items) { item in Text(item.label).tag(Optional(item.id)) }
            }
            HStack {
                if let item = items.first(where: { $0.id == selectedItem }) {
                    Button("编辑原始条目…") { request = .init(source: source, item: item, deleting: false) }
                    Button("删除原始条目…") { request = .init(source: source, item: item, deleting: true) }
                }
                Button("操作备份与恢复…") { Task { await model.loadOriginalBackups(); showBackups = true } }
            }.disabled(model.isSaving)
        }
        .onChange(of: source.text) { _, _ in selectedItem = nil }
        .sheet(item: $request) { request in CodexOriginalEditView(model: model, request: request) }
        .sheet(isPresented: $showBackups) {
            VStack(alignment: .leading, spacing: 12) {
                Text("MEMORY.md 操作备份").font(.title2)
                Text("仅当当前原文件与这次操作的结果完全一致时才允许回滚；恢复也会创建新备份。备份可能包含未成功写入的操作，请核对。最多保留 20 份，达到上限后停止修改；可导出后明确删除不再需要的备份。").font(.caption).foregroundStyle(.secondary)
                if let error = model.sourceError { Text(error).foregroundStyle(.orange) }
                List(model.originalBackups) { backup in
                    HStack {
                        Text(backup.createdAt.formatted() + " · " + backup.action + "\n" + backup.rootPath).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button("导出备份") { exportBackup(backup) }
                        Button("预览恢复…") { restore = backup }.disabled(model.isSaving || backup.rootPath != model.sourceRoot.standardizedFileURL.path)
                        Button("删除备份…") { removingBackup = backup }
                    }
                }
                HStack { Spacer(); Button("关闭") { showBackups = false } }
            }.padding(24).frame(width: 760, height: 520)
                        .alert("永久删除此操作备份？", isPresented: Binding(get: { removingBackup != nil }, set: { if !$0 { removingBackup = nil } })) {
                Button("取消", role: .cancel) { removingBackup = nil }
                Button("删除备份", role: .destructive) { if let backup = removingBackup { Task { await model.removeOriginalBackup(backup) } }; removingBackup = nil }
            } message: { Text("只删除选中的操作备份，原始记忆不变；此备份无法再恢复。建议先导出。") }
            .sheet(item: $restore) { backup in CodexOriginalRestoreView(model: model, backup: backup) }
        }
    }
    private func exportBackup(_ backup: CodexMemoryBackup) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "MEMORY-backup-" + backup.id + ".json"
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(backup).write(to: url, options: .atomic) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}
private struct CodexOriginalEditView: View {
    @Bindable var model: KnowledgeDesktopModel
    let request: CodexOriginalRequest
    @State private var draft: String
    @State private var preview: String?
    @State private var error: String?
    @State private var discard = false
    @Environment(\.dismiss) private var dismiss
    init(model: KnowledgeDesktopModel, request: CodexOriginalRequest) { self.model = model; self.request = request; _draft = State(initialValue: request.item.text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.deleting ? "删除 Codex 原始记忆条目" : "编辑 Codex 原始记忆条目").font(.title2)
            Text(request.source.fileURL.path).font(.caption).textSelection(.enabled)
            Text("只影响选中的列表项；确认后修改原始 MEMORY.md，备份整个文件。Codex 可能重新生成记忆，建议先结束相关生成任务。未同步修改摘要和历史来源，不能保证 Codex 后续不会再次学到相同内容。").font(.caption).foregroundStyle(.orange)
            Text(request.item.context).font(.headline)
            if !request.deleting { TextEditor(text: $draft).font(.system(size: 12, design: .monospaced)).frame(height: 140) }
            if let preview {
                Text("修改范围：\(request.item.text.utf8.count) 字节 → \(request.deleting ? 0 : draft.utf8.count) 字节；文件 \(request.source.text.utf8.count) → \(preview.utf8.count) 字节").font(.caption)
                HStack(alignment: .top) {
                    VStack(alignment: .leading) { Text("原条目").font(.caption); KnowledgeTextView(text: request.item.text).equatable() }
                    VStack(alignment: .leading) { Text("修改后").font(.caption); KnowledgeTextView(text: request.deleting ? "（移除此条目）" : draft).equatable() }
                }
            } else { Text("先预览这条记忆的前后差异，再确认写入。续行请缩进，不能加入其他顶层条目或标题。").foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("取消") { if draft != request.item.text { discard = true } else { dismiss() } }
                Spacer()
                if preview == nil {
                    Button("预览差异") { do { preview = try request.item.replacing(in: request.source.text, with: request.deleting ? nil : draft); error = nil } catch { self.error = error.localizedDescription } }
                } else {
                    Button(request.deleting ? "确认删除并备份" : "确认保存并备份") {
                        guard let preview else { return }
                        Task { if await model.editOriginal(source: request.source, replacement: preview, action: request.deleting ? "删除单条记忆" : "编辑单条记忆") { dismiss() } else { error = model.sourceError } }
                    }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(24).frame(width: 820, height: 650).disabled(model.isSaving).interactiveDismissDisabled()
        .onChange(of: draft) { _, _ in preview = nil }
        .confirmationDialog("放弃未保存的修改？", isPresented: $discard) { Button("放弃修改", role: .destructive) { dismiss() }; Button("继续编辑", role: .cancel) {} }
    }
}
private struct CodexOriginalRestoreView: View {
    @Bindable var model: KnowledgeDesktopModel
    let backup: CodexMemoryBackup
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认恢复原始 MEMORY.md").font(.title2)
            Text("恢复整个文件；当前内容必须与操作后的快照完全一致，否则拒绝覆盖。恢复前同样备份当前文件。").font(.caption).foregroundStyle(.orange)
            HStack {
                VStack(alignment: .leading) { Text("操作后（预期当前文件）").font(.caption); KnowledgeTextView(text: backup.after).equatable() }
                VStack(alignment: .leading) { Text("恢复为操作前").font(.caption); KnowledgeTextView(text: backup.before).equatable() }
            }
            if let error { Text(error).foregroundStyle(.orange) }
            HStack { Button("取消") { dismiss() }; Spacer(); Button("确认恢复并备份") { Task { if await model.restoreOriginal(backup) { dismiss() } else { error = model.sourceError } } }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 850, height: 650).disabled(model.isSaving).interactiveDismissDisabled()
    }
}

/// TextKit 2 lays out the visible viewport instead of asking SwiftUI to size and
/// render one enormous Text. Selection, copy, find, and the entire file remain native.
struct KnowledgeTextView: NSViewRepresentable, Equatable {
    let text: String
    var monospaced = false
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.monospaced == rhs.monospaced && lhs.text == rhs.text }
    final class Coordinator {
        var text: String?
        var monospaced: Bool?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.usesFindBar = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 5, height: 6)
        view.setAccessibilityLabel("记忆正文")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if context.coordinator.monospaced != monospaced {
            view.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
            view.textColor = .labelColor
            context.coordinator.monospaced = monospaced
        }
        guard context.coordinator.text != text else { return }
        context.coordinator.text = text
        view.string = text
        view.setSelectedRange(NSRange(location: 0, length: 0))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 500, height: proposal.height ?? 300)
    }
}
