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
    private var visibleCandidates: [MemoryOptimizationCandidate] { candidates.filter { showAll || $0.process.footprintBytes >= 32 * 1024 * 1024 } }
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("后台工具内存处理").font(.system(size: 20, weight: .semibold))
            Text("按单个工具进程占用排序，优先显示至少 32 MiB 的 MCP、REPL 和工具执行器。近期 CPU 仅供参考；请确认该工具已经不用。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text("只向所选工具进程发送正常退出信号，可能中断工具任务并影响其子进程。主应用、页面渲染和 GPU 不在此列表；不自动强杀。")
                .font(.system(size: 12)).foregroundStyle(MemoryStyle.orange).fixedSize(horizontal: false, vertical: true)
            Toggle("显示全部可处理工具（包含低于 32 MiB）", isOn: $showAll)
                .onChange(of: showAll) { _, _ in selected = [] }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if visibleCandidates.isEmpty {
                        Text("当前没有匹配工具。可以显示全部工具，或取消后刷新再扫描；归属不明及观察器的祖先进程不会列出。")
                            .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                    }
                    ForEach(visibleCandidates) { candidate in
                        Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: {
                            if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(MemoryFormat.executable(candidate.process.executable)) · PID \(candidate.process.pid) · \(MemoryFormat.bytes(candidate.process.footprintBytes))")
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(candidate.process.role.label) · \(candidate.relatedProcessCount) 个下级进程 · \(MemoryFormat.date(candidate.process.startedAt)) 启动")
                                    .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                                Text("所属：\(MemoryFormat.executable(candidate.rootProcess.executable)) · PID \(candidate.rootProcess.pid)").font(.system(size: 11))
                                Text(candidate.activity).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange)
                                Text(candidate.process.executable).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                            }
                        }.toggleStyle(.checkbox).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(minHeight: 130, maxHeight: 280)
            Text("已选 \(selected.count) 个工具进程。占用是扫描时的测量值，不能保证全部释放。执行前重新校验身份，每个目标观察 10 秒；拒绝退出、出现新实例或状态不明时停止后续处理。")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = model.optimizationMessage { Text(message).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("请求退出所选进程…") { confirms = true }.disabled(selected.isEmpty || model.hasPendingWork)
            }.controlSize(.large)
        }.padding(24).frame(width: 620)
            .alert("确认正常退出 \(selected.count) 个工具进程？", isPresented: $confirms) {
                Button("取消", role: .cancel) {}
                Button("确认退出", role: .destructive) {
                    model.startOptimization(candidates: candidates, selected: selected, snapshot: snapshot, history: history)
                    if model.isOptimizing { dismiss() }
                }
            } message: { Text("请先保存任务。所选工具任务及其下级进程可能受影响；退出请求无法撤回。") }
    }
}
