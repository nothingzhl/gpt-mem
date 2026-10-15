import SwiftUI
import GPTAnalysisKit
import GPTSessionKit

/// Draft IDs must survive view updates. Rebuilding candidates in a computed
/// property regenerated UUIDs and validated the same report several times.
final class KnowledgeExtractionCandidateCache {
    struct Output { var drafts: [KnowledgeDraft] = []; var error: String? }
    private struct Key: Equatable {
        let prepared: AIAnalysisInput?
        let input: AIAnalysisInput?
        let record: AIAnalysisRecord?
        let source: CodexSessionSummary
        let labels: [String: String]
        let context: String
        let prompt: AIAnalysisPrompt?
    }
    private var key: Key?
    private var output = Output()
    func evaluate(prepared: AIAnalysisInput?, input: AIAnalysisInput?, record: AIAnalysisRecord?, source: CodexSessionSummary,
                  labels: [String: String], context: String, prompt: AIAnalysisPrompt?) -> Output {
        let next = Key(prepared: prepared, input: input, record: record, source: source, labels: labels, context: context, prompt: prompt)
        guard key != next else { return output }
        key = next; output = .init()
        guard let prepared, prepared == input, let record else { return output }
        do {
            let drafts = try KnowledgeExtractionModule.drafts(record: record, input: prepared, source: source, subjectLabels: labels)
            if prepared.context == context && prepared.prompt == prompt { output.drafts = drafts }
        } catch { output.error = "候选校验失败，不能入库：" + error.localizedDescription }
        return output
    }
}

struct KnowledgeExtractionView: View {
    @ObservedObject var ai: DesktopAIModel
    let transcript: SessionTranscript
    let onReview: (KnowledgeDraft) -> Void
    @State private var context = ""
    @State private var preparedInput: AIAnalysisInput?
    @State private var error: String?
    @State private var candidateCache = KnowledgeExtractionCandidateCache()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let candidates = candidateCache.evaluate(prepared: preparedInput, input: ai.recordInput, record: ai.record,
            source: transcript.summary, labels: ai.recordSubjectLabels, context: context,
            prompt: try? ai.appliedPrompt(for: KnowledgeExtractionModule.moduleID))
        VStack(alignment: .leading, spacing: 12) {
            Text("从会话提取长期记忆草稿").font(.title2)
            Text(transcript.summary.title).font(.headline)
            Text("首条用户需求和最近 20 条用户/助手消息，工具输出和思考记录不发送。发送前可以查看真实摘录；生成报告与记忆入库是两个独立步骤。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("AI 来源", selection: Binding(get: { ai.settings.selectedProviderID }, set: { _ = ai.selectProvider($0) })) {
                    Text("请选择来源").tag(Optional<UUID>.none)
                    ForEach(ai.settings.providers) { Text("\($0.name) · \($0.model)").tag(Optional($0.id)) }
                }
                Button("重新读取来源") { ai.reloadSettings() }
            }.disabled(ai.isAnalyzing)
            PromptTemplateSelectionControls(model: ai, moduleID: KnowledgeExtractionModule.moduleID)
            TextField("本次提取重点（可选，随摘录发送）", text: $context).textFieldStyle(.roundedBorder).disabled(ai.isAnalyzing)
            HStack {
                Button("预览摘录并提取") { prepare() }.disabled(ai.isAnalyzing || ai.selectedProvider == nil || ai.configurationError != nil)
                if ai.isAnalyzing { ProgressView().controlSize(.small); Button("取消生成") { ai.cancelAnalysis() } }
                Spacer()
            }
            if let error = error ?? ai.configurationError ?? ai.analysisError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let candidateError = candidates.error { Text(candidateError).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            AIReportSaveStatus(model: ai.reportLibrary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let input = preparedInput, ai.recordInput == input, let record = ai.record {
                        Text(record.result.summary).textSelection(.enabled)
                        Text("生成来源：\(record.providerName) · \(record.model) · \(record.generatedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                        if candidates.drafts.isEmpty { Text("没有可入库候选，或提取条件已变化；可以重新预览提取。").foregroundStyle(.secondary) }
                        ForEach(candidates.drafts) { draft in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(draft.body).textSelection(.enabled)
                                Text(draft.sources.first?.label ?? "").font(.caption).foregroundStyle(.secondary)
                                Button("审核这条草稿") { onReview(draft) }.buttonStyle(.bordered)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        ForEach(Array(record.result.hypotheses.enumerated()), id: \.offset) { _, item in Text("待确认：\(item.title)\n\(item.explanation)").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                        Text(record.result.limitations.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                    } else { Text("尚未生成。AI 返回的内容不会自动写入记忆库，审核时默认保存为草稿。").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("关闭") { dismiss() } }
        }.padding(24).frame(width: 760, height: 680)
        .task {
            ai.reloadSettings(); await ai.configurePrompt(for: KnowledgeExtractionModule.moduleID)
            if let record = ai.record, let input = ai.recordInput,
               (try? KnowledgeExtractionModule.drafts(record: record, input: input, source: transcript.summary, subjectLabels: ai.recordSubjectLabels)) != nil {
                preparedInput = input; context = input.context
            } else {
                preparedInput = try? KnowledgeExtractionModule(transcript: transcript).input.applying(prompt: ai.appliedPrompt(for: KnowledgeExtractionModule.moduleID))
            }
        }
        .sheet(item: $ai.preview) { preview in AIAnalysisPreviewView(model: ai, prepared: preview) }
    }
    private func prepare() {
        let frozen = context
        Task { @MainActor in
            error = nil; ai.reloadSettings(); await ai.configurePrompt(for: KnowledgeExtractionModule.moduleID)
            do {
                let module = try KnowledgeExtractionModule(transcript: transcript, context: frozen)
                ai.prepare(module: module, subjectLabels: module.subjectLabels, windowSelectionSeconds: max(1, min(31_536_000, module.input.windowEnd.timeIntervalSince(module.input.windowStart))))
                preparedInput = ai.preview?.input
            } catch { self.error = error.localizedDescription }
        }
    }
}
