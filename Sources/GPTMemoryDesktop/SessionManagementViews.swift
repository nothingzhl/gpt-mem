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
                Text("正在读取本地收藏与备注…")
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
