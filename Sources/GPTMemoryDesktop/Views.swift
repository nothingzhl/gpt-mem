import SwiftUI
import Charts
import GPTMemoryCore

private enum MemoryPage: String, CaseIterable, Identifiable {
    case overview, processes, history, sessions, reports, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "概览"
        case .processes: return "进程明细"
        case .history: return "历史与报告"
        case .sessions: return "Codex 工作区"
        case .reports: return "AI 报告库"
        case .settings: return "设置"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .processes: return "list.bullet.rectangle"
        case .history: return "clock.arrow.circlepath"
        case .sessions: return "folder"
        case .reports: return "doc.text"
        case .settings: return "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "了解 GPT 当前占用，以及这次上涨来自哪里。"
        case .processes: return "按进程查看真实 Footprint，区分页面、MCP 与执行器。"
        case .history: return "用已有采样追踪进程变化，导出可离线查看的报告。"
        case .sessions: return "按项目查看会话、用量分布和活跃情况。"
        case .reports: return "保存和回看 AI 分析结论、冻结的依据，导出离线报告。"
        case .settings: return "调整本机采样、历史记录和共用的 AI 分析来源。"
        }
    }
}

struct MemoryDesktopView: View {
    @ObservedObject var model: DesktopModel
    @State private var selectedPage: MemoryPage = .overview
    @State private var selectedRole: ProcessRole?
    @State private var minutes = 30
    @State private var focusedProcessKey: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(MemoryStyle.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 20)
                if selectedPage != .sessions && selectedPage != .reports && (model.displayedErrorMessage != nil || model.noticeMessage != nil) { messageBanner.padding(.horizontal, 28).padding(.bottom, 16) }
                switch selectedPage {
                case .overview:
                    ScrollView {
                        OverviewContent(snapshot: model.snapshot, history: model.history,
                                        analysis: model.analysis, minutes: $minutes,
                                        aiModel: model.aiModel, onAIAnalysis: model.prepareMemoryAIAnalysis,
                                        onOpenReports: { selectedPage = .reports }, onLocate: locateProcess) { role in
                            selectedRole = role; selectedPage = .processes
                        }.padding(.horizontal, 28).padding(.bottom, 28)
                    }
                case .processes:
                    ProcessesContent(snapshot: model.snapshot, selectedRole: $selectedRole,
                                     isBusy: model.isBusy, focusedKey: $focusedProcessKey,
                                     actions: model.processActions, history: model.history) { model.diagnose(process: $0) }
                        .padding(.horizontal, 28).padding(.bottom, 24)
                case .history:
                    ScrollView {
                        HistoryContent(analysis: model.analysis, snapshot: model.snapshot,
                                       minutes: $minutes, isBusy: model.isBusy,
                                       lastExportURL: model.lastExportURL,
                                       aiModel: model.aiModel, onAIAnalysis: model.prepareMemoryAIAnalysis,
                                       onOpenReports: { selectedPage = .reports }, onLocate: locateProcess) { model.exportReport() }
                            .padding(.horizontal, 28).padding(.bottom, 28)
                    }
                case .sessions:
                    SessionWorkspaceHost(model: model.sessionModel, aiModel: model.sessionAIModel).equatable()
                        .padding(.horizontal, 28).padding(.bottom, 24)
                case .reports:
                    AIReportsContent(model: model.aiModel.reportLibrary)
                        .padding(.horizontal, 28).padding(.bottom, 24)
                case .settings:
                    ScrollView {
                        SettingsContent(interval: $model.interval, snapshot: model.snapshot,
                                        databaseURL: model.databaseURL, isMonitoring: model.isMonitoring,
                                        modeLabel: model.modeLabel, aiModel: model.aiModel) { model.openDataDirectory() }
                            .padding(.horizontal, 28).padding(.bottom, 28)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(MemoryStyle.background).foregroundStyle(MemoryStyle.text)
        .tint(MemoryStyle.accent)
        .disclosureGroupStyle(WideDisclosureGroupStyle())
        .frame(minWidth: 1000, minHeight: 680)
        .onChange(of: minutes) { _, value in model.setWindow(seconds: Double(value * 60)) }
        .onChange(of: model.interval) { _, value in model.setInterval(value) }
        .onChange(of: selectedPage) { _, value in
            if value == .sessions { model.sessionAIModel.reloadSettings() }
            else if value == .settings || value == .overview || value == .history { model.aiModel.reloadSettings() }
            model.isSessionWorkspaceActive = value == .sessions
            model.isReportLibraryActive = value == .reports
        }
    }

    private func locateProcess(_ key: String) {
        guard model.snapshot?.processes.contains(where: { $0.key == key }) == true else {
            model.noticeMessage = "这个历史进程当前不在采样列表中；请刷新后核对，不能仅按旧 PID 操作。"
            return
        }
        selectedRole = nil; focusedProcessKey = key; selectedPage = .processes
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white).frame(width: 38, height: 38)
                    .background(LinearGradient(colors: [MemoryStyle.accent, Color(red: 0.53, green: 0.39, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("GPT Manager").font(.system(size: 15, weight: .semibold))
                    Text("本机内存与 Codex 会话").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 34)
            HStack(spacing: 7) {
                Image(systemName: "memorychip").font(.system(size: 11))
                Text("工作区").font(.system(size: 11, weight: .medium))
            }.foregroundStyle(MemoryStyle.secondary).padding(.horizontal, 24).padding(.bottom, 12)
            ForEach(MemoryPage.allCases) { page in
                Button {
                    selectedPage = page
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: page.icon).font(.system(size: 14)).frame(width: 18)
                        Text(page.title).font(.system(size: 13, weight: selectedPage == page ? .semibold : .regular))
                        Spacer()
                        if selectedPage == page { Circle().fill(MemoryStyle.accent).frame(width: 5, height: 5) }
                    }.foregroundStyle(selectedPage == page ? MemoryStyle.accent : MemoryStyle.text.opacity(0.8))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(selectedPage == page ? MemoryStyle.accentBackground : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(model.isMonitoring ? MemoryStyle.green : MemoryStyle.secondary).frame(width: 6, height: 6)
                    Text(model.modeLabel).font(.system(size: 11, weight: .medium))
                }
                Text("本机采样 · AI 手动发送摘要").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(MemoryStyle.border))
                .padding(16)
        }.frame(width: 216).frame(maxHeight: .infinity).background(MemoryStyle.sidebar)
    }

    private var header: some View {
        let externallyMonitoring = model.modeLabel.contains("外部采集")
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text(selectedPage == .overview ? "内存概览" : selectedPage.title)
                    .font(.system(size: 25, weight: .semibold))
                Text(selectedPage.subtitle).font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
            }
            Spacer(minLength: 8)
            if selectedPage == .overview || selectedPage == .history {
                AIQuickAnalysisButton(model: model.aiModel, hasInput: (model.analysis?.sampleCount ?? 0) >= 2) {
                    if model.aiModel.selectedProvider == nil { selectedPage = .settings }
                    else { model.prepareMemoryAIAnalysis() }
                }
            }
            if selectedPage != .sessions && selectedPage != .reports {
                if model.isBusy { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                    .buttonStyle(.bordered).controlSize(.regular).disabled(model.isBusy).help("刷新当前采样与历史").accessibilityLabel("刷新内存数据")
                Button {
                    if model.isMonitoring { model.stopMonitoring() } else { model.startMonitoring() }
                } label: {
                    Label(externallyMonitoring ? "外部采集中" : (model.isMonitoring ? "暂停采集" : "开始采集"), systemImage: externallyMonitoring ? "arrow.triangle.2.circlepath" : (model.isMonitoring ? "pause.fill" : "play.fill"))
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 3).padding(.vertical, 3)
                }.buttonStyle(.borderedProminent).disabled(model.isBusy || externallyMonitoring)
                    .help(externallyMonitoring ? "当前从外部采集器读取历史，外部采集结束后自动接管。" : (model.isMonitoring ? "暂停本观察器的采集" : "开始本机只读采集"))
            }
        }
    }

    private var messageBanner: some View {
        let isError = model.displayedErrorMessage != nil
        let color = isError ? MemoryStyle.orange : MemoryStyle.green
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.circle").foregroundStyle(color)
            Text(model.displayedErrorMessage ?? model.noticeMessage ?? "").font(.system(size: 12)).textSelection(.enabled)
            Spacer(minLength: 4)
            Button { model.dismissMessage() } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).foregroundStyle(MemoryStyle.secondary).help("收起提示").accessibilityLabel("收起提示")
        }.padding(12).background(color.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.18)))
    }
}

