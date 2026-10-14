import SwiftUI
import AppKit
import GPTMemoryCore

struct MemoryProcessActionConfirmation: View {
    @ObservedObject var model: MemoryProcessActionsModel
    let request: MemoryProcessActionRequest
    @Environment(\.dismiss) private var dismiss
    @State private var confirmationPID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.kind.label).font(.system(size: 18, weight: .semibold))
            Text("\(MemoryFormat.executable(request.process.executable)) · PID \(String(request.process.pid))")
                .font(.system(size: 14, weight: .medium))
            Text("\(request.process.role.label) · \(MemoryFormat.date(request.process.startedAt)) 启动\n\(request.process.executable)")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
            Text(request.process.role == .appMain
                 ? "这是应用主进程，退出可能中断同一应用的 \(request.relatedProcessCount) 个子进程及正在进行的任务。"
                 : "只操作这个进程，可能中断正在执行的工具或页面任务；会话归属尚未确认。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if request.kind == .force {
                Text("强制结束不会等待保存或清理，未保存的内容可能丢失。输入目标 PID 后确认。")
                    .font(.system(size: 12)).foregroundStyle(MemoryStyle.orange)
                TextField(String(request.process.pid), text: $confirmationPID).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("确认强制结束的 PID")
            } else {
                Text(request.process.role == .appMain ? "先向应用请求正常退出。" : "先发送正常退出信号（SIGTERM）。")
                    .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            }
            Text("执行前重新核对目标归属和启动身份。随后在 1、5、10 秒检查目标及占用，采集状态保持不变。")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            HStack {
                Spacer()
                Button("取消") { model.pending = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.kind.label) { model.confirm(); dismiss() }
                    .disabled(request.kind == .force && confirmationPID.trimmingCharacters(in: .whitespacesAndNewlines) != String(request.process.pid))
            }.controlSize(.large)
        }.padding(24).frame(width: 510)
    }
}

struct MemoryProcessActionHistory: View {
    @ObservedObject var model: MemoryProcessActionsModel
    @State private var isExpanded: Bool
    init(model: MemoryProcessActionsModel, initiallyExpanded: Bool = false) {
        self.model = model; _isExpanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = model.message {
                HStack(spacing: 8) {
                    if model.isBusy || model.isObserving { ProgressView().controlSize(.small) }
                    Text(message).font(.system(size: 11)).textSelection(.enabled)
                }
            }
            if let error = model.recordError {
                Text(error).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange).textSelection(.enabled)
            }
            if !model.records.isEmpty {
                DisclosureGroup("诊断与操作记录（当前 \(model.records.count) 条）", isExpanded: $isExpanded) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.records) { record in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(record.diagnostic == nil ? record.receipt?.kind.label ?? "操作" : "采集诊断") · PID \(String(record.process.pid)) · \(MemoryFormat.date(record.createdAt))")
                                        .font(.system(size: 11, weight: .medium))
                                    if record.observationFailed == true {
                                        Text("最近的效果检查未成功，当前状态尚未确认。")
                                            .font(.system(size: 11)).foregroundStyle(MemoryStyle.orange)
                                    } else if let result = record.observation {
                                        Text(result.state.label + (result.replacementPIDs.isEmpty ? "" : "；发现同程序新实例 PID \(result.replacementPIDs.map(String.init).joined(separator: ", "))"))
                                            .font(.system(size: 11))
                                        Text("处理前目标 \(MemoryFormat.bytes(record.process.footprintBytes)) · 总占用变化 \(result.knownTotalChange.map(MemoryFormat.delta) ?? "无法完整比较")")
                                            .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                                        Text("总占用也受其他进程影响，这个变化不能全部归因于本次操作。")
                                            .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                                    } else if record.receipt != nil {
                                        Text("退出请求已发送，尚未获得效果结果。") .font(.system(size: 10))
                                    }
                                    if let diagnostic = record.diagnostic {
                                        HStack {
                                            Text(diagnostic.partial ? "诊断摘要不完整" : "诊断摘要已保存").font(.system(size: 10))
                                            Button("显示摘要文件") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: diagnostic.outputPath)]) }
                                                .buttonStyle(.link).font(.system(size: 10))
                                        }
                                    }
                                    if let trend = record.trend, !trend.isEmpty {
                                        Text("已保存目标最近 \(trend.count) 份采样趋势，\(trend.filter { $0.footprintBytes == nil }.count) 份未取得目标指标。")
                                            .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                                    }
                                }.textSelection(.enabled)
                                Divider()
                            }
                        }.padding(.top, 8)
                    }.frame(maxHeight: 180)
                    Button("显示本地记录目录") { NSWorkspace.shared.activateFileViewerSelecting([model.directoryURL]) }
                        .buttonStyle(.link).font(.system(size: 10))
                    Text("当前展示有界数量的记录；完整记录可在本机目录查看。")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }.font(.system(size: 11))
            }
        }
    }
}


private struct MemoryOptimizationReview: Identifiable {
    let id = UUID()
    let candidates: [MemoryOptimizationCandidate]
    let snapshot: MemorySnapshot?
    let history: [MemorySnapshot]
}

