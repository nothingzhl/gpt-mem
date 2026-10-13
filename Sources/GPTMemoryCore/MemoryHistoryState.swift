import Foundation

/// The last fully loaded history and its analysis, retained if a subsequent read fails.
public struct MemoryHistoryState {
    public private(set) var snapshots: [MemorySnapshot] = []
    public private(set) var analysis: MemoryAnalysis?
    public private(set) var loadError: String?

    public init() {}

    public mutating func refresh(using load: () throws -> [MemorySnapshot]) {
        do {
            let history = try load()
            if history == snapshots { loadError = nil; return }
            let analysis = history.count >= 2 ? MemoryAnalyzer.analyze(history) : nil
            snapshots = history
            self.analysis = analysis
            loadError = nil
        } catch {
            let context = snapshots.isEmpty
                ? "历史读取失败："
                : "历史读取失败，仍显示上次成功读取的数据；实际时间范围可能与当前选择不同："
            loadError = context + String(describing: error)
        }
    }
}
