import SwiftUI
import GPTAnalysisKit

private func promptModuleTitle(_ moduleID: String?) -> String {
    switch moduleID {
    case nil: return "通用"
    case "memory": return "内存分析"
    case "session.handoff": return "会话交接"
    default: return moduleID ?? "通用"
    }
}

struct PromptTemplateSelectionControls: View {
    @ObservedObject var model: DesktopAIModel
    let moduleID: String
    @State private var showsManager = false
    @State private var newTemplate: AIPromptTemplate?
    @State private var expanded = false
    private var choices: [AIPromptTemplate] { model.promptLibrary.catalog.choices(for: moduleID) }
    private var canSetDefault: Bool {
        !model.promptLibrary.isSaving && model.promptLibrary.hasLoaded && model.promptLibrary.loadError == nil &&
        (model.promptTemplate == nil ? model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : choices.contains { $0 == model.promptTemplate && $0.text == model.promptText })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Picker("提示词模板", selection: Binding(get: { model.promptTemplate?.id }, set: { id in
                    model.choosePrompt(choices.first { $0.id == id }, for: moduleID)
                })) {
                    Text("使用模块默认指引").tag(Optional<String>.none)
                    ForEach(choices) { Text($0.title).tag(Optional($0.id)) }
                    if let selected = model.promptTemplate, !choices.contains(where: { $0.id == selected.id }) {
                        Text(selected.title + "（选择时版本）").tag(Optional(selected.id))
                    }
                }.frame(maxWidth: 310).disabled(model.isAnalyzing || model.promptLibrary.isLoading)
                Button("设为本模块默认") {
                    Task { _ = await model.promptLibrary.setDefault(model.promptTemplate?.id, module: moduleID) }
                }.disabled(!canSetDefault || model.isAnalyzing)
                    .help("临时编辑需要先保存为模板，再设为默认。")
                Button("管理模板") { newTemplate = nil; showsManager = true }
            }.font(.system(size: 11))
            DisclosureGroup("本次提示词（可调整）", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $model.promptText).font(.system(size: 11)).frame(height: 75)
                        .border(Color.gray.opacity(0.25)).disabled(model.isAnalyzing)
                    HStack {
                        Text("临时编辑只影响本次生成；模块的证据要求和输出格式继续保留。")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("保存为新模板") {
                            newTemplate = AIPromptTemplate(title: model.promptTemplate.map { String($0.title.prefix(76)) + " 副本" } ?? "我的提示词",
                                text: model.promptText, moduleID: moduleID)
                            showsManager = true
                        }.disabled(model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(.top, 5)
            }.font(.system(size: 11))
            if let id = model.promptLibrary.catalog.defaults[moduleID],
               let name = model.promptLibrary.catalog.allTemplates.first(where: { $0.id == id })?.title {
                Text("本模块默认：" + name).font(.caption).foregroundStyle(.secondary)
            }
            if let selected = model.promptTemplate,
               let latest = choices.first(where: { $0.id == selected.id }), latest != selected {
                HStack {
                    Text("模板已有新版本，这里保留选择时的内容。").font(.caption).foregroundStyle(.secondary)
                    Button("载入最新版") { model.choosePrompt(latest, for: moduleID) }.font(.caption).disabled(model.isAnalyzing)
                }
            }
            if let error = model.promptLibrary.loadError ?? model.promptLibrary.operationError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("重新读取模板") { Task { await model.promptLibrary.refresh() } }.font(.caption)
                }
            }
        }
        .task { await model.configurePrompt(for: moduleID) }
        .onChange(of: model.promptLibrary.catalog.revision) { _, _ in Task { await model.configurePrompt(for: moduleID) } }
        .sheet(isPresented: $showsManager) {
            PromptTemplateManager(library: model.promptLibrary, initial: newTemplate, useModule: moduleID) { template, text in
                model.choosePrompt(template?.supports(moduleID) == true ? template : nil, for: moduleID)
                model.promptText = text
                expanded = true
            }
        }
    }
}

struct PromptTemplateSettingsCard: View {
    @ObservedObject var library: PromptTemplateLibraryModel
    @State private var showsManager = false
    var body: some View {
        MemoryCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    MemorySectionTitle(title: "提示词模板", subtitle: "提前保存提示词，各模块选择后复用；支持临时编辑")
                    Spacer()
                    Button("管理模板") { showsManager = true }
                }
                ForEach(["memory", "session.handoff"], id: \.self) { module in
                    Picker(promptModuleTitle(module) + "默认", selection: Binding(get: { library.catalog.defaults[module] }, set: { id in
                        Task { _ = await library.setDefault(id, module: module) }
                    })) {
                        Text("仅模块默认指引").tag(Optional<String>.none)
                        ForEach(library.catalog.choices(for: module)) { Text($0.title).tag(Optional($0.id)) }
                    }.disabled(library.isLoading || library.isSaving || library.loadError != nil)
                }
                Text("模板会随分析输入发送；完整使用内容会写入报告，后续改模板不会改动旧报告。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = library.loadError ?? library.operationError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("重新读取模板") { Task { await library.refresh() } }
                }
            }
        }.task { await library.loadIfNeeded() }
        .sheet(isPresented: $showsManager) { PromptTemplateManager(library: library) }
    }
}

