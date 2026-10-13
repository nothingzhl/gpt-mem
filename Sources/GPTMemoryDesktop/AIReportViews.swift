import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GPTAnalysisKit
import GPTSessionKit

struct AIReportsContent: View {
    @ObservedObject var model: AIReportLibraryModel
    @State private var handoffReport: AISavedReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            AIReportSaveStatus(model: model, includesLibraryErrors: true)
            if let status = model.statusMessage {
                HStack(spacing: 10) {
                    Text(status).font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary).textSelection(.enabled)
                    if model.canUndoRemoval { Button("撤销移除") { model.undoRemoval() }.font(.system(size: 11)) }
                    if let url = model.lastExportURL {
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .font(.system(size: 11))
                    }
                }
            }
            if !model.warnings.isEmpty {
                DisclosureGroup("读取提示（\(model.warnings.count)）") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(height: 100)
                }.font(.system(size: 11)).foregroundStyle(MemoryStyle.orange)
            }
            HStack(alignment: .top, spacing: 14) {
                reportList.frame(width: 278)
                reportDetail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxHeight: .infinity)
        }
        .disclosureGroupStyle(WideDisclosureGroupStyle())
        .task { model.loadIfNeeded() }
        .sheet(item: $handoffReport) { report in
            SessionHandoffEditor(initialText: SessionHandoffAIModule.markdown(record: report.record,
                input: report.input, subjectLabels: report.subjectLabels))
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("搜索结论、模块、来源或模型", text: $model.query).textFieldStyle(.roundedBorder)
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
            }
            Picker("分析模块", selection: $model.selectedModuleID) {
                Text("全部模块").tag(Optional<String>.none)
                ForEach(model.moduleChoices) { module in
                    Text(module.title).tag(Optional(module.id))
                }
            }.frame(maxWidth: 190)
            if model.isLoading || model.isFiltering || model.isSaving || model.isExporting || model.isRemoving {
                ProgressView().controlSize(.small)
            }
            Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .disabled(model.isLoading)
        }
    }

    private var reportList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("已保存的 AI 报告").font(.system(size: 13, weight: .semibold))
                Spacer()
                MemoryBadge(text: "\(model.filteredReports.count)")
            }.padding(14)
            Rectangle().fill(MemoryStyle.border).frame(height: 1)
            if model.filteredReports.isEmpty {
                MemoryEmptyState(icon: "doc.text", title: model.isLoading ? "正在读取报告" : (model.reports.isEmpty ? "还没有保存的报告" : "没有匹配的报告"),
                    detail: model.reports.isEmpty ? "完成一次 AI 分析后，结论和冻结的依据会自动保存在这里。" : "调整搜索或模块筛选。")
                    .padding(.horizontal, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.filteredReports) { report in
                            Button { model.select(report.id) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(report.record.result.summary.prefix(180)).font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(MemoryStyle.text).lineLimit(2)
                                    Text("\(report.record.moduleTitle) · \(MemoryFormat.fullDate(report.record.generatedAt))")
                                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).lineLimit(1)
                                    Text("\(report.record.providerName) · \(report.record.model)")
                                        .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary).lineLimit(1)
                                }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.selectedReportID == report.id ? MemoryStyle.accentBackground : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.isFiltering)
                        }
                    }.padding(8)
                }
            }
            Spacer(minLength: 0)
        }.frame(maxHeight: .infinity, alignment: .topLeading)
            .background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MemoryStyle.border))
    }

    @ViewBuilder private var reportDetail: some View {
        if model.isFiltering {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("更新筛选…").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = model.selectedReport {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(report.record.moduleTitle).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if report.input.moduleID == SessionHandoffAIModule.moduleID {
                        Button("继续工作") { handoffReport = report }
                    }
                    Menu("导出") {
                        Button("导出 Markdown…") { export(report, format: .markdown) }
                        Button("导出 JSON…") { export(report, format: .json) }
                    }.disabled(model.isExporting || model.isFiltering)
                    Button { model.removeSelectedReport() } label: { Image(systemName: "trash") }
                        .disabled(model.isRemoving || model.isFiltering).help("移除到本机报告回收区，可撤销")
                        .accessibilityLabel("移除报告")
                }
                ScrollView {
                    MemoryCard {
                        AIAnalysisResultContent(record: report.record, input: report.input,
                            subjectLabels: report.subjectLabels, isStale: false, isHistorical: true)
                    }
                }
                Text(report.input.presentation?.privacyNotice ?? "导出包含结论、匿名依据和活动说明；不包含本地 PID 映射或服务密钥。")
                    .font(.system(size: 10)).foregroundStyle(MemoryStyle.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            MemoryEmptyState(icon: "doc.text.magnifyingglass", title: "选择一份报告", detail: "查看生成时的结论和完整依据，或导出为 Markdown、JSON。")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MemoryStyle.surface).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func export(_ report: AISavedReport, format: AIReportExportFormat) {
        let panel = NSSavePanel()
        panel.title = "导出 AI 报告"
        panel.allowedContentTypes = format == .markdown ? [UTType(filenameExtension: "md") ?? .plainText] : [.json]
        panel.nameFieldStringValue = format == .markdown ? "AI-分析报告.md" : "AI-分析报告.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportReport(report, to: url, format: format)
    }
}

struct AIReportSaveStatus: View {
    @ObservedObject var model: AIReportLibraryModel
    var includesLibraryErrors = false

    var body: some View {
        if model.isSaving {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("正在保存 AI 报告…").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            }
        } else if let error = includesLibraryErrors ? model.errorMessage : model.saveErrorMessage {
            VStack(alignment: .leading, spacing: 6) {
                Text(error).font(.system(size: 11)).foregroundStyle(MemoryStyle.orange).textSelection(.enabled)
                if model.canRetrySave {
                    Button("重新保存报告") { model.retrySave() }.font(.system(size: 11)).disabled(model.isSaving)
                }
            }
        }
    }
}
