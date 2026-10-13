import SwiftUI
import GPTAnalysisKit

struct AISettingsView: View {
    @ObservedObject var model: DesktopAIModel
    @State private var editingProvider: AIProviderConfiguration?
    @State private var removingProvider: AIProviderConfiguration?

    var body: some View {
        MemoryCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    MemorySectionTitle(title: "AI 分析来源", subtitle: "多个模块共用来源配置与钥匙串；先预览，再确认发送")
                    Spacer()
                    Button {
                        editingProvider = AIProviderPreset.openAI.makeConfiguration()
                    } label: { Label("添加来源", systemImage: "plus") }
                        .disabled(model.configurationError != nil)
                }
                if let error = model.configurationError {
                    HStack(alignment: .top) {
                        Text(error).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange).textSelection(.enabled)
                        Spacer()
                        Button("重新读取") { model.reloadSettings() }
                    }
                }
                if !model.settings.providers.isEmpty {
                    Picker("当前分析来源", selection: Binding(get: { model.settings.selectedProviderID },
                        set: { _ = model.selectProvider($0) })) {
                        Text("请选择").tag(Optional<UUID>.none)
                        ForEach(model.settings.providers) { provider in
                            Text("\(provider.name) · \(provider.model)").tag(Optional(provider.id))
                        }
                    }.disabled(model.configurationError != nil)
                    ForEach(model.settings.providers) { provider in
                        HStack(spacing: 12) {
                            Image(systemName: provider.kind == .ollama ? "desktopcomputer" : "network")
                                .foregroundStyle(MemoryStyle.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.name).font(.system(size: 12, weight: .medium))
                                Text("\(provider.kind.title) · \(provider.model)").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                                Text(provider.baseURL).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            if model.settings.selectedProviderID == provider.id { MemoryBadge(text: "已选择") }
                            Button("编辑") { editingProvider = provider }
                                .disabled(model.configurationError != nil)
                            Button("移除") { removingProvider = provider }
                                .disabled(model.configurationError != nil)
                        }.padding(.vertical, 5)
                    }
                } else if model.configurationError == nil {
                    Text("选择 OpenAI、DeepSeek、Ollama 或自定义来源，填入 Key 后即可拉取并选择模型。")
                        .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                }
                if let error = model.operationError {
                    Text(error).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange).textSelection(.enabled)
                }
                Text("API Key 只存入 macOS 钥匙串；配置文件不含密钥。Ollama 默认使用本机地址，也可以配置自己的服务地址。")
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editingProvider) { provider in
            AIProviderEditor(model: model, initial: provider)
        }
        .alert("移除 AI 来源？", isPresented: Binding(get: { removingProvider != nil },
            set: { if !$0 { removingProvider = nil } })) {
            Button("取消", role: .cancel) { removingProvider = nil }
            Button("移除", role: .destructive) {
                if let provider = removingProvider { model.removeProvider(provider.id, expectedProvider: provider) }
                removingProvider = nil
            }
        } message: {
            Text("移除 \(removingProvider?.name ?? "这个来源") 的配置和对应钥匙串密钥；已有分析结果仍然保留。")
        }
    }
}

struct AIProviderEditor: View {
    @ObservedObject var model: DesktopAIModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor: AIProviderEditorModel
    @State private var showKey = false
    @State private var showAdvanced = false
    @State private var modelSearch = ""
    @State private var attemptedSave = false
    private let expectedProvider: AIProviderConfiguration?

    init(model: DesktopAIModel, initial: AIProviderConfiguration,
         catalog: AIModelCatalogClient = HTTPAIModelCatalogClient()) {
        self.model = model
        expectedProvider = model.settings.providers.first { $0.id == initial.id }
        _editor = StateObject(wrappedValue: AIProviderEditorModel(configuration: initial, catalog: catalog,
            credentialResolver: { configuration, key, clear in
                try model.modelDiscoveryKey(configuration: configuration, draftKey: key, clearKey: clear)
            }))
        _showAdvanced = State(initialValue: initial.kind != AIProviderPreset.matching(initial).kind)
    }

