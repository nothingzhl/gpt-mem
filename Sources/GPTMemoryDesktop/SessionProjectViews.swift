import SwiftUI
import Charts
import GPTSessionKit

struct SessionProjectsContent: View {
    @ObservedObject var model: SessionDesktopModel
    var showStatistics = false
    var onShowStatistics: () -> Void = {}
    let onOpenProject: (SessionProjectSummary) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if (!model.hasLoaded || model.isLoading) && model.sessions.isEmpty {
                    MemoryEmptyState(icon: "folder", title: "正在读取本地项目", detail: "索引在后台建立，完成后显示项目和统计。")
                } else if model.sessions.isEmpty {
                    MemoryEmptyState(icon: "folder", title: model.errorMessage == nil ? "暂无 Codex 项目" : "无法读取项目",
                                     detail: model.errorMessage == nil ? "使用 Codex 后点击刷新，即可按会话中的项目路径查看项目。" : "检查上方读取提示后点击刷新，重新读取本地会话。")
                } else if model.isFiltering && model.analytics.projects.isEmpty {
                    MemoryEmptyState(icon: "folder", title: "正在筛选项目", detail: "正在后台更新项目和统计。")
                } else if model.analytics.projects.isEmpty {
                    MemoryEmptyState(icon: "folder", title: "没有匹配的项目", detail: "调整搜索词、归档开关或项目筛选。")
                } else {
                    overview
                    if showStatistics {
                    HStack(alignment: .top, spacing: 14) {
                        projectUsageChart.frame(maxWidth: .infinity)
                        modelDistributionChart.frame(maxWidth: .infinity)
                    }
                    activityChart
                    } else {
                    HStack {
                        MemorySectionTitle(title: "项目", subtitle: "按最近活动排序，点击项目查看其中的会话。")
                        Spacer()
                        Button("查看统计图表", action: onShowStatistics)
                            .font(.system(size: 11)).buttonStyle(.link)
                        if model.selectedProject != nil {
                            Button("查看全部项目") { model.selectedProject = nil }
                                .font(.system(size: 11)).buttonStyle(.link)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                        ForEach(model.analytics.projects) { project in
                            Button { onOpenProject(project) } label: { projectCard(project) }
                                .buttonStyle(.plain).disabled(model.isFiltering)
                        }
                    }
                    }
                }
            }.padding(.bottom, 12)
        }
    }

    private var overview: some View {
        HStack(spacing: 12) {
            compactMetric("项目", value: "\(model.analytics.projects.count)",
                          detail: "\(model.analytics.totalSessionCount) 个会话", icon: "folder")
            compactMetric("已记录用量", value: model.total(\.effectiveTotal).displayValue,
                          detail: "\(model.analytics.sessionsWithUsage) / \(model.analytics.totalSessionCount) 个会话有总用量", icon: "chart.bar")
            compactMetric("末次模型", value: "\(model.analytics.models.count)",
                          detail: "按会话中最后记录的模型分组", icon: "cpu")
        }
    }

    private func compactMetric(_ title: String, value: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(MemoryStyle.accent).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(detail).font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MemoryStyle.border))
    }

    private var rankedProjects: [SessionProjectSummary] {
        Array(model.analytics.projects.filter { $0.tokens.effectiveTotal != nil }.sorted {
            let left = $0.tokens.effectiveTotal ?? 0, right = $1.tokens.effectiveTotal ?? 0
            return left == right ? $0.id < $1.id : left > right
        }.prefix(6))
    }

    private var projectUsageChart: some View {
        MemoryCard {
            VStack(alignment: .leading, spacing: 12) {
                MemorySectionTitle(title: "项目用量排行", subtitle: "按完整会话的已记录总 Token · 前六项")
                if rankedProjects.isEmpty {
                    chartEmpty("日志尚未记录总用量")
                } else {
                    Chart(rankedProjects) { project in
                        BarMark(x: .value("已记录 Token", project.tokens.effectiveTotal ?? 0),
                                y: .value("项目", project.id))
                            .foregroundStyle(MemoryStyle.accent.gradient)
                            .cornerRadius(4)
                            .annotation(position: .trailing) {
                                Text(SessionProjectFormat.compact(project.tokens.effectiveTotal ?? 0))
                                    .font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
                            }
                    }.chartYAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let id = value.as(String.self), let project = rankedProjects.first(where: { $0.id == id }) {
                                    Text(projectLabel(project)).font(.system(size: 9)).lineLimit(1)
                                }
                            }
                        }
                    }.chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(MemoryStyle.border)
                            AxisValueLabel {
                                if let count = value.as(Int.self) { Text(SessionProjectFormat.compact(count)).font(.system(size: 9)) }
                            }
                        }
                    }.chartYScale(domain: rankedProjects.map(\.id))
                        .frame(height: 175).padding(.trailing, 26)
                }
                Text("缺失用量未填为零；柱长表示已知合计。")
                    .font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
            }
        }
    }

    private func projectLabel(_ project: SessionProjectSummary) -> String {
        let sameNames = model.analytics.projects.filter { $0.displayName == project.displayName }
        guard sameNames.count > 1, let path = project.projectPath else { return String(project.displayName.prefix(20)) }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return "\(String(project.displayName.prefix(12))) · \(String(parent.prefix(10)))"
    }

    private var modelBuckets: [ModelChartBucket] {
        let models = model.analytics.models
        var buckets = models.prefix(5).map { ModelChartBucket(id: $0.id, name: $0.name, count: $0.sessionCount) }
        if models.count > 5 {
            buckets.append(.init(id: "other-models", name: "其他模型（合并）", count: models.dropFirst(5).reduce(0) { $0 + $1.sessionCount }))
        }
        return buckets
    }

    private var modelDistributionChart: some View {
        MemoryCard {
            VStack(alignment: .leading, spacing: 12) {
                MemorySectionTitle(title: "模型分布", subtitle: "按会话末次记录的模型统计会话数")
                if modelBuckets.isEmpty {
                    chartEmpty("没有可统计的会话")
                } else {
                    Chart(modelBuckets) { bucket in
                        SectorMark(angle: .value("会话数", bucket.count), innerRadius: .ratio(0.66), angularInset: 2)
                            .foregroundStyle(by: .value("模型", bucket.name))
                    }.chartForegroundStyleScale(range: [MemoryStyle.accent, MemoryStyle.green,
                        Color(red: 0.68, green: 0.48, blue: 0.88), MemoryStyle.orange,
                        Color(red: 0.36, green: 0.65, blue: 0.84), MemoryStyle.secondary])
                        .chartLegend(position: .bottom, spacing: 6)
                        .chartBackground { proxy in
                            GeometryReader { geometry in
                                if let anchor = proxy.plotFrame {
                                    let frame = geometry[anchor]
                                    VStack(spacing: 3) {
                                        Text("\(model.analytics.totalSessionCount)")
                                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                                        Text("会话").font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
                                    }.position(x: frame.midX, y: frame.midY)
                                }
                            }
                        }.frame(height: 175)
                }
                Text("会话可能切换模型；此图不代表各模型的实际 Token 消耗。")
                    .font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary).lineLimit(2)
            }
        }
    }

    private var activityChart: some View {
        MemoryCard {
            VStack(alignment: .leading, spacing: 12) {
                MemorySectionTitle(title: "会话活跃情况", subtitle: "按会话开始日期统计 · 北京时间 · 最近最多 30 天")
                if model.analytics.activity.isEmpty {
                    chartEmpty("会话开始时间未记录")
                } else {
                    Chart(model.analytics.activity) { point in
                        BarMark(x: .value("日期", point.date, unit: .day), y: .value("新会话", point.sessionCount))
                            .foregroundStyle(MemoryStyle.accent.opacity(0.75)).cornerRadius(3)
                    }.chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { value in
                            AxisGridLine().foregroundStyle(MemoryStyle.border)
                            AxisValueLabel {
                                if let date = value.as(Date.self) { Text(SessionProjectFormat.day(date)).font(.system(size: 9)) }
                            }
                        }
                    }.chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                        .frame(height: 130)
                }
                Text(activityNote).font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
            }
        }
    }

    private var activityNote: String {
        var text = "日期范围截至已加载会话中最新的开始日期，统计新会话数量。"
        if model.analytics.missingStartDateCount > 0 { text += " \(model.analytics.missingStartDateCount) 个会话缺少开始时间。" }
        if model.analytics.activityWindowExcludedSessionCount > 0 { text += " \(model.analytics.activityWindowExcludedSessionCount) 个更早会话不在图中。" }
        return text
    }

    private func projectCard(_ project: SessionProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(MemoryStyle.accent)
                Text(project.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }
            Text(project.projectPath ?? "日志未记录项目路径").font(.system(size: 10))
                .foregroundStyle(MemoryStyle.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                Text("\(project.sessionCount) 个会话 · \(project.modelCount) 个已记录模型")
                Spacer()
                Text("\(project.toolCallCount) 次工具")
            }.font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            HStack {
                Text("Token \(projectUsageText(project))").font(.system(size: 12, weight: .medium)).monospacedDigit()
                Spacer()
                Text(project.lastActivity.map(MemoryFormat.date) ?? "活动时间未记录")
                    .font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
            }
            if project.missingUsageSessionCount > 0 {
                Text("\(project.missingUsageSessionCount) 个会话未记录总用量")
                    .font(.system(size: 9)).foregroundStyle(MemoryStyle.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MemoryStyle.border))
    }

    private func projectUsageText(_ project: SessionProjectSummary) -> String {
        guard !project.hasTokenOverflow else { return "部分统计超出范围" }
        guard let total = project.tokens.effectiveTotal else { return "未记录" }
        return (project.missingUsageSessionCount > 0 ? "≥ " : "") + total.formatted(.number.locale(Locale(identifier: "zh_CN")))
    }

    private func chartEmpty(_ detail: String) -> some View {
        Text(detail).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            .frame(maxWidth: .infinity).frame(height: 175)
    }
}

private struct ModelChartBucket: Identifiable {
    let id: String
    let name: String
    let count: Int
}

private enum SessionProjectFormat {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "MM-dd"
        return formatter
    }()
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func compact(_ value: Int) -> String {
        if value >= 100_000_000 { return String(format: "%.1f亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        return String(value)
    }
}