struct MemoryOptimizationControl: View {
    @ObservedObject var model: MemoryProcessActionsModel
    let snapshot: MemorySnapshot?
    let history: [MemorySnapshot]
    var isBusy = false
    @State private var review: MemoryOptimizationReview?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    review = MemoryOptimizationReview(candidates: model.optimizationCandidates(snapshot: snapshot, history: history, minimumBytes: 0),
                                                      snapshot: snapshot, history: history)
                } label: {
                    Label("内存处理…", systemImage: "wand.and.stars")
                }.disabled(isBusy || model.hasPendingWork || model.pending != nil || snapshot == nil)
                if model.isOptimizing {
                    ProgressView().controlSize(.small)
                    Button("停止后续处理") { model.stopOptimization() }
                }
                Text("查看 GPT 后台工具，确认后单独处理").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                Spacer()
            }
            if let message = model.optimizationMessage {
                Text(message).font(.system(size: 11)).textSelection(.enabled)
            }
        }.sheet(item: $review) { review in
            MemoryOptimizationPlan(model: model, candidates: review.candidates, snapshot: review.snapshot, history: review.history)
        }
    }
}

struct MemoryOptimizationPlan: View {
    @ObservedObject var model: MemoryProcessActionsModel
    let candidates: [MemoryOptimizationCandidate]
    let snapshot: MemorySnapshot?
    let history: [MemorySnapshot]
    @State private var selected: Set<String> = []
    @State private var confirms = false
    @State private var showAll = false
    @State private var repeatedOnly = false
    @State private var byProject = true
    private var groups: [MemoryToolInstanceGroup] { MemoryToolGrouping.groups(candidates: candidates, contexts: model.toolContexts) }
    private var visibleGroups: [MemoryToolInstanceGroup] {
        groups.filter { group in
            (!repeatedOnly || group.isRepeated) && (showAll || group.candidates.contains { $0.process.footprintBytes >= 32 * 1024 * 1024 })
        }
    }
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("后台工具内存处理").font(.system(size: 20, weight: .semibold))
            Text("按项目查看 MCP、REPL 和工具执行器，再按类型、启动命令与工作目录归组。默认展示包含至少 32 MiB 实例的组；请确认工具已经不用。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("只向所选工具进程发送正常退出信号，可能中断工具任务并影响其子进程。主应用、页面渲染和 GPU 不在此列表；不自动强杀。")
                .font(.system(size: 12)).foregroundStyle(MemoryStyle.orange).fixedSize(horizontal: false, vertical: true)
            if let warning = model.contextWarning { Text(warning).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange) }
            HStack {
                Toggle("按项目分组", isOn: $byProject)
                Toggle("仅同配置多实例", isOn: $repeatedOnly).disabled(model.isLoadingCommands)
                    .onChange(of: repeatedOnly) { _, _ in selected = [] }
                Toggle("包含低占用组", isOn: $showAll)
                    .onChange(of: showAll) { _, _ in selected = [] }
            }.font(.system(size: 11))
            Text("共 \(candidates.count) 个工具 · \(groups.filter(\.isRepeated).count) 组同配置多实例（含低占用），当前匹配 \(visibleGroups.count) 组。多实例不代表多余。")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if visibleGroups.isEmpty {
                        Text(model.isLoadingCommands ? "正在读取命令和工作目录…" : "没有匹配对象。可调整筛选，或取消后刷新；归属不明及受保护进程不会列出。")
                            .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                    }
                    if byProject {
                        ForEach(MemoryToolGrouping.projects(groups: visibleGroups)) { project in
                            MemoryToolProjectSection(model: model, project: project, snapshot: snapshot, selected: $selected)
                        }
                    } else {
                        ForEach(visibleGroups) { group in
                            MemoryToolInstanceSection(model: model, group: group, snapshot: snapshot, selected: $selected)
                        }
                    }
                }
            }.frame(minHeight: 130, maxHeight: 280)
            Text("已选 \(selected.count) 个工具进程。占用是扫描时的测量值，不能保证全部释放。执行前重新校验身份，每个目标观察 10 秒；拒绝退出、出现新实例或状态不明时停止后续处理。")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = model.optimizationMessage { Text(message).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("请求退出所选进程…") { confirms = true }.disabled(selected.isEmpty || model.hasPendingWork || model.isLoadingCommands)
            }.controlSize(.large)
            Text("命令、目录和项目依据仅在本机临时展示。会话归属未知；常驻服务的启动参数不能说明当前请求。")
                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            Button("刷新命令与工作目录") { model.loadCommandPreviews(candidates: candidates, snapshot: snapshot) }.disabled(model.isLoadingCommands)
        }.padding(24).frame(width: 740)
            .onChange(of: model.isLoadingCommands) { _, value in if value { selected = [] } }
            .onAppear { model.loadCommandPreviews(candidates: candidates, snapshot: snapshot) }
            .onDisappear { model.clearCommandPreviews() }
            .alert("确认正常退出 \(selected.count) 个工具进程？", isPresented: $confirms) {
                Button("取消", role: .cancel) {}
                Button("确认退出", role: .destructive) {
                    model.startOptimization(candidates: candidates, selected: selected, snapshot: snapshot, history: history)
                    if model.isOptimizing { dismiss() }
                }
            } message: { Text("请先保存任务。所选工具任务及其下级进程可能受影响；退出请求无法撤回。") }
    }
}


