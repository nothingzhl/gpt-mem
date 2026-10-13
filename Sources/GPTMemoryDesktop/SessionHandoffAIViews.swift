import SwiftUI
import GPTAnalysisKit
import GPTSessionKit

/// The session module has its own live result state, sharing sources and durable report storage.
struct SessionHandoffAIControls: View {
    @ObservedObject var model: DesktopAIModel
    let transcript: SessionTranscript
    @Binding var draft: String
    @State private var context = ""
    @State private var preparedInput: AIAnalysisInput?
    @State private var localError: String?
    @State private var previousDraft: String?

    private var matchingRecord: AIAnalysisRecord? {
        guard let record = model.record, let input = preparedInput,
              model.recordInput == input, input.context == context,
              input.prompt == (try? model.appliedPrompt(for: SessionHandoffAIModule.moduleID)) else { return nil }
        return record
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("AI 来源", selection: Binding(get: { model.settings.selectedProviderID }, set: { _ = model.selectProvider($0) })) {
                    Text("请选择来源").tag(Optional<UUID>.none)
                    ForEach(model.settings.providers) { Text("\($0.name) · \($0.model)").tag(Optional($0.id)) }
                }.disabled(model.isAnalyzing)
                Button("重新读取来源") { model.reloadSettings() }.disabled(model.isAnalyzing)
                if model.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Button("取消生成") { model.cancelAnalysis() }
                } else {
                    Button("从会话摘录生成 AI 交接") { prepare() }
                        .disabled(model.selectedProvider == nil || model.configurationError != nil)
                }
            }
            PromptTemplateSelectionControls(model: model, moduleID: SessionHandoffAIModule.moduleID)
            TextField("补充目标与约束（可选，确认后随摘录发送）", text: $context).textFieldStyle(.roundedBorder)
                .disabled(model.isAnalyzing)
            Text("先预览有限的真实消息摘录再发送；不读取工具输出、本地备注或编辑器内容。生成结果自动保存到 AI 报告库。")
                .font(.caption).foregroundStyle(.secondary)
            if model.selectedProvider == nil { Text("请先到设置添加 AI 来源，再重新读取来源。 ").font(.caption).foregroundStyle(.orange) }
            if let error = localError ?? model.configurationError ?? model.analysisError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let error = model.reportSaveError {
                Text(error).font(.caption).foregroundStyle(.orange)
                Button("重试保存报告") { model.reportLibrary.retrySave() }.font(.caption)
            }
            if let record = matchingRecord, let input = model.recordInput {
                HStack {
                    Text(record.result.summary).font(.caption).lineLimit(2)
                    Spacer()
                    Button("载入 AI 交接结果") {
                        previousDraft = draft
                        draft = SessionHandoffAIModule.markdown(record: record, input: input, subjectLabels: model.recordSubjectLabels)
                    }
                }
            }
            if let previousDraft {
                Button("恢复载入前的编辑内容") { draft = previousDraft; self.previousDraft = nil }.font(.caption)
            }
        }
        .task {
            model.reloadSettings()
            await model.configurePrompt(for: SessionHandoffAIModule.moduleID)
            preparedInput = try? SessionHandoffAIModule(transcript: transcript).input.applying(
                prompt: model.appliedPrompt(for: SessionHandoffAIModule.moduleID))
        }
        .sheet(item: $model.preview) { preview in
            AIAnalysisPreviewView(model: model, prepared: preview)
        }
    }

    private func prepare() {
        let frozenContext = context
        Task { @MainActor in
            localError = nil
            model.reloadSettings()
            await model.configurePrompt(for: SessionHandoffAIModule.moduleID)
            do {
                let module = try SessionHandoffAIModule(transcript: transcript, context: frozenContext)
                model.prepare(module: module, subjectLabels: module.subjectLabels,
                              windowSelectionSeconds: max(1, min(31_536_000, module.input.windowEnd.timeIntervalSince(module.input.windowStart))))
                preparedInput = model.preview?.input
            } catch { localError = error.localizedDescription }
        }
    }

}

struct SessionHandoffBackgroundStatus: View {
    @ObservedObject var model: DesktopAIModel
    var body: some View {
        if model.isAnalyzing {
            HStack {
                ProgressView().controlSize(.small)
                Text("AI 交接正在后台生成，完成后保存到报告库。")
                Button("取消生成") { model.cancelAnalysis() }
            }.font(.caption)
        } else if let error = model.analysisError ?? model.reportSaveError {
            HStack {
                Text(error).foregroundStyle(.orange)
                if model.reportSaveError != nil { Button("重试保存") { model.reportLibrary.retrySave() } }
            }.font(.caption)
        } else if model.record?.moduleID == SessionHandoffAIModule.moduleID {
            Text(model.reportLibrary.isSaving ? "AI 交接已生成，正在保存…" : "AI 交接已生成，可到 AI 报告库选择“会话交接”查看历史结果。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