private struct RoleSummary: Identifiable {
    let role: ProcessRole
    let count: Int
    let bytes: UInt64
    var id: String { role.rawValue }
    static func summaries(_ snapshot: MemorySnapshot?) -> [RoleSummary] {
        guard let snapshot else { return [] }
        return ProcessRole.allCases.compactMap { role in
            let processes = snapshot.processes.filter { $0.role == role }
            guard !processes.isEmpty else { return nil }
            return RoleSummary(role: role, count: processes.count, bytes: processes.reduce(0) { $0 + $1.footprintBytes })
        }.sorted { $0.bytes > $1.bytes }
    }
}

private struct WindowPicker: View {
    @Binding var minutes: Int
    var body: some View {
        Picker("观察窗口", selection: $minutes) {
            Text("15 分钟").tag(15)
            Text("30 分钟").tag(30)
            Text("2 小时").tag(120)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 218).controlSize(.small)
    }
}

private struct OverviewContent: View {
    let snapshot: MemorySnapshot?
    let history: [MemorySnapshot]
    let analysis: MemoryAnalysis?
    @Binding var minutes: Int
    let aiModel: DesktopAIModel
    let onAIAnalysis: () -> Void
    let onOpenReports: () -> Void
    var onLocate: (String) -> Void = { _ in }
    let onRoleSelect: (ProcessRole) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            metrics
            AnalysisConclusionCard(analysis: analysis, minutes: minutes, findingLimit: 3, onLocate: onLocate)
            AIAnalysisCard(model: aiModel, hasInput: (analysis?.sampleCount ?? 0) >= 2, onPrepare: onAIAnalysis,
                           onOpenReports: onOpenReports)
            HStack(alignment: .top, spacing: 18) {
                MemoryCard {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top) {
                            MemorySectionTitle(title: "总占用趋势", subtitle: "Footprint · MiB")
                            Spacer(minLength: 4)
                            WindowPicker(minutes: $minutes)
                        }
                        trend
                        HStack {
                            Circle().fill(MemoryStyle.accent).frame(width: 5, height: 5)
                            Text("GPT 已识别进程合计").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                            Spacer()
                            Text("\(history.count) 份真实样本").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity)
                roleDistribution.frame(width: 250)
            }
            GrowthAttribution(analysis: analysis)
            dataNote
        }
    }

    private var metrics: some View {
        HStack(spacing: 14) {
            MemoryMetricCard(title: "GPT 总占用", value: snapshot.map { MemoryFormat.bytes($0.totalFootprintBytes) } ?? "—",
                             detail: analysis.map { "窗口内 \(MemoryFormat.delta($0.totalChangeBytes))" } ?? "等待采样基线", icon: "memorychip")
            MemoryMetricCard(title: "目标进程", value: snapshot.map { String($0.processes.count) } ?? "—",
                             detail: "主程序、页面、MCP 与 REPL", icon: "square.stack.3d.up", color: MemoryStyle.green)
            MemoryMetricCard(title: "系统压力", value: MemoryFormat.pressure(snapshot?.system.pressureLevel),
                             detail: "交换 \(snapshot?.system.swapUsedBytes.map(MemoryFormat.bytes) ?? "未知")", icon: "gauge.with.dots.needle.33percent",
                             color: MemoryFormat.pressureColor(snapshot?.system.pressureLevel))
            MemoryMetricCard(title: snapshot?.observer?.pid == Int(ProcessInfo.processInfo.processIdentifier) ? "采集器自身" : "记录采集器", value: snapshot?.observer.map { MemoryFormat.bytes($0.footprintBytes) } ?? "—",
                             detail: "已从 GPT 总占用中排除", icon: "leaf", color: MemoryStyle.orange)
        }
    }

    @ViewBuilder private var trend: some View {
        if history.count < 2 {
            MemoryEmptyState(icon: "chart.xyaxis.line", title: "等待趋势样本", detail: "至少两份历史采样后显示真实曲线。开始采集，或等待已有采集器写入历史。")
                .frame(height: 220)
        } else {
            Chart(chartSamples(history), id: \.id) { point in
                AreaMark(x: .value("时间", point.capturedAt), y: .value("占用", Double(point.totalFootprintBytes) / 1_048_576))
                    .foregroundStyle(LinearGradient(colors: [MemoryStyle.accent.opacity(0.18), MemoryStyle.accent.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", point.capturedAt), y: .value("占用", Double(point.totalFootprintBytes) / 1_048_576))
                    .foregroundStyle(MemoryStyle.accent).lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(MemoryStyle.border)
                    AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(MemoryStyle.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(MemoryStyle.border)
                    AxisValueLabel().foregroundStyle(MemoryStyle.secondary)
                }
            }.frame(height: 220)
        }
    }

    private func chartSamples(_ samples: [MemorySnapshot]) -> [MemorySnapshot] {
        let limit = 360
        guard samples.count > limit, let first = samples.first, let last = samples.last else { return samples }
        // Model history is chronological. Keep endpoints plus each bucket's low and high;
        // analysis and sample-count labels continue to use the complete history.
        let bucketSize = Int(ceil(Double(samples.count - 2) / Double((limit - 2) / 2)))
        var points = [first]
        for start in stride(from: 1, to: samples.count - 1, by: bucketSize) {
            let bucket = samples[start..<min(samples.count - 1, start + bucketSize)]
            if let low = bucket.min(by: { $0.totalFootprintBytes < $1.totalFootprintBytes }),
               let high = bucket.max(by: { $0.totalFootprintBytes < $1.totalFootprintBytes }) {
                points.append(low)
                if low.id != high.id { points.append(high) }
            }
        }
        points.append(last)
        return points.sorted { $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt }
    }

    private var roleDistribution: some View {
        let roles = RoleSummary.summaries(snapshot)
        return MemoryCard {
            VStack(alignment: .leading, spacing: 17) {
                MemorySectionTitle(title: "角色分布", subtitle: "点击一类查看进程")
                if roles.isEmpty {
                    MemoryEmptyState(icon: "rectangle.stack", title: "暂无目标进程", detail: "打开 ChatGPT / Codex 后刷新。")
                } else {
                    ForEach(roles.prefix(7)) { item in
                        Button { onRoleSelect(item.role) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Circle().fill(MemoryStyle.roleColor(item.role)).frame(width: 6, height: 6)
                                    Text(item.role.label).font(.system(size: 11)).lineLimit(1)
                                    Text("\(item.count)").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                                    Spacer(minLength: 2)
                                    Text(MemoryFormat.bytes(item.bytes)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                                }
                                GeometryReader { geometry in
                                    Capsule().fill(MemoryStyle.border)
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(MemoryStyle.roleColor(item.role))
                                                .frame(width: geometry.size.width * min(1, Double(item.bytes) / Double(max(1, snapshot?.totalFootprintBytes ?? 0))))
                                        }
                                }.frame(height: 3)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if roles.count > 7 { Text("其余 \(roles.count - 7) 类可在进程明细中查看").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dataNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 11))
            VStack(alignment: .leading, spacing: 4) {
                if let snapshot { Text("最新采样：\(MemoryFormat.date(snapshot.capturedAt))（北京时间）") }
                Text("Footprint 包含进程承担的压缩等内存；采集器自身单列。会话归属未知，常驻或上涨不能单独证明泄漏。")
                if let snapshot, !snapshot.unavailablePIDs.isEmpty {
                    Text("本次 \(snapshot.unavailablePIDs.count) 个 PID 指标不可用，合计可能偏低。")
                }
                if let snapshot, let first = snapshot.warnings.first { Text(first) }
            }.font(.system(size: 10)).textSelection(.enabled)
            Spacer(minLength: 0)
        }.foregroundStyle(MemoryStyle.secondary).padding(.horizontal, 3)
    }
}

private struct AnalysisConclusionCard: View {
    let analysis: MemoryAnalysis?
    let minutes: Int
    var findingLimit: Int? = nil
    var onLocate: (String) -> Void = { _ in }

    var body: some View {
        MemoryCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    MemorySectionTitle(title: "分析结论", subtitle: analysis.map { "观察窗口 \(minutes) 分钟 · \($0.sampleCount) 份真实样本" } ?? "观察窗口 \(minutes) 分钟 · 等待足够历史样本")
                    Spacer(minLength: 4)
                    MemoryBadge(text: conclusionLabel, color: conclusionColor)
                }
                if let analysis, let start = analysis.start, let end = analysis.end {
                    Text("实际采样：\(MemoryFormat.date(start)) → \(MemoryFormat.date(end))（北京时间）")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                        .textSelection(.enabled)
                }
                if let explanation = analysis?.explanation {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(explanation.headline).font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(conclusionColor)
                        Text(explanation.summary).font(.system(size: 12)).textSelection(.enabled)
                    }
                    if !explanation.evidence.isEmpty {
                        conclusionList(title: "判断依据", values: explanation.evidence, numbered: false)
                    }
                    let findings = visibleFindings(explanation.findings)
                    if !findings.isEmpty {
                        Divider().overlay(MemoryStyle.border)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("重点发现").font(.system(size: 11, weight: .semibold)).foregroundStyle(MemoryStyle.secondary)
                            ForEach(findings) { finding in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: findingIcon(finding.kind)).font(.system(size: 12))
                                        .foregroundStyle(findingColor(finding.kind)).frame(width: 16).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(finding.title).font(.system(size: 12, weight: .medium))
                                        Text(finding.detail).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                                    }.textSelection(.enabled)
                                    if let key = finding.processKey {
                                        Spacer(minLength: 4)
                                        Button { onLocate(key) } label: {
                                            Text("定位进程").font(.system(size: 11)).frame(minHeight: 32).contentShape(Rectangle())
                                        }.buttonStyle(.plain).foregroundStyle(MemoryStyle.accent)
                                    }
                                }
                            }
                            if findings.count < explanation.findings.count {
                                Text("另有 \(explanation.findings.count - findings.count) 条发现，可在“历史与报告”查看。")
                                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                            }
                        }
                    }
                    if !explanation.nextSteps.isEmpty {
                        Divider().overlay(MemoryStyle.border)
                        conclusionList(title: "下一步", values: explanation.nextSteps, numbered: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text((analysis?.sampleCount ?? 0) < 2 ? "等待分析样本" : "等待分析结论")
                            .font(.system(size: 18, weight: .semibold))
                        Text((analysis?.sampleCount ?? 0) < 2
                             ? "至少两份真实采样后，才可判断窗口内的占用变化和来源。开始采集，或等待已有采集器写入历史。"
                             : "已有历史数据尚未生成解释，刷新后查看。当前不能据此判断内存状态。")
                            .font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var conclusionLabel: String {
        guard let kind = analysis?.explanation?.kind else { return "等待分析" }
        switch kind {
        case .insufficientData: return "样本不足"
        case .partialData: return "指标缺失"
        case .growth: return "占用上涨"
        case .reduction: return "占用回落"
        case .littleChange: return "变化较小"
        }
    }

    private var conclusionColor: Color {
        guard let kind = analysis?.explanation?.kind else { return MemoryStyle.secondary }
        switch kind {
        case .insufficientData: return MemoryStyle.secondary
        case .partialData, .growth: return MemoryStyle.orange
        case .reduction: return MemoryStyle.green
        case .littleChange: return MemoryStyle.accent
        }
    }

    private func visibleFindings(_ findings: [AnalysisFinding]) -> [AnalysisFinding] {
        guard let findingLimit, findings.count > findingLimit else { return findings }
        let important = findings.filter { $0.kind == .measurementGap || $0.kind == .memoryPressure }
        let remaining = findings.filter { $0.kind != .measurementGap && $0.kind != .memoryPressure }
        // Missing metrics and system pressure must remain visible in the overview.
        return important + Array(remaining.prefix(max(0, findingLimit - important.count)))
    }

    private func conclusionList(title: String, values: [String], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(MemoryStyle.secondary)
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                HStack(alignment: .top, spacing: 8) {
                    Text(numbered ? "\(index + 1)." : "·")
                        .foregroundStyle(MemoryStyle.accent).frame(width: 16, alignment: .leading)
                    Text(value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.font(.system(size: 11))
            }
        }
    }

    private func findingIcon(_ kind: AnalysisFindingKind) -> String {
        switch kind {
        case .growthProcess: return "arrow.up.right"
        case .sustainedGrowth: return "chart.line.uptrend.xyaxis"
        case .recoveredSpike: return "arrow.down.right"
        case .memoryPressure: return "gauge.with.dots.needle.33percent"
        case .measurementGap: return "exclamationmark.triangle"
        }
    }

    private func findingColor(_ kind: AnalysisFindingKind) -> Color {
        switch kind {
        case .growthProcess, .sustainedGrowth, .measurementGap: return MemoryStyle.orange
        case .memoryPressure: return MemoryStyle.red
        case .recoveredSpike: return MemoryStyle.green
        }
    }
}

private struct GrowthAttribution: View {
    let analysis: MemoryAnalysis?
    var body: some View {
        MemoryCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    MemorySectionTitle(title: "增长归因", subtitle: analysis.map { "\($0.start.map(MemoryFormat.date) ?? "未知") → \($0.end.map(MemoryFormat.date) ?? "未知") · \($0.sampleCount) 份样本" } ?? "需要至少两份历史采样")
                    Spacer()
                    MemoryBadge(text: analysis?.isComplete == true ? "指标完整" : "等待 / 部分指标", color: analysis?.isComplete == true ? MemoryStyle.green : MemoryStyle.orange)
                }
                HStack(spacing: 0) {
                    attribution("新增进程", value: analysis?.addedContributionBytes, detail: "新实例结束时占用", color: MemoryStyle.accent)
                    Divider().frame(height: 44).padding(.horizontal, 20)
                    attribution("退出进程", value: analysis?.exitedContributionBytes, detail: "退出实例的起始占用", color: MemoryStyle.green)
                    Divider().frame(height: 44).padding(.horizontal, 20)
                    attribution("已有进程", value: analysis?.existingChangeBytes, detail: "同一实例净变化", color: MemoryStyle.orange)
                    Divider().frame(height: 44).padding(.horizontal, 20)
                    attribution("无法归因", value: analysis?.unresolvedContributionBytes, detail: "缺失指标单独保留", color: MemoryStyle.secondary)
                }
            }
        }
    }
    private func attribution(_ title: String, value: Int64?, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            Text(value.map(MemoryFormat.delta) ?? "—").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProcessTableRow: Identifiable {
    let sample: ProcessSample
    var id: String { sample.key }
    var pid: Int { sample.pid }
    var parentPID: Int { sample.parentPID }
    var role: String { sample.role.label }
    var executable: String { MemoryFormat.executable(sample.executable) }
    var footprint: UInt64 { sample.footprintBytes }
    var peak: UInt64 { sample.peakFootprintBytes }
    var cpu: Double { sample.cpuPercent ?? -1 }
    var startedAt: Date { sample.startedAt }
}

struct ProcessesContent: View {
    let snapshot: MemorySnapshot?
    @Binding var selectedRole: ProcessRole?
    let isBusy: Bool
    @Binding var focusedKey: String?
    @ObservedObject var actions: MemoryProcessActionsModel
    var history: [MemorySnapshot] = []
    var initiallyExpandedActionHistory = false
    let onDiagnose: (ProcessSample) -> Void
    @State private var search = ""
    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\ProcessTableRow.footprint, order: .reverse)]

    private var rows: [ProcessTableRow] {
        (snapshot?.processes ?? []).filter { p in
            (selectedRole == nil || p.role == selectedRole) && (search.isEmpty || "\(p.pid) \(p.parentPID) \(p.role.label) \(MemoryFormat.executable(p.executable))".localizedCaseInsensitiveContains(search))
        }.map(ProcessTableRow.init).sorted(using: sortOrder)
    }
    private var selectedProcess: ProcessSample? { rows.first { $0.id == selection }?.sample }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(MemoryStyle.secondary)
                    TextField("搜索 PID、角色或程序", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MemoryStyle.secondary) }.buttonStyle(.plain) }
                }.font(.system(size: 12)).padding(10).frame(maxWidth: 320)
                    .background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MemoryStyle.border))
                Picker("角色", selection: $selectedRole) {
                    Text("所有角色").tag(Optional<ProcessRole>.none)
                    ForEach(ProcessRole.allCases, id: \.self) { role in Text(role.label).tag(Optional(role)) }
                }.labelsHidden().frame(width: 170)
                Spacer()
                Text("\(rows.count) 个进程").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                Button { if let selectedProcess { onDiagnose(selectedProcess) } } label: { Label("采集诊断", systemImage: "doc.text.magnifyingglass") }
                    .disabled(selectedProcess == nil || isBusy || actions.isBusy || actions.isObserving).help("对选中的目标手动运行有界 vmmap 摘要")
            }
            HStack(spacing: 12) {
                Button("请求退出") { if let selectedProcess { actions.prepare(selectedProcess, kind: .request, snapshot: snapshot, history: history) } }
                    .disabled((selectedProcess.map { !actions.canRequest($0) } ?? true) || isBusy || actions.isBusy || actions.isObserving)
                Button("强制结束…") { if let selectedProcess { actions.prepare(selectedProcess, kind: .force, snapshot: snapshot, history: history) } }
                    .disabled(isBusy || (selectedProcess.map { !actions.canForce($0) } ?? true))
                Text("先选择目标，正常退出后仍存活时可强制结束。")
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                Spacer()
            }.controlSize(.large)
            if let process = selectedProcess, !actions.canRequest(process) {
                Text("目标可能已退出、归属未确认，或属于观察器及其父进程；请刷新核对。")
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }
            processTable
            if selectedProcess != nil || !actions.records.isEmpty || actions.message != nil || actions.recordError != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    MemoryProcessActionHistory(model: actions, initiallyExpanded: initiallyExpandedActionHistory)
                    if let process = selectedProcess {
                        MemoryCard {
                            HStack(alignment: .top, spacing: 20) {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack { Text("PID \(String(process.pid))").font(.system(size: 14, weight: .semibold)); MemoryBadge(text: process.role.label) }
                                    Text("\(MemoryFormat.executable(process.executable)) · 父进程 \(String(process.parentPID)) · \(MemoryFormat.date(process.startedAt)) 启动")
                                        .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                                    Text("程序：\(process.executable)").font(.system(size: 10)).textSelection(.enabled)
                                    let root = snapshot?.processes.first(where: { $0.key == process.rootKey })
                                    Text("所属应用：\(root.map { MemoryFormat.executable($0.executable) + " · PID " + String($0.pid) } ?? "当前无法确认主进程")")
                                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                                    let children = snapshot?.processes.filter { $0.parentPID == process.pid }.map(\.pid) ?? []
                                    Text("直接子进程：\(children.isEmpty ? "当前未发现" : children.map(String.init).joined(separator: ", "))")
                                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text(MemoryFormat.bytes(process.footprintBytes)).font(.system(size: 20, weight: .semibold, design: .rounded))
                                    Text("会话归属未知").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                                }
                            }
                        }
                    }
                }
            }.frame(minHeight: 0, maxHeight: 220)
            }
            Text("采样保持只读；退出操作需单独确认。RSS 与 Footprint 口径不同，缺失 CPU 显示为未知。")
                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
        }.frame(maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: selectedRole) { _, _ in selection = nil }
            .onAppear { if let focusedKey { search = ""; selection = focusedKey; self.focusedKey = nil } }
            .onChange(of: focusedKey) { _, value in if let value { search = ""; selection = value; focusedKey = nil } }
            .sheet(item: $actions.pending) { request in MemoryProcessActionConfirmation(model: actions, request: request) }
    }

    @ViewBuilder private var processTable: some View {
        if snapshot == nil || rows.isEmpty {
            MemoryCard {
                MemoryEmptyState(icon: "list.bullet.rectangle", title: snapshot == nil ? "尚未完成采样" : "没有匹配的进程", detail: snapshot == nil ? "开始采集或点击刷新，读取本机真实进程。" : "调整搜索和角色筛选；目标未运行时不会生成占位数据。")
                    .frame(maxHeight: .infinity)
            }.frame(maxHeight: .infinity)
        } else {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("PID", value: \.pid) { Text(String($0.pid)).monospacedDigit() }.width(min: 44, ideal: 52)
                TableColumn("PPID", value: \.parentPID) { Text(String($0.parentPID)).foregroundStyle(MemoryStyle.secondary).monospacedDigit() }.width(min: 44, ideal: 52)
                TableColumn("角色", value: \.role) { item in
                    HStack(spacing: 5) { Circle().fill(MemoryStyle.roleColor(item.sample.role)).frame(width: 5, height: 5); Text(item.role).lineLimit(1) }
                }.width(min: 88, ideal: 110)
                TableColumn("程序", value: \.executable).width(min: 85, ideal: 135)
                TableColumn("Footprint", value: \.footprint) { Text(MemoryFormat.bytes($0.footprint)).monospacedDigit() }.width(min: 80, ideal: 90)
                TableColumn("峰值", value: \.peak) { Text(MemoryFormat.bytes($0.peak)).foregroundStyle(MemoryStyle.secondary).monospacedDigit() }.width(min: 75, ideal: 85)
                TableColumn("CPU", value: \.cpu) { Text($0.sample.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "未知").foregroundStyle(MemoryStyle.secondary).monospacedDigit() }.width(min: 42, ideal: 52)
                TableColumn("启动时间", value: \.startedAt) { Text(MemoryFormat.date($0.startedAt)).foregroundStyle(MemoryStyle.secondary).monospacedDigit() }.width(min: 105, ideal: 118)
            }.font(.system(size: 11)).tableStyle(.inset)
                .background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(MemoryStyle.border))
                .frame(minHeight: 180, maxHeight: .infinity)
        }
    }
}

