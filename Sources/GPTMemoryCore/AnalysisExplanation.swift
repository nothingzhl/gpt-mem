import Foundation

public enum AnalysisConclusionKind: String, Codable {
    case insufficientData, partialData, growth, reduction, littleChange
}

public enum AnalysisFindingKind: String, Codable {
    case growthProcess, sustainedGrowth, recoveredSpike, memoryPressure, measurementGap
}

public struct AnalysisFinding: Codable, Identifiable {
    public let id: String
    public let kind: AnalysisFindingKind
    public let title: String
    public let detail: String
    public let processKey: String?
    public let pid: Int?
}

public struct AnalysisExplanation: Codable {
    public let kind: AnalysisConclusionKind
    public let headline: String
    public let summary: String
    public let evidence: [String]
    public let findings: [AnalysisFinding]
    public let nextSteps: [String]
}

/// Turns the existing numerical analysis into local, evidence-based guidance.
/// It uses all snapshots for peaks and process identities without changing the
/// original reconciliation or the sustained-growth candidate rules.
enum AnalysisInterpreter {
    private static let mib: Int64 = 1_048_576

    private enum ContributionKind {
        case added, existing, unresolved, exited

        var label: String {
            switch self {
            case .added: return "新增进程"
            case .existing: return "存量进程"
            case .unresolved: return "未归因项"
            case .exited: return "退出进程"
            }
        }
    }

    private struct PositiveProcess {
        let sample: ProcessSample
        let startBytes: UInt64
        let deltaBytes: Int64
    }