private struct MemoryToolCommandRow: View {
    @ObservedObject var model: MemoryProcessActionsModel
    let candidate: MemoryOptimizationCandidate
    let snapshot: MemorySnapshot?
    @Binding var selected: Bool
    var body: some View {
        Toggle(isOn: $selected) {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(MemoryFormat.executable(candidate.process.executable)) · PID \(candidate.process.pid) · \(MemoryFormat.bytes(candidate.process.footprintBytes))")
                .font(.system(size: 13, weight: .medium))
            Text("\(candidate.process.role.label) · \(candidate.relatedProcessCount) 个下级进程 · \(MemoryFormat.date(candidate.process.startedAt)) 启动")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            Text("所属：\(MemoryFormat.executable(candidate.rootProcess.executable)) · PID \(candidate.rootProcess.pid)").font(.system(size: 11))
            Text("父进程 PID \(candidate.process.parentPID) · 会话归属：未知").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            MemoryToolContextDetail(context: model.toolContexts[candidate.id], isLoading: model.isLoadingCommands)
            Text(candidate.activity).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange)
            Text("启动命令：" + (model.commandPreviews[candidate.id] ?? (model.isLoadingCommands ? "读取中…" : "未读取")))
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            let children = snapshot.map { sample in sample.processes.filter { MemoryOptimizationPlanner.isDescendant($0, of: candidate.process, in: sample) } } ?? []
            if !children.isEmpty {
                DisclosureGroup("下级进程命令（\(children.count) 个，最多展示 8 个）") {
                    ForEach(Array(children.prefix(8))) { child in
                        Text("PID \(child.pid)：" + (model.commandPreviews[child.key] ?? (model.isLoadingCommands ? "读取中…" : "未读取")))
                            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        }.toggleStyle(.checkbox).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}


struct MemoryProcessCommandDetail: View {
    @ObservedObject var model: MemoryProcessActionsModel
    let process: ProcessSample
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button("读取启动命令") { model.loadCommandPreview(for: process) }.disabled(model.isLoadingCommands)
            if let command = model.commandPreviews[process.key] {
                Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                MemoryToolContextDetail(context: model.toolContexts[process.key], isLoading: model.isLoadingCommands)
                Text("本次读取的启动参数，不能据此判断当前请求或是否空闲。")
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }
        }.onChange(of: process.key) { _, _ in model.clearCommandPreviews() }
            .onDisappear { model.clearCommandPreviews() }
    }
}


private struct MemoryToolContextDetail: View {
    let context: MemoryToolRuntimeContext?
    let isLoading: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("工作目录：" + (context?.workingDirectory ?? context?.directoryIssue ?? (isLoading ? "读取中…" : "未知")))
                .font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("项目：" + (context?.projectPath ?? "归属未知"))
                .font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let context {
                DisclosureGroup("项目归属依据与读取时间") {
                    Text(context.projectEvidence).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                    Text("读取时间：" + MemoryFormat.date(context.capturedAt)).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }.font(.system(size: 10))
            }
        }
    }
}

private struct MemoryToolInstanceSection: View {
    @ObservedObject var model: MemoryProcessActionsModel
    let group: MemoryToolInstanceGroup
    let snapshot: MemorySnapshot?
    @Binding var selected: Set<String>
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.candidates[0].process.role.label).font(.system(size: 12, weight: .semibold))
                Text("\(group.candidates.count) 个实例 · 合计 \(group.footprintBytes.map(MemoryFormat.bytes) ?? "超出计量范围")")
                    .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                if group.isRepeated { MemoryBadge(text: "同配置多实例", color: MemoryStyle.orange) }
            }
            if !group.isComparable { Text("命令或工作目录未读全，暂不比较重复实例。") .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary) }
            ForEach(group.candidates) { candidate in
                MemoryToolCommandRow(model: model, candidate: candidate, snapshot: snapshot,
                    selected: Binding(get: { selected.contains(candidate.id) }, set: {
                        if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                    }))
            }
        }.padding(.vertical, 6)
    }
}

private struct MemoryToolProjectSection: View {
    @ObservedObject var model: MemoryProcessActionsModel
    let project: MemoryToolProjectGroup
    let snapshot: MemorySnapshot?
    @Binding var selected: Set<String>
    @State private var expanded = true
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(project.groups) { group in
                MemoryToolInstanceSection(model: model, group: group, snapshot: snapshot, selected: $selected)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "项目归属未知")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(project.instanceCount) 个工具 · 合计 \(project.footprintBytes.map(MemoryFormat.bytes) ?? "超出计量范围")")
                    .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                if let path = project.path { Text(path).font(.system(size: 10)).textSelection(.enabled) }
            }
        }
    }
}
