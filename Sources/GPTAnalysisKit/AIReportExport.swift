import Foundation

/// Public exports use an explicit allowlist. Native PID mappings, service identity,
/// fingerprint, credentials and connection settings are never serialized here.
public enum AIReportExport {
    public static func markdown(_ report: AISavedReport) throws -> String {
        try report.validate()
        let input = report.input, record = report.record, result = record.result
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["# AI 分析报告", "", "- 分析模块：\(escape(input.moduleTitle))",
                     "- 来源：\(escape(record.providerName))", "- 模型：\(escape(record.model))",
                     "- 生成时间：\(formatter.string(from: record.generatedAt))",
                     "- 实际观察窗口：\(formatter.string(from: input.windowStart)) 至 \(formatter.string(from: input.windowEnd))",
                     "- 实际窗口长度：\(String(format: "%.3f", input.windowEnd.timeIntervalSince(input.windowStart))) 秒",
                     "", "## 概要", "", escape(result.summary), "", "## " + escape(input.presentation?.evidenceTitle ?? "事实观察"), ""]
        for observation in result.observations {
            lines += ["- \(escape(observation.text))", "  - 引用证据：\(observation.evidenceIDs.map(escape).joined(separator: "、"))"]
        }
        lines += ["", "## " + escape(input.presentation?.hypothesesTitle ?? "原因假设"), ""]
        if result.hypotheses.isEmpty { lines.append(input.presentation == nil ? "本次报告没有提出原因假设。" : "本次没有提出待确认问题。") }
        for hypothesis in result.hypotheses {
            lines += ["### \(escape(hypothesis.title))", "", escape(hypothesis.explanation), "",
                      "- 引用证据：\(hypothesis.evidenceIDs.map(escape).joined(separator: "、"))"]
            for missing in hypothesis.missingEvidence { lines.append("- 待补证据：\(escape(missing))") }
            lines.append("")
        }
        lines += ["", "## " + escape(input.presentation?.nextStepsTitle ?? "检查建议"), ""]
        for (index, step) in result.nextSteps.enumerated() {
            let subject = step.subjectID.flatMap { id in input.subjects.first { $0.id == id } }
            lines += ["\(index + 1). \(escape(step.action))", "   - 目的：\(escape(step.purpose))"]
            if let subject { lines.append("   - 匿名对象：\(escape(subject.label))（\(escape(subject.id))）") }
        }
        lines += ["", "## 限制", ""]
        for limitation in result.limitations { lines.append("- \(escape(limitation))") }
        if let prompt = input.prompt {
            lines += ["", "## 使用提示词", "", escape(prompt.title) + (prompt.revision.map { " · v\($0)" } ?? "") + (prompt.isModified ? " · 本次已调整" : ""),
                      "", escape(prompt.text)]
        }
        lines += ["", "## 活动说明", "", input.context.isEmpty ? "未填写活动说明。" : escape(input.context),
                  "", "## 分析说明", "", escape(input.guidance), "", "## 匿名对象", ""]
        if input.subjects.isEmpty { lines.append("本次没有独立匿名对象。") }
        for subject in input.subjects {
            lines.append("- \(escape(subject.id))：\(escape(subject.label))；生成报告时\(subject.canInspect ? "可检查" : "不可直接检查")")
        }
        lines += ["", "## 冻结证据", ""]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for fact in input.facts {
            lines += ["### \(escape(fact.title))（\(escape(fact.id))）", ""]
            let encoded = try encoder.encode(fact.data)
            guard let json = String(data: encoded, encoding: .utf8) else { throw AIReportStoreError.invalidReport("证据编码失败。") }
            // Indented code cannot be terminated by a model-supplied fenced delimiter.
            // Encode HTML punctuation as JSON Unicode escapes to keep the data literal.
            lines += safeJSONText(json).components(separatedBy: "\n").map { "    " + $0 }
            lines.append("")
        }
        lines += ["", escape(input.presentation?.interpretation ?? "AI 原因假设需要后续验证。此报告保存的是生成时的证据和对象状态，不能代表当前状态。"),
                  "导出不包含本地 PID 映射、来源内部编号、请求指纹或服务连接配置。", ""]
        if let notice = input.presentation?.privacyNotice { lines += [escape(notice), ""] }
        let markdown = lines.joined(separator: "\n")
        guard markdown.utf8.count <= 1_048_576 else { throw AIReportStoreError.oversizedReport }
        return markdown
    }

    public static func json(_ report: AISavedReport) throws -> Data {
        try report.validate()
        let document = PublicReport(schemaVersion: 1, moduleID: report.input.moduleID,
                                    moduleTitle: report.input.moduleTitle, promptVersion: report.input.promptVersion,
                                    providerName: report.record.providerName, model: report.record.model,
                                    generatedAt: report.record.generatedAt,
                                    windowStart: report.input.windowStart, windowEnd: report.input.windowEnd,
                                    durationSeconds: report.input.windowEnd.timeIntervalSince(report.input.windowStart),
                                    activityContext: report.input.context, analysisGuidance: report.input.guidance,
                                    facts: report.input.facts, subjects: report.input.subjects,
                                    result: report.record.result,
                                    interpretation: report.input.presentation?.interpretation ?? "AI 原因假设需要后续验证；对象状态与证据反映生成时的观察窗口。",
                                    presentation: report.input.presentation,
                                    prompt: report.input.prompt.map { PublicPrompt(title: $0.title, revision: $0.revision, text: $0.text, isModified: $0.isModified) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Numeric Unix times preserve subsecond windows in a portable, explicit form.
        encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try encoder.encode(document)
        guard let text = String(data: encoded, encoding: .utf8) else { throw AIReportStoreError.invalidReport("报告编码失败。") }
        let data = Data(safeJSONText(text).utf8)
        guard data.count <= 1_048_576 else { throw AIReportStoreError.oversizedReport }
        return data
    }

    private struct PublicReport: Encodable {
        let schemaVersion: Int
        let moduleID: String
        let moduleTitle: String
        let promptVersion: String
        let providerName: String
        let model: String
        let generatedAt: Date
        let windowStart: Date
        let windowEnd: Date
        let durationSeconds: TimeInterval
        let activityContext: String
        let analysisGuidance: String
        let facts: [AIAnalysisFact]
        let subjects: [AIAnalysisSubject]
        let result: AIAnalysisResult
        let interpretation: String
        let presentation: AIAnalysisPresentation?
        let prompt: PublicPrompt?
    }

    private struct PublicPrompt: Encodable {
        let title: String
        let revision: Int?
        let text: String
        let isModified: Bool
    }

    private static func safeJSONText(_ value: String) -> String {
        value.replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func escape(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let punctuation = Set("\\`*_{}[]()#+-.!|~:".unicodeScalars)
        var output = ""
        for scalar in normalized.unicodeScalars {
            switch scalar {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            default:
                if punctuation.contains(scalar) { output += "\\" }
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}