private struct HistoryContent: View {
    let analysis: MemoryAnalysis?
    let snapshot: MemorySnapshot?
    @Binding var minutes: Int
    let isBusy: Bool
    let lastExportURL: URL?
    let aiModel: DesktopAIModel
    let onAIAnalysis: () -> Void
    let onOpenReports: () -> Void
    var onLocate: (String) -> Void = { _ in }
    let onExport: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                WindowPicker(minutes: $minutes)
                Spacer()
                Button(action: onExport) { Label("导出 HTML 报告", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).disabled(isBusy || (analysis?.sampleCount ?? 0) < 2)
            }
            AnalysisConclusionCard(analysis: analysis, minutes: minutes, onLocate: onLocate)
            AIAnalysisCard(model: aiModel, hasInput: (analysis?.sampleCount ?? 0) >= 2, onPrepare: onAIAnalysis,
                           onOpenReports: onOpenReports)
            GrowthAttribution(analysis: analysis)
            if let analysis, analysis.sampleCount >= 2 {
                candidates(analysis)
                changes(analysis)
                events(analysis)
                if !analysis.warnings.isEmpty {
                    MemoryCard {
                        VStack(alignment: .leading, spacing: 8) {
                            MemorySectionTitle(title: "数据提示")
                            ForEach(Array(analysis.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                MemoryCard { MemoryEmptyState(icon: "clock.arrow.circlepath", title: "还没有足够的历史", detail: "至少两份采样后才可分析和导出。当前页面不会用模拟数据填充历史。") }
            }
            if let lastExportURL {
                HStack(spacing: 7) { Image(systemName: "checkmark.circle").foregroundStyle(MemoryStyle.green); Text("最近报告：\(lastExportURL.lastPathComponent)").textSelection(.enabled) }
                    .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            }
            Text("报告离线可读，包含 PID、时间和内存指标；不包含聊天正文与原始命令行。疑似增长仅为定位线索。")
                .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
        }
    }

    private func candidates(_ analysis: MemoryAnalysis) -> some View {
        let span = analysis.start.flatMap { start in analysis.end.map { $0.timeIntervalSince(start) } } ?? 0
        let enoughSamples = analysis.sampleCount >= 11 && span >= 600
        return MemoryCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack { MemorySectionTitle(title: "持续增长候选", subtitle: "完整持续样本满足规则后才列出，不代表已确认泄漏"); Spacer(); MemoryBadge(text: "\(analysis.sustainedGrowthCandidates.count) 个候选", color: MemoryStyle.orange) }
                if analysis.sustainedGrowthCandidates.isEmpty {
                    HStack(spacing: 10) { Image(systemName: enoughSamples ? "checkmark.circle" : "clock").foregroundStyle(enoughSamples ? MemoryStyle.green : MemoryStyle.secondary); Text(enoughSamples ? "当前窗口没有命中持续增长规则。" : "样本时间或数量尚不足以判断持续增长。").font(.system(size: 12)); Spacer() }
                        .padding(.vertical, 9)
                    Text("至少 10 分钟、11 份完整样本、净增长 100 MiB、70% 正增量；未命中也不能排除其他窗口中的问题。")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                } else {
                    ForEach(analysis.sustainedGrowthCandidates, id: \.key) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.right").foregroundStyle(MemoryStyle.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("PID \(item.pid) · \(item.role.label)").font(.system(size: 12, weight: .medium))
                                Text("\(MemoryFormat.executable(item.executable)) · \(item.sampleCount) 份样本").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                            }
                            Spacer()
                            Text(MemoryFormat.delta(item.netGrowthBytes)).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(MemoryStyle.orange)
                        }.padding(.vertical, 5)
                    }
                }
            }
        }
    }

    private func changes(_ analysis: MemoryAnalysis) -> some View {
        MemoryCard {
            VStack(alignment: .leading, spacing: 16) {
                MemorySectionTitle(title: "进程变化", subtitle: "起止样本对账 · 按绝对变化排序")
                ForEach(analysis.topChanges.prefix(12), id: \.key) { item in
                    HStack(spacing: 10) {
                        Circle().fill(MemoryStyle.roleColor(item.role)).frame(width: 6, height: 6)
                        Text("PID \(item.pid)").font(.system(size: 11, weight: .medium)).frame(width: 76, alignment: .leading)
                        Text(item.role.label).font(.system(size: 11)).frame(width: 108, alignment: .leading)
                        Text(MemoryFormat.executable(item.executable)).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).lineLimit(1)
                        Spacer()
                        MemoryBadge(text: changeLabel(item.kind), color: item.kind == .exited ? MemoryStyle.green : MemoryStyle.secondary)
                        Text(item.deltaBytes.map(MemoryFormat.delta) ?? "指标缺失").font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 105, alignment: .trailing)
                    }
                }
                if analysis.topChanges.isEmpty { Text("窗口内没有可显示的进程变化。").font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary) }
            }
        }
    }

    private func events(_ analysis: MemoryAnalysis) -> some View {
        MemoryCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack { MemorySectionTitle(title: "采样事件", subtitle: "创建、退出与指标不可用"); Spacer(); Text("\(analysis.events.count) 条").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary) }
                if analysis.events.isEmpty {
                    Text("当前窗口没有记录到进程生命周期变化。").font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary).padding(.vertical, 8)
                } else {
                    ForEach(Array(analysis.events.suffix(40).reversed().enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .top, spacing: 14) {
                            Text(MemoryFormat.time(event.capturedAt)).font(.system(size: 10, design: .monospaced)).foregroundStyle(MemoryStyle.secondary).frame(width: 60, alignment: .leading)
                            Circle().fill(event.kind == .processExited ? MemoryStyle.green : MemoryStyle.accent).frame(width: 5, height: 5).padding(.top, 5)
                            Text(event.message).font(.system(size: 11)).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                    if analysis.events.count > 40 { Text("显示最近 40 条；导出报告包含本窗口全部事件。").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary) }
                }
            }
        }
    }
    private func changeLabel(_ value: ProcessChangeKind) -> String {
        switch value {
        case .added: return "新增"
        case .exited: return "退出"
        case .existing: return "存量"
        case .unavailableBaseline: return "缺少基线"
        case .unavailableEnd: return "末次缺失"
        }
    }
}

