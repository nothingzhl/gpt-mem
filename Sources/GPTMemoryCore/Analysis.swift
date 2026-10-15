import Foundation

public enum ProcessChangeKind: String, Codable {
    case added, exited, existing, unavailableBaseline, unavailableEnd
}

public struct ProcessMemoryChange: Codable {
    public let key: String
    public let pid: Int
    public let role: ProcessRole
    public let executable: String
    public let kind: ProcessChangeKind
    public let startBytes: UInt64?
    public let endBytes: UInt64?
    public let deltaBytes: Int64?
}

public enum MemoryEventKind: String, Codable {
    case processAdded, processExited, measurementUnavailable, bootChanged
}

public struct MemoryEvent: Codable {
    public let capturedAt: Date
    public let kind: MemoryEventKind
    public let key: String?
    public let pid: Int?
    public let role: ProcessRole?
    public let message: String
}

public struct GrowthCandidate: Codable {
    public let key: String
    public let pid: Int
    public let role: ProcessRole
    public let executable: String
    public let start: Date
    public let end: Date
    public let netGrowthBytes: Int64
    public let sampleCount: Int
    public let positiveIncrementFraction: Double
}

/// Signed reconciliation: totalChange = added + exited + existing + unresolved.
/// Unknown measurements remain unknown instead of being counted as zero or an exit.
public struct MemoryAnalysis: Codable {
    public let start: Date?
    public let end: Date?
    public let sampleCount: Int
    public let startTotalBytes: UInt64
    public let endTotalBytes: UInt64
    public let totalChangeBytes: Int64
    public let addedContributionBytes: Int64
    public let exitedContributionBytes: Int64
    public let existingChangeBytes: Int64
    public let unresolvedContributionBytes: Int64
    public let isComplete: Bool
    public let topChanges: [ProcessMemoryChange]
    public let events: [MemoryEvent]
    public let sustainedGrowthCandidates: [GrowthCandidate]
    public let warnings: [String]
    public var explanation: AnalysisExplanation? = nil
}

public enum MemoryAnalyzer {
    public static func analyze(_ snapshots: [MemorySnapshot]) -> MemoryAnalysis {
        let ordered = snapshots.sorted {
            $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt
        }
        guard let first = ordered.first, let last = ordered.last else {
            var analysis = MemoryAnalysis(start: nil, end: nil, sampleCount: 0, startTotalBytes: 0,
                                          endTotalBytes: 0, totalChangeBytes: 0, addedContributionBytes: 0,
                                          exitedContributionBytes: 0, existingChangeBytes: 0,
                                          unresolvedContributionBytes: 0, isComplete: false,
                                          topChanges: [], events: [], sustainedGrowthCandidates: [],
                                          warnings: ["没有可分析的快照。"])
            analysis.explanation = AnalysisInterpreter.interpret(snapshots: ordered, analysis: analysis)
            return analysis
        }
        let before = samplesByKey(first.processes)
        let after = samplesByKey(last.processes)
        let missingBefore = Set(first.unavailablePIDs)
        let missingAfter = Set(last.unavailablePIDs)
        var changes: [ProcessMemoryChange] = []
        var added: Int64 = 0, exited: Int64 = 0, existing: Int64 = 0
        for key in Set(before.keys).union(after.keys).sorted() {
            let a = before[key], b = after[key]
            guard let sample = b ?? a else { continue }
            let kind: ProcessChangeKind
            let delta: Int64?
            if let a, let b {
                kind = .existing; delta = signed(b.footprintBytes) - signed(a.footprintBytes)
                existing += delta!
            } else if let b {
                // A different observed instance with the same PID proves a replacement,
                // whereas an unavailable PID does not identify a new process.
                if missingBefore.contains(b.pid) && !first.processes.contains(where: { $0.pid == b.pid }) {
                    kind = .unavailableBaseline; delta = nil
                } else {
                    kind = .added; delta = signed(b.footprintBytes); added += delta!
                }
            } else if let a {
                if missingAfter.contains(a.pid) && !last.processes.contains(where: { $0.pid == a.pid }) {
                    kind = .unavailableEnd; delta = nil
                } else {
                    kind = .exited; delta = -signed(a.footprintBytes); exited += delta!
                }
            } else { continue }
            changes.append(ProcessMemoryChange(key: key, pid: sample.pid, role: sample.role,
                                               executable: sample.executable, kind: kind,
                                               startBytes: a?.footprintBytes, endBytes: b?.footprintBytes,
                                               deltaBytes: delta))
        }
        let total = signed(last.totalFootprintBytes) - signed(first.totalFootprintBytes)
        let unresolved = total - added - exited - existing
        let scan = scanHistory(ordered)
        var warnings = Array(scan.warnings)
        let hasMissing = scan.hasMissing
        if hasMissing {
            warnings.append("区间内存在未取得指标的进程；缺失值不代表内存为零或进程退出，总量与增长归因可能不完整。")
        }
        if ordered.count == 1 { warnings.append("只有一个快照，无法判断增长趋势。") }
        if scan.bootIDs.count > 1 {
            warnings.append("观察区间跨越系统启动实例；进程按启动身份分开，不能作为同一进程的持续增长。")
        }
        let events = scan.events
        let candidates = growthCandidates(scan.histories, snapshots: ordered)
        if !candidates.isEmpty {
            warnings.append("持续增长候选仅为疑似现象，不能证明泄漏或会话已闲置；工具不会结束任何进程。")
        }
        if candidates.contains(where: { $0.role == .gpu }) {
            warnings.append("GPU 候选表示图形资源持续增长；需要结合绘制活动判断，不能等同于堆内存泄漏。")
        }
        let sortedChanges = changes.sorted {
            let lhs = abs($0.deltaBytes ?? 0), rhs = abs($1.deltaBytes ?? 0)
            return lhs == rhs ? $0.key < $1.key : lhs > rhs
        }
        var analysis = MemoryAnalysis(start: first.capturedAt, end: last.capturedAt, sampleCount: ordered.count,
                                      startTotalBytes: first.totalFootprintBytes, endTotalBytes: last.totalFootprintBytes,
                                      totalChangeBytes: total, addedContributionBytes: added,
                                      exitedContributionBytes: exited, existingChangeBytes: existing,
                                      unresolvedContributionBytes: unresolved,
                                      isComplete: !hasMissing && ordered.count >= 2 && last.capturedAt > first.capturedAt,
                                      topChanges: Array(sortedChanges.prefix(30)), events: events,
                                      sustainedGrowthCandidates: candidates, warnings: Array(Set(warnings)).sorted())
        analysis.explanation = AnalysisInterpreter.interpret(snapshots: ordered, analysis: analysis)
        return analysis
    }