    static func interpret(snapshots: [MemorySnapshot], analysis: MemoryAnalysis) -> AnalysisExplanation {
        let first = snapshots.first
        let last = snapshots.last
        let span = first.flatMap { start in last.map { $0.capturedAt.timeIntervalSince(start.capturedAt) } } ?? 0
        let missing = snapshots.filter { !$0.unavailablePIDs.isEmpty }
        let insufficient = snapshots.count < 2 || span <= 0
        let partial = !missing.isEmpty || !analysis.isComplete
        let kind: AnalysisConclusionKind
        if insufficient { kind = .insufficientData }
        else if partial { kind = .partialData }
        else if analysis.totalChangeBytes >= 10 * mib { kind = .growth }
        else if analysis.totalChangeBytes <= -10 * mib { kind = .reduction }
        else { kind = .littleChange }

        let positiveSources: [(ContributionKind, Int64)] = [
            (.added, analysis.addedContributionBytes),
            (.existing, analysis.existingChangeBytes),
            (.unresolved, analysis.unresolvedContributionBytes)
        ]
        let mainPositive = positiveSources.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
        let largestAdded = largestAddedProcess(first: first, last: last)
        var evidence = [
            "观察窗口：\(duration(max(0, span)))，\(analysis.sampleCount) 份样本。",
            "四项对账：新增 \(delta(analysis.addedContributionBytes)) + 退出 \(delta(analysis.exitedContributionBytes)) + 存量 \(delta(analysis.existingChangeBytes)) + 未归因 \(delta(analysis.unresolvedContributionBytes)) = 已测净变化 \(delta(analysis.totalChangeBytes))。"
        ]
        if first != nil, last != nil {
            evidence.insert("已测总占用：\(bytes(analysis.startTotalBytes)) → \(bytes(analysis.endTotalBytes))。", at: 1)
        }
        if !insufficient, let mainPositive {
            let qualifier = partial ? "按已测值对账，" : "按起止对账，"
            var source = "\(qualifier)最大正向来源是\(mainPositive.0.label)，贡献 \(delta(mainPositive.1))。"
            if analysis.exitedContributionBytes < 0 {
                source += "退出进程贡献 \(delta(analysis.exitedContributionBytes))，抵消了部分正向增长。"
            }
            evidence.append(source)
            if mainPositive.0 == .added, let p = largestAdded {
                evidence.append("已测新增实例中，末次占用最大的是 \(p.role.label) PID \(p.pid)（\(name(p.executable))），末次占用 \(bytes(p.footprintBytes))。这是新增实例的占用，不能仅据新增判断泄漏。")
            }
        }

        let positiveProcesses = positiveExistingProcesses(first: first, last: last)
        var findings: [AnalysisFinding] = []
        if !insufficient {
            for process in positiveProcesses {
                let p = process.sample
                let qualifier = partial ? "这是已测值变化；区间有缺测，不能据此确认总体增长或泄漏。" : "起止增长本身不能确认内存泄漏。"
                findings.append(AnalysisFinding(
                    id: "growth:\(p.key)", kind: .growthProcess,
                    title: "\(p.role.label) PID \(p.pid) 增加 \(magnitude(process.deltaBytes))",
                    detail: "\(name(p.executable)) 从 \(bytes(process.startBytes)) 增至 \(bytes(p.footprintBytes))（\(delta(process.deltaBytes))）；启动时间 \(startTime(p.startedAt))。\(qualifier)",
                    processKey: p.key, pid: p.pid))
            }
        }

        var activeCandidates: [GrowthCandidate] = []
        for candidate in analysis.sustainedGrowthCandidates {
            let current = last?.processes.first { $0.key == candidate.key }
            let isPresent = current != nil
            let isUnavailable = last.map { snapshot in
                snapshot.unavailablePIDs.contains(candidate.pid)
                    && !snapshot.processes.contains { $0.pid == candidate.pid }
            } ?? false
            let state: String
            if isPresent {
                state = "当前仍观测到该启动身份；"
                activeCandidates.append(candidate)
            } else if isUnavailable {
                state = "窗口结束时未取得该启动身份的指标，当前状态未知；"
            } else {
                state = "该启动身份已退出；退出前"
            }
            var detail = "\(state)在 \(duration(candidate.end.timeIntervalSince(candidate.start))) 内净增长 \(magnitude(candidate.netGrowthBytes))，\(candidate.sampleCount) 份样本中 \(String(format: "%.0f%%", candidate.positiveIncrementFraction * 100)) 的相邻采样出现正增量。"
            if let current { detail += "启动时间 \(startTime(current.startedAt))。" }
            detail += "这是持续增长候选，尚未确诊内存泄漏。"
            if partial { detail += "窗口存在缺测，以上仅为该完整候选片段的已测证据。" }
            if candidate.role == .gpu { detail += "GPU/图形增长还需结合绘制活动判断。" }
            findings.append(AnalysisFinding(
                id: "sustained:\(candidate.key)", kind: .sustainedGrowth,
                title: "\(candidate.role.label) PID \(candidate.pid) \(isPresent ? "出现" : "曾出现")持续增长候选",
                detail: detail, processKey: candidate.key, pid: candidate.pid))
        }

        var recoveredSpike = false
        if !insufficient, !partial, let first, let last,
           let peak = snapshots.max(by: { $0.totalFootprintBytes < $1.totalFootprintBytes }) {
            let peakValue = Int64(clamping: peak.totalFootprintBytes)
            let rise = peakValue - Int64(clamping: first.totalFootprintBytes)
            let fall = peakValue - Int64(clamping: last.totalFootprintBytes)
            if rise >= 100 * mib, fall >= 100 * mib {
                recoveredSpike = true
                findings.append(AnalysisFinding(
                    id: "recovered-spike", kind: .recoveredSpike,
                    title: "窗口内出现明显尖峰，随后回落",
                    detail: "峰值 \(bytes(peak.totalFootprintBytes))，比起始高 \(magnitude(rise))，结束时已回落 \(magnitude(fall))。回落不能证明没有异常，应结合峰值附近的页面或工具活动判断。",
                    processKey: nil, pid: nil))
            }
        }

        let pressure = last?.system.pressureLevel
        if pressure == 2 || pressure == 4 {
            let level = pressure == 4 ? "严重" : "警告"
            findings.append(AnalysisFinding(
                id: "memory-pressure", kind: .memoryPressure,
                title: "系统末次内存压力为\(level)",
                detail: "最后一份样本的系统内存压力为\(level)（级别 \(pressure!)）。这是全系统信号，不能单凭它将压力归因到 GPT；需要结合其他应用、压缩内存和交换空间观察。",
                processKey: nil, pid: nil))
        }
        if !missing.isEmpty {
            let pids = Set(missing.flatMap(\.unavailablePIDs)).sorted()
            let examples = pids.prefix(3).map(String.init).joined(separator: "、")
            findings.append(AnalysisFinding(
                id: "measurement-gap", kind: .measurementGap,
                title: "\(missing.count) 份样本存在缺测",
                detail: "\(pids.count) 个 PID 未取得指标\(examples.isEmpty ? "" : "（例如 \(examples)）")。缺失项没有当成零或退出，已测净变化不能代表完整变化，也不能用它确认泄漏。",
                processKey: nil, pid: nil))
        }

        let headline: String
        var summary: String
        switch kind {
        case .insufficientData:
            headline = "样本不足，暂时无法判断内存趋势"
            summary = snapshots.isEmpty ? "还没有可分析的快照。" : "需要至少两份时间不同的快照，才能比较起止变化；当前不能判断增长、回落或泄漏。"
        case .partialData:
            headline = "采样不完整，暂时无法确认总体趋势"
            summary = "已测总占用净变化 \(delta(analysis.totalChangeBytes))，但区间存在缺测。这仅是已测值的变化，不能代表完整总量，也不能确认内存泄漏。"
        case .growth:
            headline = "总占用增加 \(magnitude(analysis.totalChangeBytes))"
            summary = mainPositive.map { "最大正向来源是\($0.0.label)，贡献 \(delta($0.1))。" } ?? "起止总占用明显增加。"
            if analysis.exitedContributionBytes < 0 { summary += "退出进程释放的内存抵消了部分增长。" }
            summary += "增长是定位线索，尚未确认内存泄漏。"
        case .reduction:
            headline = "总占用下降 \(magnitude(analysis.totalChangeBytes))"
            let mainNegative = [(ContributionKind.exited, analysis.exitedContributionBytes), (.existing, analysis.existingChangeBytes), (.unresolved, analysis.unresolvedContributionBytes)].filter { $0.1 < 0 }.min { $0.1 < $1.1 }
            summary = mainNegative.map { "最大下降来源是\($0.0.label)，贡献 \(delta($0.1))。" } ?? "起止总占用下降。"
            summary += "总量下降仍可能包含个别进程增长或窗口内尖峰。"
        case .littleChange:
            headline = "起止总占用变化较小"
            summary = "净变化 \(delta(analysis.totalChangeBytes))，低于 10 MiB 的变化阈值。新增和退出、不同存量进程的变化可能相互抵消，起止接近不代表窗口内没有异常。"
        }
        if !insufficient, mainPositive?.0 == .added, let p = largestAdded {
            summary += "末次占用最大的已测新增实例是 \(p.role.label) PID \(p.pid)（\(name(p.executable))），占用 \(bytes(p.footprintBytes))。"
        }
        if !insufficient, analysis.sustainedGrowthCandidates.isEmpty {
            summary += "当前窗口未命中持续增长候选，不能排除其他窗口中的问题。"
        }

        var nextSteps: [String] = []
        if !missing.isEmpty {
            nextSteps.append("先补齐未取得指标的进程采样，再重新判断总占用和增长来源。")
        }
        if !insufficient, mainPositive?.0 == .added {
            if let p = largestAdded {
                nextSteps.append("核对 \(p.role.label) PID \(p.pid)（\(name(p.executable))）及启动时间 \(startTime(p.startedAt))，确认是否对应窗口中新开的页面、会话或工具；新增实例的占用不能单独证明泄漏。")
            } else {
                nextSteps.append("核对观察窗口中新开的页面、会话和工具；新增进程占用应先与这些活动对应。")
            }
        }
        if !insufficient {
            if !activeCandidates.isEmpty {
                for candidate in activeCandidates.prefix(3) {
                    guard let current = last?.processes.first(where: { $0.key == candidate.key }) else { continue }
                    nextSteps.append("到进程明细核对 \(candidate.role.label) PID \(candidate.pid) 和启动时间 \(startTime(current.startedAt))；确认仍是该实例后，手动采集诊断摘要并比较下一窗口。")
                }
            } else if let process = positiveProcesses.first,
                      !analysis.sustainedGrowthCandidates.contains(where: { $0.key == process.sample.key }) {
                let p = process.sample
                nextSteps.append("到进程明细核对 \(p.role.label) PID \(p.pid) 和启动时间 \(startTime(p.startedAt))；若该实例继续增长，再手动采集诊断摘要。")
            }
        }
        if insufficient || analysis.sustainedGrowthCandidates.isEmpty {
            if span < 600 || snapshots.count < 11 || !missing.isEmpty {
                nextSteps.append("继续采样至少 10 分钟，积累至少 11 份完整样本，再判断持续增长。")
            } else {
                nextSteps.append("若增长再次出现，在复现活动后保留至少 10 分钟、11 份完整样本，比较同一启动身份的趋势。")
            }
        } else if activeCandidates.isEmpty {
            nextSteps.append("候选实例已退出或末次状态未知；复现原活动并取得新实例的完整样本，再核对新实例的 PID 和启动时间。")
        }
        if recoveredSpike {
            nextSteps.append("复现峰值附近的页面或工具活动，关注峰值占用及回落所需时间；再次出现时记录对应进程明细。")
        }
        if pressure == 2 || pressure == 4 {
            nextSteps.append("结合其他应用占用、压缩内存和交换空间检查全系统压力，确认 GPT 的占用变化是否与压力同步。")
        }
        if nextSteps.isEmpty { nextSteps.append("继续按相同采样口径观察，并结合页面或工具活动核对占用变化。") }

        return AnalysisExplanation(kind: kind, headline: headline, summary: summary,
                                   evidence: evidence, findings: findings, nextSteps: nextSteps)
    }