private struct SettingsContent: View {
    @Binding var interval: Double
    let snapshot: MemorySnapshot?
    let databaseURL: URL
    let isMonitoring: Bool
    let modeLabel: String
    let aiModel: DesktopAIModel
    let onOpenDirectory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MemoryCard {
                VStack(alignment: .leading, spacing: 22) {
                    MemorySectionTitle(title: "采样设置", subtitle: "仅调整本观察器，不修改 ChatGPT / Codex 配置")
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("采集间隔").font(.system(size: 13, weight: .medium))
                            Text("较长间隔可减少观察开销，默认 5 秒。").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                        }
                        Spacer()
                        Picker("采集间隔", selection: $interval) {
                            Text("1 秒").tag(1.0); Text("2 秒").tag(2.0); Text("5 秒").tag(5.0); Text("10 秒").tag(10.0)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 235)
                    }
                    Divider().overlay(MemoryStyle.border)
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("当前运行模式").font(.system(size: 13, weight: .medium))
                            Text("同一数据库目录只允许一个写入采集器。").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                        }
                        Spacer()
                        MemoryBadge(text: modeLabel, color: isMonitoring ? MemoryStyle.green : MemoryStyle.secondary)
                    }
                }
            }
            AISettingsView(model: aiModel)
            MemoryCard {
                VStack(alignment: .leading, spacing: 18) {
                    MemorySectionTitle(title: "采集器开销", subtitle: snapshot?.observer?.pid == Int(ProcessInfo.processInfo.processIdentifier) ? "桌面自身单列，避免把观察开销误认成 GPT 增长" : "当前显示历史记录的采集器，PID 不一定是这个桌面窗口")
                    HStack(spacing: 30) {
                        settingMetric("当前 Footprint", value: snapshot?.observer.map { MemoryFormat.bytes($0.footprintBytes) } ?? "未知")
                        settingMetric("峰值 Footprint", value: snapshot?.observer.map { MemoryFormat.bytes($0.peakFootprintBytes) } ?? "未知")
                        settingMetric("采集器 PID", value: snapshot?.observer.map { String($0.pid) } ?? "未知")
                    }
                }
            }
            MemoryCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { MemorySectionTitle(title: "本机历史", subtitle: "常规采样保存在本机；手动 AI 分析发送脱敏摘要"); Spacer(); Button(action: onOpenDirectory) { Label("打开数据目录", systemImage: "folder") } }
                    Text(databaseURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(MemoryStyle.background).clipShape(RoundedRectangle(cornerRadius: 8))
                    HStack(alignment: .top, spacing: 28) {
                        retention("最近 24 小时", detail: "保留全部原始样本", icon: "clock")
                        retention("24 小时至 7 天", detail: "每分钟保留最新样本", icon: "chart.bar.xaxis")
                        retention("超过 7 天", detail: "自动移除旧记录", icon: "archivebox")
                    }
                    Text("历史维护每分钟执行。清空记录前先停止所有使用该数据库的采集器；运行时不要删除锁或 SQLite 附属文件。")
                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
                }
            }
            MemoryCard {
                VStack(alignment: .leading, spacing: 9) {
                    MemorySectionTitle(title: "观测边界")
                    Text("内存采样读取进程和系统指标，MCP 与 REPL 分开统计，会话归属未知。诊断手动运行有界 vmmap 摘要。退出操作需选中目标、核对身份并单独确认，随后检查效果；记录保存在本机。AI 分析需先查看摘要并确认发送，不会自动读取诊断文件；活动说明由你决定是否填写。")
                        .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                    Text("Codex 会话只读原日志；标题、用量和用户提问的搜索摘要保存在本机，以加快再次打开。日志变更后更新摘要，索引损坏时重新读取。收藏、本地名称和备注单独保存在本机，重启后继续使用。")
                        .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func settingMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary); Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func retention(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(MemoryStyle.accent).font(.system(size: 12)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 11, weight: .medium)); Text(detail).font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