struct PromptTemplateManager: View {
    @ObservedObject var library: PromptTemplateLibraryModel
    let useModule: String?
    let onUse: ((AIPromptTemplate?, String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AIPromptTemplate
    @State private var baseline: AIPromptTemplate?
    @State private var drafts: [String: AIPromptTemplate] = [:]
    @State private var baselines: [String: AIPromptTemplate] = [:]
    @State private var showArchived = false
    @State private var discardAlert = false
    @State private var savedMessage = ""

    init(library: PromptTemplateLibraryModel, initial: AIPromptTemplate? = nil,
         useModule: String? = nil, onUse: ((AIPromptTemplate?, String) -> Void)? = nil) {
        self.library = library; self.useModule = useModule; self.onUse = onUse
        let item = initial ?? AIPromptTemplate.builtIns[0]
        _draft = State(initialValue: item)
        _baseline = State(initialValue: library.catalog.allTemplates.first { $0.id == item.id })
    }
    private var items: [AIPromptTemplate] {
        library.catalog.allTemplates.filter { showArchived ? $0.isArchived : !$0.isArchived }
    }
    private var hasUnsavedEdits: Bool {
        func dirty(_ item: AIPromptTemplate, baseline: AIPromptTemplate?) -> Bool {
            if let baseline { return item != baseline }
            return !item.title.isEmpty || !item.text.isEmpty
        }
        return dirty(draft, baseline: baseline) || drafts.values.contains { $0.id != draft.id && dirty($0, baseline: baselines[$0.id]) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("提示词模板").font(.headline)
                Spacer()
                Toggle("回收区", isOn: $showArchived).toggleStyle(.checkbox)
                Button("新建模板") { select(AIPromptTemplate(title: "", text: "", moduleID: useModule), existing: false) }
                Button("重新读取") { Task { await library.refresh() } }.disabled(library.isLoading)
            }
            HStack(alignment: .top, spacing: 14) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(items) { item in
                            Button { select(item, existing: true) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).fontWeight(.medium).lineLimit(2)
                                    Text(promptModuleTitle(item.moduleID) + (item.isBuiltIn ? " · 预设" : " · v\(item.revision)"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(draft.id == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(width: 180)
                VStack(alignment: .leading, spacing: 10) {
                    TextField("模板名称", text: $draft.title).textFieldStyle(.roundedBorder)
                    Picker("使用范围", selection: $draft.moduleID) {
                        Text("通用（所有模块）").tag(Optional<String>.none)
                        Text("内存分析").tag(Optional("memory"))
                        Text("会话交接").tag(Optional("session.handoff"))
                        if let module = draft.moduleID, !["memory", "session.handoff"].contains(module) {
                            Text(module).tag(Optional(module))
                        }
                    }
                    Text(draft.isBuiltIn ? "预设可以调整后另存为自定义模板。" : "保存后可反复选择使用；移除的模板可从回收区恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft.text).font(.system(size: 12)).border(Color.gray.opacity(0.25))
                    Text("\(draft.text.utf8.count)/8192 字节 · 修改不会影响已生成报告。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if !draft.isBuiltIn, baseline != nil {
                            Button(draft.isArchived ? "恢复模板" : "移到回收区") {
                                Task {
                                    guard var original = baseline else { return }
                                    original.isArchived.toggle()
                                    if await library.save(original, expected: baseline), let saved = library.catalog.templates.first(where: { $0.id == original.id }) {
                                        draft.isArchived = saved.isArchived; draft.revision = saved.revision
                                        baseline = saved; baselines[saved.id] = saved
                                        if draft.title == original.title && draft.text == original.text { drafts.removeValue(forKey: saved.id) }
                                    }
                                }
                            }
                        }
                        Spacer()
                        if !draft.isBuiltIn { Button("保存模板") { save(copy: false) } }
                        Button(draft.isBuiltIn ? "另存为我的模板" : "另存为新模板") { save(copy: true) }
                    }.disabled(library.isSaving || library.loadError != nil)
                }
            }
            if let error = library.loadError ?? library.operationError { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text(savedMessage).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { if hasUnsavedEdits { discardAlert = true } else { dismiss() } }
                if let onUse, let useModule {
                    Button("使用当前内容") {
                        let original = library.catalog.choices(for: useModule).first { $0.id == draft.id }
                        onUse(original, draft.text)
                        dismiss()
                    }.buttonStyle(.borderedProminent).disabled(!draft.supports(useModule) || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.controlSize(.large)
        }.padding(20).frame(width: 760, height: 550)
        .disabled(library.isSaving)
        .task { await library.loadIfNeeded() }
        .alert("丢弃未保存的模板修改？", isPresented: $discardAlert) {
            Button("继续编辑", role: .cancel) {}
            Button("丢弃并关闭", role: .destructive) { dismiss() }
        } message: { Text("已保存的模板保持不变。") }
    }
    private func select(_ item: AIPromptTemplate, existing: Bool) {
        drafts[draft.id] = draft
        if let baseline { baselines[draft.id] = baseline }
        draft = drafts[item.id] ?? item
        baseline = baselines[item.id] ?? (existing ? item : nil)
        savedMessage = ""
    }
    private func save(copy: Bool) {
        let current = draft
        let expected = baseline
        let savedDraft = copy ? AIPromptTemplate(title: current.title, text: current.text, moduleID: current.moduleID) : current
        Task {
            if await library.save(savedDraft, expected: copy ? nil : expected),
               let saved = library.catalog.templates.first(where: { $0.id == savedDraft.id }) {
                drafts.removeValue(forKey: current.id)
                draft = saved; baseline = saved; baselines[saved.id] = saved
                savedMessage = "模板已保存，重启后可继续使用。"
            }
        }
    }
}