    private var isEditing: Bool { model.settings.providers.contains { $0.id == editor.configuration.id } }
    private var filteredModels: [String] {
        let search = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? editor.models : editor.models.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isEditing ? "编辑 AI 来源" : "添加 AI 来源").font(.system(size: 20, weight: .semibold))
                Text("选服务商、填 Key、选模型；常用参数已自动填好。")
                    .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
            }
            HStack(spacing: 10) {
                ForEach(AIProviderPreset.allCases) { preset in
                    Button {
                        editor.selectPreset(preset)
                        modelSearch = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Image(systemName: preset.symbolName)
                                Spacer()
                                if editor.selectedPreset == preset { Image(systemName: "checkmark.circle.fill") }
                            }
                            Text(preset.title).font(.system(size: 12, weight: .semibold))
                            Text(preset.subtitle).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(editor.selectedPreset == preset ? MemoryStyle.accent : MemoryStyle.text)
                            .background(editor.selectedPreset == preset ? MemoryStyle.accent.opacity(0.08) : MemoryStyle.background)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(editor.selectedPreset == preset ? MemoryStyle.accent : MemoryStyle.border, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("名称").font(.system(size: 11, weight: .medium))
                        TextField("例如：个人 OpenAI / 工作网关", text: $editor.configuration.name)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("服务地址").font(.system(size: 11, weight: .medium))
                        TextField("https://api.example.com/v1", text: $editor.configuration.baseURL)
                        if editor.selectedPreset == .custom {
                            Picker("接口格式", selection: $editor.configuration.kind) {
                                Text("Chat Completions").tag(AIProviderKind.openAICompatible)
                                Text("Responses").tag(AIProviderKind.openAIResponses)
                                Text("Ollama").tag(AIProviderKind.ollama)
                            }
                            Text("填写服务商提供的基础地址，并选择它支持的接口格式。")
                                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(editor.configuration.requiresAPIKey ? "API Key" : "API Key（可选）")
                            .font(.system(size: 11, weight: .medium))
                        HStack {
                            Group {
                                if showKey {
                                    TextField(isEditing ? "留空保留已有密钥" : "粘贴这个来源的 API Key", text: $editor.key)
                                } else {
                                    SecureField(isEditing ? "留空保留已有密钥" : "粘贴这个来源的 API Key", text: $editor.key)
                                }
                            }.disabled(editor.clearKey)
                            Button { showKey.toggle() } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                            }.buttonStyle(.borderless).help(showKey ? "隐藏输入的 Key" : "显示输入的 Key")
                        }
                        Text(editor.configuration.kind == .ollama ? "本机 Ollama 通常不需要 Key；请先启动 Ollama 并安装模型。" : "只保存在 macOS 钥匙串，取消不会保存。")
                            .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                        Text("切换服务地址或接口格式后，请重新填写对应来源的 Key。")
                            .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("模型").font(.system(size: 11, weight: .medium))
                            Spacer()
                            if editor.isLoading {
                                ProgressView().controlSize(.small)
                                Button("取消拉取") { editor.cancelFetch() }
                            } else {
                                Button { editor.fetchModels() } label: { Label("拉取模型", systemImage: "arrow.down.circle") }
                            }
                        }
                        TextField("从列表选择，或直接填写模型 ID", text: $editor.configuration.model)
                        if !editor.models.isEmpty {
                            HStack {
                                TextField("搜索模型", text: $modelSearch).frame(maxWidth: 240)
                                Picker("选择模型", selection: $editor.configuration.model) {
                                    Text("请选择").tag("")
                                    if !editor.configuration.model.isEmpty && !filteredModels.contains(editor.configuration.model) {
                                        Text("\(editor.configuration.model)（当前值）").tag(editor.configuration.model)
                                    }
                                    ForEach(filteredModels, id: \.self) { name in Text(name).tag(name) }
                                }.labelsHidden()
                            }
                            Text("\(filteredModels.count) / \(editor.models.count) 个模型；选择用于文字分析的模型。")
                                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                        }
                        if let error = editor.modelError {
                            Text(error).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange).textSelection(.enabled)
                        }
                        if let status = editor.statusMessage {
                            Text(status).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                        }
                        Text("点击拉取会用 Key 请求上方服务的模型列表，不发送内存摘要；也可直接填写模型后保存。")
                            .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                    }
                    DisclosureGroup("高级设置", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            if editor.selectedPreset != .custom {
                                Picker("接口协议", selection: $editor.configuration.kind) {
                                    ForEach(AIProviderKind.allCases) { kind in Text(kind.title).tag(kind) }
                                }
                            }
                            Toggle("请求接口 JSON 模式", isOn: $editor.configuration.jsonMode)
                            HStack {
                                Text("请求超时")
                                Spacer()
                                TextField("秒", value: $editor.configuration.timeoutSeconds, format: .number).frame(width: 100)
                                Text("秒")
                            }
                            Text("范围 1–180 秒，限制从发送到接收完整响应的总时间。")
                                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                            HStack {
                                Text("最大输出 Token")
                                Spacer()
                                TextField("Token", value: $editor.configuration.maxOutputTokens, format: .number).frame(width: 100)
                            }
                            Text("范围 128–16384；完整分析建议先用 8192。")
                                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                            if isEditing { Toggle("清除已保存的密钥", isOn: $editor.clearKey) }
                            Text("服务地址不包含 /responses、/chat/completions 或 /api/chat；不支持 JSON 模式的服务可关闭该选项。")
                                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                        }.padding(.top, 10)
                    }.font(.system(size: 11))
                }.textFieldStyle(.roundedBorder).padding(.trailing, 8)
            }
            if attemptedSave, let error = model.operationError {
                Text(error).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange).textSelection(.enabled)
            }
            HStack {
                Text("保存来源不会自动发起分析。")
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    attemptedSave = true
                    if model.saveProvider(editor.configuration, key: editor.key, clearKey: editor.clearKey,
                                          expectedProvider: expectedProvider) {
                        editor.cancelFetch()
                        editor.key = ""; dismiss()
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 720, height: 670)
            .onDisappear { editor.cancelFetch() }
    }
}