    private static func samplesByKey(_ samples: [ProcessSample]) -> [String: ProcessSample] {
        var result: [String: ProcessSample] = [:]
        result.reserveCapacity(samples.count)
        for sample in samples { result[sample.key] = sample }
        return result
    }

    private static func signed(_ value: UInt64) -> Int64 { Int64(clamping: value) }

    private struct FootprintObservation {
        let snapshotIndex: Int
        let bytes: UInt64
        let unavailable: Bool
    }

    private struct ProcessHistory {
        var last: ProcessSample
        var observations: [FootprintObservation] = []
    }

    private struct HistoryScan {
        var events: [MemoryEvent] = []
        var histories: [String: ProcessHistory] = [:]
        var bootIDs: Set<String> = []
        var warnings: Set<String> = []
        var hasMissing = false
    }

    // Events and growth used to rebuild every snapshot's process dictionary in
    // separate passes and retain full ProcessSample copies for every observation.
    // Walk once, retaining only an index, footprint and gap flag for each point.
    private static func scanHistory(_ snapshots: [MemorySnapshot]) -> HistoryScan {
        var result = HistoryScan()
        var preceding: [String: ProcessSample] = [:]
        var previousBoot: Set<String> = []
        for (index, current) in snapshots.enumerated() {
            result.warnings.formUnion(current.warnings)
            let unavailable = Set(current.unavailablePIDs)
            result.hasMissing = result.hasMissing || !unavailable.isEmpty
            for pid in unavailable.sorted() {
                result.events.append(MemoryEvent(capturedAt: current.capturedAt, kind: .measurementUnavailable,
                                          key: nil, pid: pid, role: nil, message: "PID \(pid) 未取得指标，状态未知。"))
            }
            let b = samplesByKey(current.processes)
            var currentBoot: Set<String> = []
            for process in current.processes {
                if !process.bootID.hasPrefix("boot-unavailable") && !process.bootID.hasPrefix("unknown-boot") {
                    currentBoot.insert(process.bootID)
                }
            }
            for (key, process) in b {
                if snapshots.count >= 11 {
                    if result.histories[key] == nil { result.histories[key] = ProcessHistory(last: process) }
                    result.histories[key]!.last = process
                    result.histories[key]!.observations.append(.init(snapshotIndex: index, bytes: process.footprintBytes,
                                                                    unavailable: unavailable.contains(process.pid)))
                }
            }
            result.bootIDs.formUnion(currentBoot)
            let a = preceding
            preceding = b
            defer { previousBoot = currentBoot }
            guard index > 0 else { continue }
            let previous = snapshots[index - 1]
            if !previousBoot.isEmpty && !currentBoot.isEmpty && previousBoot.isDisjoint(with: currentBoot)
                && !a.keys.contains(where: { b[$0] != nil }) {
                result.events.append(MemoryEvent(capturedAt: current.capturedAt, kind: .bootChanged,
                                          key: nil, pid: nil, role: nil, message: "检测到系统启动身份变化。"))
            }
            for key in b.keys.filter({ a[$0] == nil }).sorted() {
                guard let p = b[key] else { continue }
                if previous.unavailablePIDs.contains(p.pid) && !previous.processes.contains(where: { $0.pid == p.pid }) { continue }
                result.events.append(MemoryEvent(capturedAt: current.capturedAt, kind: .processAdded,
                                          key: key, pid: p.pid, role: p.role, message: "新增 \(p.role.label) 进程 PID \(p.pid)。"))
            }
            for key in a.keys.filter({ b[$0] == nil }).sorted() {
                guard let p = a[key] else { continue }
                if current.unavailablePIDs.contains(p.pid) && !current.processes.contains(where: { $0.pid == p.pid }) { continue }
                result.events.append(MemoryEvent(capturedAt: current.capturedAt, kind: .processExited,
                                          key: key, pid: p.pid, role: p.role, message: "已退出 \(p.role.label) 进程 PID \(p.pid)。"))
            }
        }
        return result
    }

