import SwiftUI
import GPTSessionKit

/// A separate control keeps a star click from also opening its project or session.
struct SessionFavoriteButton: View {
    let isFavorite: Bool
    let targetLabel: String
    var isEnabled = true
    let action: () -> Void

    private var actionLabel: String { isFavorite ? "取消收藏" : "收藏" }

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 13)).foregroundStyle(isFavorite ? MemoryStyle.orange : MemoryStyle.secondary)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!isEnabled)
            .help(actionLabel).accessibilityLabel("\(actionLabel)：\(targetLabel)")
            .accessibilityValue(isFavorite ? "已收藏" : "未收藏")
    }
}

struct SessionManagementStatus: View {
    @ObservedObject var model: SessionManagementModel
    var showsWriteError = true

    var body: some View {
        if model.isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在读取本地收藏、标签与备注…")
            }.font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
        } else if model.isSaving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在保存本地管理信息…")
            }.font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
        } else if let error = model.errorMessage, !model.hasLoaded || showsWriteError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(MemoryStyle.orange)
                Text(error).font(.system(size: 11)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !model.hasLoaded {
                    Button("重新读取") { model.refresh() }
                } else if model.hasPendingRetry {
                    Button("重试保存") { model.retryLastMutation() }
                }
                if model.hasLoaded {
                    Button { model.dismissError() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭管理信息提示")
                }
            }.font(.system(size: 11)).padding(10)
                .background(MemoryStyle.orange.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The original target and draft stay fixed while the catalog refreshes behind this sheet.
struct SessionMetadataEditor: View {
    @ObservedObject var model: SessionDesktopModel
    let summary: CodexSessionSummary
    @Environment(\.dismiss) private var dismiss
    @State private var localTitle: String
    @State private var note: String
    @State private var baseline: SessionManagementEntry
    @State private var isSubmitting = false
    @State private var isReloadingDraft = false
    @State private var saveError: String?
    @State private var hasMergedLatest = false
    @State private var didSave = false

    init(model: SessionDesktopModel, summary: CodexSessionSummary) {
        self.model = model
        self.summary = summary
        _localTitle = State(initialValue: model.localTitle(for: summary))
        _note = State(initialValue: model.note(for: summary))
        _baseline = State(initialValue: model.management.index.entry(for: summary)
                          ?? .init(kind: .session, itemID: summary.managementID))
    }

    private var isBusy: Bool { isSubmitting || isReloadingDraft || model.management.isSaving || model.management.isLoading }
    private var maySave: Bool { model.management.hasLoaded && !isBusy && !model.isLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本地名称与备注").font(.system(size: 18, weight: .semibold))
            Text("只更改 GPT Manager 中的显示名称和备注。收藏状态与原始会话日志保留。")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("日志原名：\(summary.title)").font(.system(size: 11)).textSelection(.enabled).lineLimit(3)
                Text("会话 ID：\(summary.sessionID)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("本地名称").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("恢复原名") { localTitle = ""; saveError = nil }
                        .buttonStyle(.link).disabled(isBusy || localTitle.isEmpty)
                }
                TextField(summary.title, text: $localTitle).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("本地名称").disabled(isBusy)
                Text("留空并保存后使用日志原名 · \(localTitle.count)/\(SessionManagementStore.maximumDisplayNameCharacters) 字")
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("本地备注").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(note.count)/\(SessionManagementStore.maximumNoteCharacters) 字")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }
                TextEditor(text: $note).font(.system(size: 12)).scrollContentBackground(.hidden)
                    .padding(7).frame(height: 145).background(MemoryStyle.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MemoryStyle.border))
                    .accessibilityLabel("本地备注").disabled(isBusy)
            }
            if let saveError {
                VStack(alignment: .leading, spacing: 7) {
                    Text(saveError).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("合并最新管理信息") { mergeLatest() }.disabled(isBusy)
                    Text("保留你修改的字段，其余字段使用最新值；检查后再次保存。")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }
            } else if hasMergedLatest {
                Text("已合并最新信息，你的修改仍保留。请检查后保存。")
                    .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            }
            HStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text(isReloadingDraft || model.management.isLoading ? "正在读取…" : "正在保存…").font(.system(size: 11))
                }
                Spacer()
                Button("取消") { cancel() }.keyboardShortcut(.cancelAction).disabled(isBusy)
                Button(saveError == nil ? "保存" : "重试保存") { save() }
                    .keyboardShortcut(.defaultAction).disabled(!maySave)
            }
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(isBusy)
            .onDisappear {
                if !didSave && !isSubmitting {
                    model.discardFailedSessionMetadata(summary)
                }
            }
    }

    private func save() {
        guard maySave else { return }
        isSubmitting = true
        saveError = nil
        let submittedTitle = localTitle
        let submittedNote = note
        let submittedBaseline = baseline
        Task { @MainActor in
            let saved = await model.saveSessionMetadata(summary, title: submittedTitle, note: submittedNote, baseline: submittedBaseline)
            isSubmitting = false
            if saved { didSave = true; dismiss() }
            else { saveError = model.management.errorMessage ?? "保存未完成。输入仍保留，可以重试。" }
        }
    }

    private func cancel() {
        guard !isBusy else { return }
        model.discardFailedSessionMetadata(summary)
        dismiss()
    }

    private func mergeLatest() {
        guard !isBusy else { return }
        // Normalize like storage when deciding what the user actually changed.
        // A blank title/note is a clear operation, not a new whitespace value.
        let changedTitle = normalizedTitle(localTitle) != baseline.displayName
        let changedNote = normalizedNote(note) != baseline.note
        isReloadingDraft = true
        Task { @MainActor in
            let loaded = await model.management.reload()
            isReloadingDraft = false
            guard loaded else {
                saveError = model.management.errorMessage ?? "未能读取最新信息。你的输入仍保留，请稍后重试。"
                return
            }
            let latest = model.management.index.entry(for: summary)
                ?? .init(kind: .session, itemID: summary.managementID)
            if !changedTitle { localTitle = latest.displayName ?? "" }
            if !changedNote { note = latest.note ?? "" }
            baseline = latest
            saveError = nil
            hasMergedLatest = true
        }
    }

    private func normalizedTitle(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedNote(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}

struct ProjectTagChip: View {
    let tag: String

    var body: some View {
        Text(tag).font(.system(size: 9, weight: .medium)).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(MemoryStyle.accent).background(MemoryStyle.accentBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5)).help(tag)
    }
}