    // topChanges is intentionally capped and ordered by absolute change. Read
    // the full boundary observations so exits cannot hide positive growth.
    private static func largestAddedProcess(first: MemorySnapshot?, last: MemorySnapshot?) -> ProcessSample? {
        guard let first, let last else { return nil }
        let baselineKeys = Set(first.processes.map(\.key))
        let baselinePIDs = Set(first.processes.map(\.pid))
        let missingBefore = Set(first.unavailablePIDs)
        let after = Dictionary(last.processes.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        return after.values.filter { sample in
            // Match the original added classification: an unavailable baseline
            // is unknown, while a known earlier instance with the same PID
            // establishes a replacement and permits classifying the new one.
            !baselineKeys.contains(sample.key)
                && !(missingBefore.contains(sample.pid) && !baselinePIDs.contains(sample.pid))
        }.max {
            $0.footprintBytes == $1.footprintBytes ? $0.key > $1.key : $0.footprintBytes < $1.footprintBytes
        }
    }

    private static func positiveExistingProcesses(first: MemorySnapshot?, last: MemorySnapshot?) -> [PositiveProcess] {
        guard let first, let last else { return [] }
        let before = Dictionary(first.processes.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        let after = Dictionary(last.processes.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        return after.values.compactMap { sample -> PositiveProcess? in
            guard let baseline = before[sample.key] else { return nil }
            let change = Int64(clamping: sample.footprintBytes) - Int64(clamping: baseline.footprintBytes)
            guard change > 0 else { return nil }
            return PositiveProcess(sample: sample, startBytes: baseline.footprintBytes, deltaBytes: change)
        }.sorted {
            $0.deltaBytes == $1.deltaBytes ? $0.sample.key < $1.sample.key : $0.deltaBytes > $1.deltaBytes
        }.prefix(3).map { $0 }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 3_600 { return String(format: "%.1f 小时", seconds / 3_600) }
        if seconds >= 60 { return String(format: "%.1f 分钟", seconds / 60) }
        return String(format: "%.0f 秒", seconds)
    }

    private static func bytes(_ bytes: UInt64) -> String { String(format: "%.1f MiB", Double(bytes) / Double(mib)) }
    private static func magnitude(_ bytes: Int64) -> String { String(format: "%.1f MiB", abs(Double(bytes)) / Double(mib)) }
    private static func delta(_ bytes: Int64) -> String { String(format: "%+.1f MiB", Double(bytes) / Double(mib)) }
    private static func startTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(formatter.string(from: date))（北京时间）"
    }
    private static func name(_ executable: String) -> String {
        let basename = URL(fileURLWithPath: executable).lastPathComponent
        return basename.isEmpty ? "该进程" : basename
    }
}