    private static func growthCandidates(_ histories: [String: ProcessHistory], snapshots: [MemorySnapshot]) -> [GrowthCandidate] {
        guard snapshots.count >= 11 else { return [] }
        var candidates: [GrowthCandidate] = []
        for (key, trace) in histories {
            let history = trace.observations
            guard let last = history.last else { continue }
            let lastDate = snapshots[last.snapshotIndex].capturedAt
            // An earlier flat hour must not hide growth during the latest 10–15 minutes.
            // Try the recent 10-minute window first, then a 15-minute window for
            // slower but still sustained growth. Never bridge missing observations.
            var match: GrowthCandidate?
            for duration in [600.0, 900.0] {
                let cutoff = lastDate.addingTimeInterval(-duration)
                let baseline = history.lastIndex(where: { snapshots[$0.snapshotIndex].capturedAt <= cutoff }) ?? 0
                let window = history[baseline...]
                guard let first = window.first, window.count >= 11,
                      lastDate.timeIntervalSince(snapshots[first.snapshotIndex].capturedAt) >= 600 else { continue }
                let firstDate = snapshots[first.snapshotIndex].capturedAt
                let growth = signed(last.bytes) - signed(first.bytes)
                guard growth >= 100 * 1_024 * 1_024 else { continue }
                // A sparse or interrupted trace cannot establish sustained growth.
                // Contiguous snapshot indices prove no missing observations.
                // Equal timestamp neighbors outside the slice must also count,
                // matching the original whole-history time-range selection.
                guard window.count == last.snapshotIndex - first.snapshotIndex + 1,
                      (first.snapshotIndex == 0 || snapshots[first.snapshotIndex - 1].capturedAt < firstDate),
                      (last.snapshotIndex == snapshots.count - 1 || snapshots[last.snapshotIndex + 1].capturedAt > lastDate),
                      !window.contains(where: \.unavailable),
                      zip(window, window.dropFirst()).allSatisfy({
                          let span = snapshots[$1.snapshotIndex].capturedAt.timeIntervalSince(snapshots[$0.snapshotIndex].capturedAt)
                          return span > 0 && span <= 120
                      }) else { continue }
                let positive = zip(window, window.dropFirst()).reduce(0) { $0 + ($1.1.bytes > $1.0.bytes ? 1 : 0) }
                let fraction = Double(positive) / Double(window.count - 1)
                guard fraction >= 0.7 else { continue }
                match = GrowthCandidate(key: key, pid: trace.last.pid, role: trace.last.role,
                                        executable: trace.last.executable, start: firstDate, end: lastDate,
                                        netGrowthBytes: growth, sampleCount: window.count,
                                        positiveIncrementFraction: fraction)
                break
            }
            if let match { candidates.append(match) }
        }
        return candidates.sorted { $0.netGrowthBytes == $1.netGrowthBytes ? $0.key < $1.key : $0.netGrowthBytes > $1.netGrowthBytes }
    }
}