/// Project tags are saved as one field. A conflict offers an explicit choice
/// between the new field value and the frozen local draft before another save.
struct ProjectTagsEditor: View {
    @ObservedObject var model: SessionDesktopModel
    let project: SessionProjectSummary
    @Environment(\.dismiss) private var dismiss
    @State private var tagsInput: String
    @State private var baseline: SessionManagementEntry
    @State private var latestEntry: SessionManagementEntry?
    @State private var isSubmitting = false
    @State private var isReadingLatest = false
    @State private var saveError: String?
    @State private var hasStorageError = false
    @State private var recoveryNotice: String?
    @State private var didSave = false

    init(model: SessionDesktopModel, project: SessionProjectSummary) {
        self.model = model
        self.project = project
        let initial = model.management.index.entryForProject(project.id)
            ?? .init(kind: .project, itemID: SessionManagementIndex.projectID(project.id))
        _baseline = State(initialValue: initial)
        _tagsInput = State(initialValue: initial.tags.joined(separator: ", "))
    }

    private var isBusy: Bool { isSubmitting || isReadingLatest || model.management.isSaving || model.management.isLoading }
    private var maySave: Bool { model.management.hasLoaded && !isBusy && !model.isLoading && latestEntry == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("项目标签").font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text(project.displayName).font(.system(size: 12, weight: .medium))
                Text(project.projectPath ?? "未记录项目目录").font(.system(size: 10))
                    .foregroundStyle(MemoryStyle.secondary).textSelection(.enabled).lineLimit(2)
            }
            Text("给项目添加标签，方便在项目、会话和统计中筛选。标签保存在本机，原始日志只读。")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("标签").font(.system(size: 12, weight: .medium))
                TextEditor(text: $tagsInput).font(.system(size: 12)).scrollContentBackground(.hidden)
                    .padding(7).frame(height: 100).background(MemoryStyle.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MemoryStyle.border))
                    .accessibilityLabel("项目标签输入").disabled(isBusy)
                Text("用英文逗号、中文逗号或换行分隔，例如：工作, 学习, 工具。")
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                Text("最多 \(SessionManagementStore.maximumTags) 个标签，每个最多 \(SessionManagementStore.maximumTagCharacters) 字、\(SessionManagementStore.maximumTagBytes) 字节；留空保存可清除标签。")
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }
            if !model.availableProjectTags.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("快捷添加标签").font(.system(size: 11, weight: .medium))
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(Array(model.availableProjectTags.prefix(48)), id: \.self) { tag in
                                Button { addTag(tag) } label: {
                                    Text(tag).font(.system(size: 10)).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.disabled(isBusy).help(tag).accessibilityLabel("添加标签：\(tag)")
                            }
                        }
                    }.frame(maxHeight: 85)
                    if model.availableProjectTags.count > 48 {
                        Text("更多标签可直接输入。")
                            .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                    }
                }
            }
            if let latestEntry {
                recoveryChoice(latestEntry)
            } else if let saveError {
                VStack(alignment: .leading, spacing: 7) {
                    Text(saveError).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if hasStorageError {
                        Button("读取最新标签（保留草稿）") { readLatest() }.disabled(isBusy)
                    }
                }
            } else if let recoveryNotice {
                Text(recoveryNotice).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            }
            HStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text(isReadingLatest || model.management.isLoading ? "正在读取…" : "正在保存…")
                        .font(.system(size: 11))
                }
                Spacer()
                Button("取消") { cancel() }.keyboardShortcut(.cancelAction).disabled(isBusy)
                Button(saveError == nil ? "保存" : "重试保存") { save() }
                    .keyboardShortcut(.defaultAction).disabled(!maySave)
            }
        }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(isBusy)
            .onDisappear {
                if !didSave && !isSubmitting { model.discardFailedProjectTags(project.id) }
            }
            .onChange(of: tagsInput) { _, _ in
                if !hasStorageError { saveError = nil }
            }
    }

    private func recoveryChoice(_ latest: SessionManagementEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最新标签：\(latest.tags.isEmpty ? "未设置" : latest.tags.joined(separator: ", "))")
                .font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("标签按整组保存。选择使用最新标签，或保留草稿以替换最新标签；随后点击保存。")
                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            HStack(spacing: 10) {
                Button("使用最新标签") { resolveConflict(using: latest, keepDraft: false) }.disabled(isBusy)
                Button("保留草稿继续保存") { resolveConflict(using: latest, keepDraft: true) }.disabled(isBusy)
            }.font(.system(size: 11))
        }.padding(10).background(MemoryStyle.accentBackground).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rawTags() -> [String] {
        tagsInput.components(separatedBy: CharacterSet(charactersIn: ",，\n\r"))
    }

    private func addTag(_ tag: String) {
        guard !isBusy else { return }
        do {
            let tags = try SessionManagementStore.normalizedTags(rawTags() + [tag])
            tagsInput = tags.joined(separator: ", ")
            if !hasStorageError { saveError = nil }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func save() {
        guard maySave else { return }
        let tags: [String]
        do { tags = try SessionManagementStore.normalizedTags(rawTags()) }
        catch { saveError = error.localizedDescription; return }
        let submittedBaseline = baseline
        isSubmitting = true
        saveError = nil
        recoveryNotice = nil
        Task { @MainActor in
            let saved = await model.saveProjectTags(project.id, tags: tags, baseline: submittedBaseline)
            isSubmitting = false
            if saved { didSave = true; dismiss() }
            else {
                hasStorageError = true
                saveError = model.management.errorMessage ?? "保存未完成。标签草稿仍保留，可以重试。"
            }
        }
    }

    private func readLatest() {
        guard !isBusy else { return }
        isReadingLatest = true
        Task { @MainActor in
            let loaded = await model.management.reload()
            isReadingLatest = false
            guard loaded else {
                saveError = model.management.errorMessage ?? "未能读取最新标签，草稿仍保留。"
                return
            }
            latestEntry = model.management.index.entryForProject(project.id)
                ?? .init(kind: .project, itemID: SessionManagementIndex.projectID(project.id))
        }
    }

    private func resolveConflict(using latest: SessionManagementEntry, keepDraft: Bool) {
        guard !isBusy else { return }
        if !keepDraft { tagsInput = latest.tags.joined(separator: ", ") }
        baseline = latest
        latestEntry = nil
        saveError = nil
        hasStorageError = false
        recoveryNotice = keepDraft ? "草稿仍保留。保存将用这组标签替换最新标签。" : "已使用最新标签，请检查后保存。"
    }

    private func cancel() {
        guard !isBusy else { return }
        model.discardFailedProjectTags(project.id)
        dismiss()
    }
}