/// Renders a reusable analysis result. The prepare closure is supplied by each module.
struct AIQuickAnalysisButton: View {
    @ObservedObject var model: DesktopAIModel
    let hasInput: Bool
    let onPrepare: () -> Void
    var body: some View {
        Button(action: onPrepare) { Label("AI 分析", systemImage: "sparkles") }
            .buttonStyle(.bordered).disabled(!hasInput || model.isAnalyzing)
            .help(model.selectedProvider == nil ? "先配置 AI 来源" : "查看摘要并发送给所选 AI 来源")
    }
}

struct AIAnalysisCard: View {
    @ObservedObject var model: DesktopAIModel
    let hasInput: Bool
    let onPrepare: () -> Void
    var onOpenReports: (() -> Void)? = nil

    var body: some View {
        MemoryCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    MemorySectionTitle(title: "AI 深入分析", subtitle: "结合本地事实提出原因假设与检查建议，需进一步验证")
                    Spacer()
                    if let onOpenReports {
                        Button(action: onOpenReports) { Label("报告库", systemImage: "doc.text") }
                    }
                    if model.isAnalyzing {
                        ProgressView().controlSize(.small)
                        Button("取消分析") { model.cancelAnalysis() }
                    } else {
                        Button(action: onPrepare) { Label("AI 深入分析", systemImage: "sparkles") }
                            .buttonStyle(.borderedProminent).disabled(!hasInput)
                    }
                }
                HStack {
                    if !model.settings.providers.isEmpty {
                        Picker("来源", selection: Binding(get: { model.settings.selectedProviderID },
                            set: { _ = model.selectProvider($0) })) {
                            Text("请选择来源").tag(Optional<UUID>.none)
                            ForEach(model.settings.providers) { provider in
                                Text("\(provider.name) · \(provider.model)").tag(Optional(provider.id))
                            }
                        }.frame(maxWidth: 480).disabled(model.configurationError != nil)
                    } else {
                        Text("先在设置中添加 AI 来源。")
                            .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                    }
                    Spacer()
                    if !hasInput { Text("至少需要两份历史采样").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary) }
                }
                PromptTemplateSelectionControls(model: model, moduleID: "memory")
                DisclosureGroup("补充活动说明（可选）") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("例如：这段时间运行了一个长任务，随后打开新页面", text: $model.activityContext, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...4)
                        Text("这段说明会发送给所选来源。请避免输入聊天正文、文件路径和敏感信息。")
                            .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                    }.padding(.top, 5)
                }.font(.system(size: 11))
                if let error = model.configurationError {
                    Text(error).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange).textSelection(.enabled)
                }
                if let error = model.operationError {
                    Text(error).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange).textSelection(.enabled)
                }
                if let error = model.analysisError {
                    Text(error).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange).textSelection(.enabled)
                }
                if let suggested = model.suggestedOutputLimitAfterFailure {
                    HStack(alignment: .top, spacing: 12) {
                        Text("本次因长度限制中断，可提高输出上限或缩短观察窗口后重新预览。")
                            .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                        Spacer()
                        Button("提高到 \(suggested) Token 并重新预览") {
                            guard hasInput else { return }
                            if model.increaseOutputLimitAfterFailure() { onPrepare() }
                        }
                        .disabled(!hasInput)
                    }
                    Text("只更新当前来源的上限，仍需手动确认发送，不会自动重试。")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }
                if let status = model.statusMessage {
                    Text(status).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }
                AIReportSaveStatus(model: model.reportLibrary)
                if let record = model.record {
                    AIAnalysisResultContent(record: record, input: model.recordInput,
                                            subjectLabels: model.recordSubjectLabels, isStale: model.resultIsStale)
                } else {
                    Text("点击后先查看实际观察窗口和匿名摘要，再手动确认发送。常规采样不会自动调用 AI。")
                        .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $model.preview) { prepared in
            AIAnalysisPreviewView(model: model, prepared: prepared)
        }
    }
}

