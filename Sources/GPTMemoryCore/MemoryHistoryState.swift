import Foundation

/// The last fully loaded history and its analysis, retained if a subsequent read fails.
public struct MemoryHistoryState {
    public private(set) var snapshots: [MemorySnapshot] = []
    public private(set) var analysis: MemoryAnalysis?
    public private(set) var loadError: String?
    public private(set) var revision: UInt64 = 0
    private var metadata = MemoryProcessMetadataPool()

    public init() {}

    @discardableResult
    public mutating func refresh(using load: () throws -> [MemorySnapshot]) -> Bool {
        do {
            let history = try load()
            if history == snapshots { loadError = nil; return true }
            let analysis = history.count >= 2 ? MemoryAnalyzer.analyze(history) : nil
            snapshots = history
            self.analysis = analysis
            metadata = MemoryProcessMetadataPool()
            if let latest = history.last { metadata.observe(latest) }
            loadError = nil
            revision &+= 1
            return true
        } catch {
            recordFailure(error)
            return false
        }
    }

    /// Advance a successfully loaded window using the value already committed by
    /// the sampling owner. Keep the same most-recent pre-cutoff baseline as SQLite.
    /// Callers reload for window expansion, external commits, and retention changes.
    /// A moved baseline also returns false: its earlier predecessor may no longer
    /// be in memory, so callers must immediately reload the authoritative store.
    @discardableResult
    public mutating func advance(saved snapshot: MemorySnapshot?, since: Date, maxSamples: Int = 10_000) -> Bool {
        do {
            guard maxSamples > 0 else { throw MemoryError.message("历史快照读取上限必须大于零。") }
            var updated = snapshots
            if let snapshot {
                let snapshot = metadata.canonicalized(snapshot)
                if let existing = updated.firstIndex(where: { $0.id == snapshot.id }) {
                    if existing == 0, updated[existing].capturedAt < since,
                       updated[existing].capturedAt != snapshot.capturedAt {
                        throw MemoryError.message("滚动基线时间发生变化，需要重新读取历史。")
                    }
                    if updated[existing] != snapshot { updated.remove(at: existing); insert(snapshot, into: &updated) }
                } else { insert(snapshot, into: &updated) }
            }
            var firstInWindow = 0
            while firstInWindow < updated.count && updated[firstInWindow].capturedAt < since { firstInWindow += 1 }
            let removeCount = max(0, firstInWindow - 1)
            if updated.count - removeCount > maxSamples {
                throw MemoryError.message("历史快照超过 \(maxSamples) 条读取上限，请缩短观察窗口（since/window）后重试；本次没有截断或降采样结果。")
            }
            if removeCount > 0 { updated.removeFirst(removeCount) }
            // The normal owner path adds exactly one immutable value; comparing
            // every process in the unchanged historical samples is unnecessary.
            let changed = snapshot != nil || removeCount > 0
            if changed {
                snapshots = updated
                analysis = updated.count >= 2 ? MemoryAnalyzer.analyze(updated) : nil
                revision &+= 1
            }
            loadError = nil
            return true
        } catch {
            recordFailure(error)
            return false
        }
    }

    private func insert(_ snapshot: MemorySnapshot, into history: inout [MemorySnapshot]) {
        if let last = history.last,
           last.capturedAt > snapshot.capturedAt || (last.capturedAt == snapshot.capturedAt && last.id > snapshot.id) {
            let index = history.firstIndex {
                $0.capturedAt > snapshot.capturedAt || ($0.capturedAt == snapshot.capturedAt && $0.id > snapshot.id)
            } ?? history.endIndex
            history.insert(snapshot, at: index)
        } else { history.append(snapshot) }
    }

    private mutating func recordFailure(_ error: Error) {
        let context = snapshots.isEmpty
            ? "历史读取失败："
            : "历史读取失败，仍显示上次成功读取的数据；实际时间范围可能与当前选择不同："
        loadError = context + String(describing: error)
    }
}
