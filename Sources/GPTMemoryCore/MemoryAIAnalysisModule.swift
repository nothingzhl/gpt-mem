import Foundation
import GPTAnalysisKit

/// Adapts the existing memory analysis to the shared AI contract. Native process
/// identities stay in this module; providers receive anonymous, bounded facts.
public struct MemoryAIAnalysisModule: AIAnalysisModule {
    private let snapshots: [MemorySnapshot]
    private let analysis: MemoryAnalysis
    private let context: String

    public init(snapshots: [MemorySnapshot], analysis: MemoryAnalysis, context: String = "") {
        self.snapshots = snapshots.sorted {
            $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt
        }
        self.analysis = analysis
        self.context = context
    }

    /// Used only by the local UI to locate the original process instance.
    public var subjectLabels: [String: String] {
        let histories = processHistories()
        let formatter = ISO8601DateFormatter()
        return Dictionary(uniqueKeysWithValues: selectedKeys(histories: histories).enumerated().compactMap { index, key in
            guard let sample = histories[key]?.last?.sample else { return nil }
            return ("p\(index + 1)", "\(sample.role.label) · PID \(sample.pid) · 启动 \(formatter.string(from: sample.startedAt))")
        })
    }

    public func makeInput() throws -> AIAnalysisInput {
        guard snapshots.count >= 2, let first = snapshots.first, let last = snapshots.last,
              last.capturedAt > first.capturedAt else {
            throw AIAnalysisError.invalidConfiguration("至少需要两份时间不同的快照，才能进行 AI 内存分析。")
        }
        guard analysis.sampleCount == snapshots.count, analysis.start == first.capturedAt,
              analysis.end == last.capturedAt,
              analysis.startTotalBytes == first.totalFootprintBytes,
              analysis.endTotalBytes == last.totalFootprintBytes else {
            throw AIAnalysisError.invalidConfiguration("内存分析结果与快照窗口不一致，请刷新后重试。")
        }

        let histories = processHistories()
        let keys = selectedKeys(histories: histories)
        let aliases = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, "p\($0.offset + 1)") })
        let intervals = zip(snapshots, snapshots.dropFirst()).map { $1.capturedAt.timeIntervalSince($0.capturedAt) }
        let positiveIntervals = intervals.filter { $0 > 0 }.sorted()
        let missing = snapshots.filter { !$0.unavailablePIDs.isEmpty }
        let trendIndices = downsampledIndices()
        let peak = snapshots.max { $0.totalFootprintBytes < $1.totalFootprintBytes }!
        let knownBootCount = Set(snapshots.flatMap { $0.processes.map(\.bootID) }.filter {
            !$0.hasPrefix("boot-unavailable") && !$0.hasPrefix("unknown-boot")
        }).count

        var facts: [AIAnalysisFact] = [
            AIAnalysisFact(id: "memory.window", title: "观察窗口与范围", data: .object([
                "durationSeconds": .number(last.capturedAt.timeIntervalSince(first.capturedAt)),
                "sampleCount": .number(Double(analysis.sampleCount)),
                "observedInstanceCount": .number(Double(histories.count)),
                "selectedInstanceCount": .number(Double(keys.count)),
                "omittedInstanceCount": .number(Double(histories.count - keys.count)),
                "metric": .string("physical_footprint_bytes"),
                "observerIncluded": .bool(false)
            ])),
            AIAnalysisFact(id: "memory.quality", title: "采样完整性与间隔", data: .object([
                "isComplete": .bool(analysis.isComplete),
                "unavailableSnapshotCount": .number(Double(missing.count)),
                "unavailableMeasurementCount": .number(Double(missing.reduce(0) { $0 + Set($1.unavailablePIDs).count })),
                "distinctUnavailableProcessCount": .number(Double(Set(missing.flatMap(\.unavailablePIDs)).count)),
                "collectorWarningCount": .number(Double(snapshots.reduce(0) { $0 + $1.warnings.count })),
                "knownSystemBootCount": .number(Double(knownBootCount)),
                "maxIntervalSeconds": .number(intervals.max() ?? 0),
                "medianIntervalSeconds": positiveIntervals.isEmpty ? .null : .number(positiveIntervals[positiveIntervals.count / 2]),
                "intervalOver120SecondsCount": .number(Double(intervals.filter { $0 > 120 }.count)),
                "duplicateTimestampCount": .number(Double(intervals.filter { $0 == 0 }.count)),
                "missingValuesAreZero": .bool(false)
            ])),
            AIAnalysisFact(id: "memory.totals", title: "已测占用与窗口峰值", data: .object([
                "startBytes": bytes(analysis.startTotalBytes),
                "endBytes": bytes(analysis.endTotalBytes),
                "netChangeBytes": .number(Double(analysis.totalChangeBytes)),
                "windowPeakBytes": bytes(peak.totalFootprintBytes),
                "windowPeakOffsetSeconds": .number(peak.capturedAt.timeIntervalSince(first.capturedAt))
            ])),
            AIAnalysisFact(id: "memory.reconciliation", title: "本地分析的四项对账", data: .object([
                "addedContributionBytes": .number(Double(analysis.addedContributionBytes)),
                "exitedContributionBytes": .number(Double(analysis.exitedContributionBytes)),
                "existingChangeBytes": .number(Double(analysis.existingChangeBytes)),
                "unresolvedContributionBytes": .number(Double(analysis.unresolvedContributionBytes)),
                "totalChangeBytes": .number(Double(analysis.totalChangeBytes)),
                "equation": .string("totalChangeBytes = addedContributionBytes + exitedContributionBytes + existingChangeBytes + unresolvedContributionBytes")
            ])),
            AIAnalysisFact(id: "memory.system", title: "全系统压力、压缩内存和交换空间", data: systemFact(first: first, last: last)),
            AIAnalysisFact(id: "memory.trend", title: "保留首尾和极值的已测趋势摘要", data: .object([
                "originalSampleCount": .number(Double(snapshots.count)),
                "pointCount": .number(Double(trendIndices.count)),
                "downsampled": .bool(trendIndices.count < snapshots.count),
                "method": .string("time_bucket_min_max_with_boundary_and_system_extrema"),
                "points": .array(trendIndices.map { trendPoint(snapshots[$0], origin: first.capturedAt) })
            ])),
            AIAnalysisFact(id: "memory.localInterpretation", title: "本地规则解读与疑似候选", data: localInterpretation(aliases: aliases))
        ]

        var subjects: [AIAnalysisSubject] = []
        for key in keys {
            guard let id = aliases[key], let history = histories[key], let sample = history.last?.sample else { continue }
            let state = instanceState(key: key, sample: sample, last: last)
            subjects.append(AIAnalysisSubject(id: id, label: "\(sample.role.label) \(id)", canInspect: state == "active"))
            facts.append(AIAnalysisFact(id: "memory.subject.\(id)", title: "\(sample.role.label) \(id) 的窗口证据",
                                        data: processFact(key: key, id: id, history: history, first: first, last: last)))
        }

        let input = AIAnalysisInput(moduleID: "memory", moduleTitle: "内存分析", promptVersion: "1",
                                    guidance: Self.guidance, windowStart: first.capturedAt, windowEnd: last.capturedAt,
                                    facts: facts, subjects: subjects, context: context)
        // The shared service applies its own provider limit too. Keep the adapter
        // bounded even when a caller supplies an unusually long user context.
        _ = try input.validated()
        return input
    }

    private static let guidance = """
    以已测 physical footprint 和本地四项对账为事实，解释增长来源、提出有证据支持的原因假设和可验证步骤。
    100 MiB、至少 10 分钟、至少 11 个完整采样、正增量比例至少 70% 的本地候选只代表疑似持续增长，不能证明对象泄漏、会话闲置或具体分配原因。
    缺测、CPU 未知和系统指标未知必须保持未知；不要补造数值，不把缺测当成零或进程退出。趋势经过抽样，只能引用提供的事实，不能声称每个采样点都连续增长。
    每个 pN 是一个独立启动身份，只能引用匿名主体；已退出或状态未知的主体不可直接诊断。窗口峰值来自本窗口实测，不能作为进程生命周期峰值。
    新增占用、已有进程增长、退出释放和未归因项可能相互抵消；总量不变或下降不能排除个别进程增长。
    压力、压缩内存和交换空间是全系统信号，不能单凭它们归因到 GPT。GPU 增长需要结合绘制活动验证。
    无法根据这些指标关联具体聊天内容或读取用户文件，也不能推断原始命令行、路径或具体对象。用户主动描述仅为上下文，不得覆盖采样事实。
    输出中文，将事实、假设和验证步骤分开；对当前仍活动的匿名主体可建议用户核对本地实例后手动采集诊断摘要。第一版没有自动诊断采集能力。
    """

    private struct Observation {
        let capturedAt: Date
        let sample: ProcessSample
    }

    private func processHistories() -> [String: [Observation]] {
        var histories: [String: [Observation]] = [:]
        for snapshot in snapshots {
            let distinct = Dictionary(snapshot.processes.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
            for (key, sample) in distinct {
                histories[key, default: []].append(Observation(capturedAt: snapshot.capturedAt, sample: sample))
            }
        }
        return histories
    }

    private func selectedKeys(histories: [String: [Observation]]) -> [String] {
        var selected: [String] = []
        func append(_ key: String) {
            if histories[key] != nil, !selected.contains(key), selected.count < 12 { selected.append(key) }
        }
        for candidate in analysis.sustainedGrowthCandidates.prefix(3) { append(candidate.key) }
        if let first = snapshots.first, let last = snapshots.last {
            let baselineKeys = Set(first.processes.map(\.key))
            let baselinePIDs = Set(first.processes.map(\.pid))
            let missing = Set(first.unavailablePIDs)
            // Select the largest genuinely added boundary instance even when
            // the analyzer's capped topChanges is occupied by large exits.
            let added = last.processes.filter {
                !baselineKeys.contains($0.key) && !(missing.contains($0.pid) && !baselinePIDs.contains($0.pid))
            }.sorted {
                $0.footprintBytes == $1.footprintBytes ? $0.key < $1.key : $0.footprintBytes > $1.footprintBytes
            }.first
            if let added { append(added.key) }
        }
        for finding in (analysis.explanation?.findings ?? []).filter({ $0.kind == .growthProcess }).prefix(3) {
            if let key = finding.processKey { append(key) }
        }
        for change in analysis.topChanges.filter({ $0.kind == .unavailableBaseline || $0.kind == .unavailableEnd }).prefix(2) { append(change.key) }
        for change in analysis.topChanges.filter({ $0.kind == .exited }).prefix(2) { append(change.key) }
        if let largest = snapshots.last?.processes.max(by: { $0.footprintBytes < $1.footprintBytes }) { append(largest.key) }
        for change in analysis.topChanges { append(change.key) }
        // If a window has only intermediate observations, retain the largest
        // observed instance even when it is absent at both boundaries.
        let peaks = histories.mapValues { $0.map { $0.sample.footprintBytes }.max() ?? 0 }
        let peakOrder = histories.keys.sorted {
            let lhs = peaks[$0] ?? 0
            let rhs = peaks[$1] ?? 0
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        for key in peakOrder { append(key) }
        return selected.sorted {
            let lhs = histories[$0]?.first?.capturedAt ?? .distantPast
            let rhs = histories[$1]?.first?.capturedAt ?? .distantPast
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
    }

    private func instanceState(key: String, sample: ProcessSample, last: MemorySnapshot) -> String {
        if last.processes.contains(where: { $0.key == key }) { return "active" }
        if last.unavailablePIDs.contains(sample.pid), !last.processes.contains(where: { $0.pid == sample.pid }) {
            // A later observed replacement proves that the old identity exited,
            // even if the replacement itself becomes unavailable at the end.
            let lastObserved = snapshots.lastIndex { $0.processes.contains { $0.key == key } } ?? 0
            let replacementObserved = snapshots.dropFirst(lastObserved + 1).contains {
                $0.processes.contains { $0.pid == sample.pid && $0.key != key }
            }
            return replacementObserved ? "exited" : "unknown"
        }
        return "exited"
    }

    private func processFact(key: String, id: String, history: [Observation], first: MemorySnapshot, last: MemorySnapshot) -> AIJSONValue {
        let initial = history.first!, final = history.last!
        let baseline = first.processes.last { $0.key == key }
        let current = last.processes.last { $0.key == key }
        let change = analysis.topChanges.first { $0.key == key }
        let peak = history.max { $0.sample.footprintBytes < $1.sample.footprintBytes }!
        let cpu = history.compactMap { $0.sample.cpuPercent }.filter(\.isFinite)
        let candidate = analysis.sustainedGrowthCandidates.first { $0.key == key }
        let candidateFact: AIJSONValue = candidate.map { candidate in
            .object([
                "startOffsetSeconds": .number(candidate.start.timeIntervalSince(first.capturedAt)),
                "endOffsetSeconds": .number(candidate.end.timeIntervalSince(first.capturedAt)),
                "netGrowthBytes": .number(Double(candidate.netGrowthBytes)),
                "sampleCount": .number(Double(candidate.sampleCount)),
                "positiveIncrementFraction": .number(candidate.positiveIncrementFraction),
                "confirmedLeak": .bool(false)
            ])
        } ?? .null
        var value: [String: AIJSONValue] = [
            "subjectID": .string(id),
            "role": .string(final.sample.role.rawValue),
            "stateAtWindowEnd": .string(instanceState(key: key, sample: final.sample, last: last)),
            "sameInstanceAtBothBoundaries": .bool(baseline != nil && current != nil),
            "firstObservedBytes": bytes(initial.sample.footprintBytes),
            "lastObservedBytes": bytes(final.sample.footprintBytes),
            "firstObservedOffsetSeconds": .number(initial.capturedAt.timeIntervalSince(first.capturedAt)),
            "lastObservedOffsetSeconds": .number(final.capturedAt.timeIntervalSince(first.capturedAt)),
            "windowPeakBytes": bytes(peak.sample.footprintBytes),
            "windowPeakOffsetSeconds": .number(peak.capturedAt.timeIntervalSince(first.capturedAt)),
            "observationCount": .number(Double(history.count)),
            "sustainedGrowthCandidate": candidateFact
        ]
        value["boundaryChangeKind"] = change.map { AIJSONValue.string($0.kind.rawValue) } ?? .null
        value["startBytes"] = baseline.map { bytes($0.footprintBytes) } ?? .null
        value["endBytes"] = current.map { bytes($0.footprintBytes) } ?? .null
        if let delta = change?.deltaBytes { value["boundaryDeltaBytes"] = .number(Double(delta)) }
        else { value["boundaryDeltaBytes"] = .null }
        value["cpuPercent"] = .object([
            "meanObserved": cpu.isEmpty ? .null : .number(cpu.reduce(0, +) / Double(cpu.count)),
            "maxObserved": cpu.max().map(AIJSONValue.number) ?? .null,
            "observedSampleCount": .number(Double(cpu.count)),
            "unknownSampleCount": .number(Double(history.count - cpu.count))
        ])
        return .object(value)
    }

    private func systemFact(first: MemorySnapshot, last: MemorySnapshot) -> AIJSONValue {
        let compressed = snapshots.compactMap { $0.system.compressedPhysicalBytes }
        let swap = snapshots.compactMap { $0.system.swapUsedBytes }
        return .object([
            "scope": .string("whole_system"),
            "physicalBytesAtEnd": bytes(last.system.physicalBytes),
            "pressureAtStart": integer(first.system.pressureLevel),
            "pressureAtEnd": integer(last.system.pressureLevel),
            "observedPressureLevels": .array(Set(snapshots.compactMap { $0.system.pressureLevel }).sorted().map { .number(Double($0)) }),
            "pressureUnknownSampleCount": .number(Double(snapshots.filter { $0.system.pressureLevel == nil }.count)),
            "compressedBytesAtStart": optionalBytes(first.system.compressedPhysicalBytes),
            "compressedBytesAtEnd": optionalBytes(last.system.compressedPhysicalBytes),
            "compressedBytesChange": byteDifference(first.system.compressedPhysicalBytes, last.system.compressedPhysicalBytes),
            "compressedWindowPeakBytes": optionalBytes(compressed.max()),
            "compressedUnknownSampleCount": .number(Double(snapshots.count - compressed.count)),
            "swapBytesAtStart": optionalBytes(first.system.swapUsedBytes),
            "swapBytesAtEnd": optionalBytes(last.system.swapUsedBytes),
            "swapBytesChange": byteDifference(first.system.swapUsedBytes, last.system.swapUsedBytes),
            "swapWindowPeakBytes": optionalBytes(swap.max()),
            "swapUnknownSampleCount": .number(Double(snapshots.count - swap.count))
        ])
    }

    private func localInterpretation(aliases: [String: String]) -> AIJSONValue {
        let kind = analysis.explanation?.kind
        let summary: String
        switch kind {
        case .growth: summary = "本地规则判定已测起止占用增长；增长来源以四项对账为准，尚不能确诊泄漏。"
        case .reduction: summary = "本地规则判定已测起止占用下降；个别实例增长或窗口尖峰仍需单独观察。"
        case .littleChange: summary = "本地规则判定已测净变化低于 10 MiB；不同来源可能抵消，不能据此确认没有异常。"
        case .partialData: summary = "本地规则判定采样不完整；已测净变化不能代表完整变化。"
        case .insufficientData: summary = "本地规则认为采样不足。"
        case nil: summary = "没有本地文字解读，仅提供数值事实。"
        }
        let localFindings = analysis.explanation?.findings ?? []
        let findings: [AIJSONValue] = localFindings.prefix(24).map { finding in
            var value: [String: AIJSONValue] = ["kind": .string(finding.kind.rawValue)]
            value["subjectID"] = finding.processKey.flatMap { aliases[$0] }.map(AIJSONValue.string) ?? .null
            return .object(value)
        }
        let encodedKind: AIJSONValue = kind.map { AIJSONValue.string($0.rawValue) } ?? .null
        let value: [String: AIJSONValue] = [
            "kind": encodedKind,
            "summary": .string(summary),
            "findings": .array(findings),
            "omittedFindingCount": .number(Double(max(0, localFindings.count - findings.count))),
            "sustainedGrowthCandidateCount": .number(Double(analysis.sustainedGrowthCandidates.count)),
            "candidateThresholdBytes": .number(100 * 1_024 * 1_024),
            "candidateMinimumSpanSeconds": .number(600),
            "candidateMinimumSampleCount": .number(11),
            "candidateMinimumPositiveIncrementFraction": .number(0.7)
        ]
        return .object(value)
    }

    private func downsampledIndices() -> [Int] {
        guard snapshots.count > 120, let first = snapshots.first, let last = snapshots.last else { return Array(snapshots.indices) }
        let span = last.capturedAt.timeIntervalSince(first.capturedAt)
        guard span > 0 else { return Array(snapshots.indices.prefix(120)) }
        var selected: Set<Int> = [0, snapshots.count - 1]
        if let peak = snapshots.indices.max(by: { snapshots[$0].totalFootprintBytes < snapshots[$1].totalFootprintBytes }) { selected.insert(peak) }
        if let trough = snapshots.indices.min(by: { snapshots[$0].totalFootprintBytes < snapshots[$1].totalFootprintBytes }) { selected.insert(trough) }
        for metric in [0, 1, 2] {
            let known = snapshots.indices.filter { systemMetric(snapshots[$0], metric) != nil }
            if let index = known.max(by: { systemMetric(snapshots[$0], metric)! < systemMetric(snapshots[$1], metric)! }) { selected.insert(index) }
        }
        var buckets: [Int: [Int]] = [:]
        for index in snapshots.indices.dropFirst().dropLast() {
            let fraction = snapshots[index].capturedAt.timeIntervalSince(first.capturedAt) / span
            let bucket = min(55, max(0, Int(fraction * 56)))
            buckets[bucket, default: []].append(index)
        }
        for indices in buckets.values {
            if let low = indices.min(by: { snapshots[$0].totalFootprintBytes < snapshots[$1].totalFootprintBytes }) { selected.insert(low) }
            if let high = indices.max(by: { snapshots[$0].totalFootprintBytes < snapshots[$1].totalFootprintBytes }) { selected.insert(high) }
        }
        return selected.sorted()
    }

    private func systemMetric(_ snapshot: MemorySnapshot, _ metric: Int) -> UInt64? {
        switch metric {
        case 0: return snapshot.system.compressedPhysicalBytes
        case 1: return snapshot.system.swapUsedBytes
        default: return snapshot.system.pressureLevel.flatMap { $0 >= 0 ? UInt64($0) : nil }
        }
    }

    private func trendPoint(_ snapshot: MemorySnapshot, origin: Date) -> AIJSONValue {
        .object([
            "offsetSeconds": .number(snapshot.capturedAt.timeIntervalSince(origin)),
            "totalMeasuredBytes": bytes(snapshot.totalFootprintBytes),
            "observedProcessCount": .number(Double(snapshot.processes.count)),
            "unavailableProcessCount": .number(Double(Set(snapshot.unavailablePIDs).count)),
            "pressureLevel": integer(snapshot.system.pressureLevel),
            "compressedPhysicalBytes": optionalBytes(snapshot.system.compressedPhysicalBytes),
            "swapUsedBytes": optionalBytes(snapshot.system.swapUsedBytes)
        ])
    }

    private func bytes(_ value: UInt64) -> AIJSONValue { .number(Double(value)) }
    private func optionalBytes(_ value: UInt64?) -> AIJSONValue { value.map(bytes) ?? .null }
    private func integer(_ value: Int?) -> AIJSONValue { value.map { .number(Double($0)) } ?? .null }
    private func byteDifference(_ first: UInt64?, _ last: UInt64?) -> AIJSONValue {
        guard let first, let last else { return .null }
        return .number(Double(Int64(clamping: last) - Int64(clamping: first)))
    }
}