struct AIAnalysisPreviewView: View {
    @ObservedObject var model: DesktopAIModel
    let prepared: AIAnalysisPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let prepared = model.preview ?? self.prepared
        return VStack(alignment: .leading, spacing: 16) {
            Text("确认 AI 分析摘要").font(.system(size: 20, weight: .semibold))
            Text("\(prepared.input.moduleTitle) · \(prepared.configuration.name) · \(prepared.configuration.model)")
                .font(.system(size: 12, weight: .medium)).textSelection(.enabled)
            Text("发送到：\(prepared.configuration.baseURL)")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
            Text(prepared.input.presentation == nil
                ? "实际观察窗口：\(MemoryFormat.date(prepared.input.windowStart)) → \(MemoryFormat.date(prepared.input.windowEnd))"
                : "来源日志时间范围：\(MemoryFormat.fullDate(prepared.input.windowStart)) → \(MemoryFormat.fullDate(prepared.input.windowEnd))（缺少起点时使用末次更新时间建立占位范围）")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            Text("本次输出上限：\(prepared.configuration.maxOutputTokens) Token")
                .font(.system(size: 12, weight: .medium))
            if prepared.configuration.maxOutputTokens < 8_192 {
                HStack(alignment: .top, spacing: 12) {
                    Text("结构化分析可能需要更长的输出，可在发送前提高上限。")
                        .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                    Spacer()
                    Button("提高到 8192 并重新预览") {
                        _ = model.increaseOutputLimitForPreview(prepared)
                    }.disabled(model.isAnalyzing)
                }
                Text("只更新来源配置和这份摘要的预览，不会发送请求。")
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }
            if let error = model.configurationError {
                Text(error).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange).textSelection(.enabled)
            }
            if let error = model.operationError {
                Text(error).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange).textSelection(.enabled)
            }
            Text((prepared.input.presentation?.privacyNotice ?? "分析对象使用匿名编号，本地定位信息留在本机。") + "包含 \(prepared.input.facts.count) 条事实和 \(prepared.input.subjects.count) 个分析对象。")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            if let prompt = prepared.input.prompt {
                Text("使用提示词：\(prompt.title)\(prompt.revision.map { " · v\($0)" } ?? "")\(prompt.isModified ? " · 本次已调整" : "")")
                    .font(.system(size: 11, weight: .medium))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let prompt = prepared.input.prompt {
                        Text("本次提示词").font(.system(size: 11, weight: .medium))
                        Text(prompt.text).font(.system(size: 11)).textSelection(.enabled)
                    }
                    ForEach(prepared.input.facts, id: \.id) { fact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(fact.id) · \(fact.title)").font(.system(size: 11, weight: .medium))
                            Text(jsonValue(fact.data)).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                        }
                    }
                    DisclosureGroup("查看完整发送内容（JSON）") {
                        Text(prepared.json).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }.font(.system(size: 11))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 200, maxHeight: 380)
            Text("该输入在打开此窗口时冻结。确认后只调用所选来源，不会自动切换到其他服务。")
                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("发送摘要并分析") { model.beginAnalysis(prepared); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 700)
    }

    private func jsonValue(_ value: AIJSONValue) -> String {
        guard let data = try? AIAnalysisCodec.encoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

struct AIAnalysisResultContent: View {
    let record: AIAnalysisRecord
    let input: AIAnalysisInput?
    let subjectLabels: [String: String]
    let isStale: Bool
    var isHistorical = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider().overlay(MemoryStyle.border)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(record.providerName) · \(record.model) · \(displayDate(record.generatedAt)) 生成")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                    Text("\(input?.presentation == nil ? "分析窗口" : "来源日志范围")：\(displayDate(record.windowStart)) → \(displayDate(record.windowEnd))")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }
                Spacer()
                MemoryBadge(text: isHistorical ? "历史快照" : (isStale ? "窗口 / 说明 / 来源已变化" : "本次窗口结果"), color: isStale ? MemoryStyle.orange : MemoryStyle.accent)
                if record.wasCached { MemoryBadge(text: "缓存", color: MemoryStyle.secondary) }
            }
            if isHistorical {
                Text(input?.presentation?.interpretation ?? "这份报告保留生成时的结论和依据，请按上方标注的观察窗口阅读。检查建议中的对象状态也属于当时的记录。")
                    .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            } else if isStale {
                Text("窗口、活动说明或来源已变化；以下结论只适用于分析时的摘要和上方标注的窗口及来源。")
                    .font(.system(size: 11)).foregroundStyle(MemoryStyle.orange)
            }
            if let prompt = input?.prompt {
                DisclosureGroup("使用提示词：" + prompt.title + (prompt.revision.map { " · v\($0)" } ?? "") + (prompt.isModified ? " · 本次已调整" : "")) {
                    Text(prompt.text).font(.system(size: 11)).textSelection(.enabled)
                }.font(.system(size: 11))
            }
            Text(record.result.summary).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
            if !record.result.observations.isEmpty {
                resultSection(input?.presentation?.evidenceTitle ?? "证据观察") {
                    ForEach(Array(record.result.observations.enumerated()), id: \.offset) { _, observation in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(observation.text).textSelection(.enabled)
                            evidence(observation.evidenceIDs)
                        }
                    }
                }
            }
            if !record.result.hypotheses.isEmpty {
                resultSection(input?.presentation?.hypothesesTitle ?? "原因假设 · 尚待验证") {
                    ForEach(Array(record.result.hypotheses.enumerated()), id: \.offset) { _, hypothesis in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(hypothesis.title).fontWeight(.medium).foregroundStyle(MemoryStyle.orange)
                            Text(hypothesis.explanation).textSelection(.enabled)
                            evidence(hypothesis.evidenceIDs)
                            if !hypothesis.missingEvidence.isEmpty {
                                Text("还缺少：\(hypothesis.missingEvidence.joined(separator: "；"))")
                                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            if !record.result.nextSteps.isEmpty {
                resultSection(input?.presentation?.nextStepsTitle ?? "检查建议") {
                    ForEach(Array(record.result.nextSteps.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 5) {
                            if let id = step.subjectID { Text(subjectLabels[id] ?? id).fontWeight(.medium) }
                            Text("\(index + 1). \(step.action)").textSelection(.enabled)
                            Text(step.purpose).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            if !record.result.limitations.isEmpty {
                resultSection("分析限制") {
                    Text(record.result.limitations.joined(separator: "\n"))
                        .foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func displayDate(_ date: Date) -> String {
        isHistorical ? MemoryFormat.fullDate(date) : MemoryFormat.date(date)
    }

    private func evidence(_ ids: [String]) -> some View {
        let facts = input?.facts ?? []
        return DisclosureGroup("依据：" + ids.map { id in facts.first { $0.id == id }?.title ?? id }.joined(separator: "；")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ids.enumerated()), id: \.offset) { _, id in
                    if let fact = facts.first(where: { $0.id == id }),
                       let data = try? AIAnalysisCodec.encoder(pretty: true).encode(fact.data),
                       let text = String(data: data, encoding: .utf8) {
                        Text(text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }.padding(.top, 5)
        }.font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
    }

    private func resultSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content().font(.system(size: 11))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
