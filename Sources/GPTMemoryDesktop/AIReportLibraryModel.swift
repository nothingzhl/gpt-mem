import Foundation
import Combine
import GPTAnalysisKit

enum AIReportExportFormat: String, CaseIterable, Identifiable {
    case markdown, json
    var id: String { rawValue }
    var fileExtension: String { self == .markdown ? "md" : "json" }
    var title: String { self == .markdown ? "Markdown" : "JSON" }
}

struct AIReportModuleChoice: Identifiable {
    let id: String
    let title: String
}

private struct IndexedAIReport {
    let report: AISavedReport
    let searchText: String

    init(_ report: AISavedReport) {
        self.report = report
        let result = report.record.result
        var text: [String] = [report.record.moduleTitle, report.record.moduleID,
                              report.record.providerName, report.record.model,
                              result.summary, report.input.context]
        text.append(contentsOf: report.subjectLabels.values)
        text.append(contentsOf: result.observations.map(\.text))
        for hypothesis in result.hypotheses {
            text.append(hypothesis.title); text.append(hypothesis.explanation)
            text.append(contentsOf: hypothesis.missingEvidence)
        }
        for step in result.nextSteps { text.append(step.action); text.append(step.purpose) }
        text.append(contentsOf: result.limitations)
        searchText = text.joined(separator: "\n").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private struct ReportLibrarySnapshot {
    let revision: UInt64
    let catalog: AIReportCatalog
    let indexed: [IndexedAIReport]
}

private struct ReportLibraryMutation {
    let report: AISavedReport?
    let location: AIReportLocation?
    let indexedReport: IndexedAIReport?
    let revision: UInt64
    let snapshot: ReportLibrarySnapshot?
    let reloadError: String?
}

/// Store operations run serially away from the main actor. The snapshot revision
/// follows the actual file operation order, so a delayed refresh cannot undo a save.
private actor AIReportLibraryIO {
    let store: AIReportStore
    private var revision: UInt64 = 0

    init(store: AIReportStore) { self.store = store }

    func load() throws -> ReportLibrarySnapshot {
        revision &+= 1
        let catalog = try store.loadCatalog()
        return ReportLibrarySnapshot(revision: revision, catalog: catalog,
                                     indexed: catalog.reports.map(IndexedAIReport.init))
    }

    func save(_ report: AISavedReport) throws -> ReportLibraryMutation {
        let saved = try store.save(report)
        let location = try store.location(of: saved.id)
        guard location != .missing else { throw AIReportStoreError.missingReport }
        return snapshotAfterMutation(report: saved, location: location)
    }

    func remove(_ id: UUID) throws -> ReportLibraryMutation {
        try store.remove(id)
        return snapshotAfterMutation(report: nil)
    }

    func restore(_ id: UUID) throws -> ReportLibraryMutation {
        let restored = try store.restore(id)
        return snapshotAfterMutation(report: restored)
    }

    private func snapshotAfterMutation(report: AISavedReport?, location: AIReportLocation? = nil) -> ReportLibraryMutation {
        do {
            let snapshot = try load()
            return ReportLibraryMutation(report: report, location: location, indexedReport: nil, revision: snapshot.revision,
                                         snapshot: snapshot, reloadError: nil)
        } catch {
            // The mutation already committed. Do not treat a later read failure as
            // a failed save/delete or lose the information needed to undo it.
            return ReportLibraryMutation(report: report, location: location, indexedReport: report.map(IndexedAIReport.init),
                                         revision: revision, snapshot: nil, reloadError: error.localizedDescription)
        }
    }

    func export(_ report: AISavedReport, to destination: URL, format: AIReportExportFormat) throws {
        guard destination.isFileURL else { throw ReportLibraryError.invalidExportDestination }
        // Foundation may leave a nonexistent final component unresolved. Resolve
        // its existing parent separately, including a directory symlink alias.
        let protected = store.directoryURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent(store.directoryURL.lastPathComponent, isDirectory: true).path
        let targets = [destination.standardizedFileURL.resolvingSymlinksInPath().path,
                       destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                        .appendingPathComponent(destination.lastPathComponent).path]
        guard targets.allSatisfy({ $0 != protected && !$0.hasPrefix(protected + "/") }) else {
            throw ReportLibraryError.protectedExportDestination
        }
        let applicationDirectory = store.directoryURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let applicationFileNames = ["ai-services.json", "history.sqlite3", "history.sqlite3-wal",
                                    "history.sqlite3-shm", "history.sqlite3-journal", "monitor.lock"]
        let applicationPaths = Set(applicationFileNames.flatMap { name -> [String] in
            let file = applicationDirectory.appendingPathComponent(name)
            return [file.path, file.resolvingSymlinksInPath().path]
        })
        guard targets.allSatisfy({ !applicationPaths.contains($0) }) else {
            throw ReportLibraryError.protectedApplicationData
        }
        let data: Data
        switch format {
        case .markdown: data = Data(try AIReportExport.markdown(report).utf8)
        case .json: data = try AIReportExport.json(report)
        }
        // Atomic replacement leaves an existing hard link's source inode intact.
        try data.write(to: destination, options: .atomic)
    }
}

private enum ReportLibraryError: LocalizedError {
    case invalidExportDestination, protectedExportDestination, protectedApplicationData
    var errorDescription: String? {
        switch self {
        case .invalidExportDestination: return "请选择本地文件保存报告。"
        case .protectedExportDestination: return "导出位置属于报告库，请选择其他目录；本次没有覆盖报告文件。"
        case .protectedApplicationData: return "导出位置属于应用配置或历史数据，请选择其他文件名；本次没有覆盖应用数据。"
        }
    }
}

/// Historical reports are independent of the currently displayed live analysis.
/// Opening, filtering, exporting, and restoring never resolve credentials or call AI.
@MainActor
final class AIReportLibraryModel: ObservableObject {
    let store: AIReportStore
    @Published private(set) var reports: [AISavedReport] = []
    @Published private(set) var filteredReports: [AISavedReport] = []
    @Published private(set) var selectedReportID: UUID?
    @Published private(set) var moduleChoices: [AIReportModuleChoice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isRemoving = false
    @Published private(set) var isExporting = false
    @Published private(set) var isFiltering = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var saveErrorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var pendingSaveCount = 0
    @Published private(set) var canUndoRemoval = false
    @Published var query = "" { didSet { if query != oldValue { filter(debounce: true) } } }
    @Published var selectedModuleID: String? { didSet { if selectedModuleID != oldValue { filter() } } }

    private let io: AIReportLibraryIO
    private var indexedReports: [IndexedAIReport] = []
    private var appliedRevision: UInt64 = 0
    private var loadGeneration = UUID()
    private var filterGeneration = UUID()
    private var loadTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var filterOperation: Task<[AISavedReport]?, Never>?
    private var saveTask: Task<Void, Never>?
    private var removalTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var pendingSaves: [AISavedReport] = []
    private var lastRemovedID: UUID?

    init(store: AIReportStore) {
        self.store = store
        io = AIReportLibraryIO(store: store)
    }

    var selectedReport: AISavedReport? {
        guard !isFiltering, let selectedReportID else { return nil }
        return reports.first { $0.id == selectedReportID }
    }
    var moduleIDs: [String] { moduleChoices.map(\.id) }
    var canRetrySave: Bool { pendingSaveCount > 0 && !isSaving }

    func loadIfNeeded() { if !hasLoaded && !isLoading { refresh() } }

    func refresh() {
        loadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        loadTask = Task { [weak self, io] in
            do {
                let snapshot = try await io.load()
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                self.apply(snapshot)
                self.errorMessage = self.saveErrorMessage
                self.isLoading = false
                self.loadTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                self.errorMessage = "报告库读取失败：\(error.localizedDescription)。已显示的报告仍然保留，请修复后重试。"
                self.isLoading = false
                self.loadTask = nil
            }
        }
    }

    func select(_ id: UUID?) {
        guard !isFiltering, id == nil || filteredReports.contains(where: { $0.id == id }) else { return }
        selectedReportID = id
    }

    func select(id: UUID?) { select(id) }

    func save(record: AIAnalysisRecord, input: AIAnalysisInput, subjectLabels: [String: String],
              windowSelectionSeconds: TimeInterval) {
        pendingSaves.append(AISavedReport(record: record, input: input, subjectLabels: subjectLabels,
                                         windowSelectionSeconds: windowSelectionSeconds))
        pendingSaveCount = pendingSaves.count
        // A failed report stays queued until the user retries; a later success must
        // not silently discard it or resend the original AI request.
        guard saveErrorMessage == nil else { return }
        startSaving()
    }

    func retrySave() {
        guard canRetrySave else { return }
        saveErrorMessage = nil
        errorMessage = nil
        startSaving()
    }

    private func startSaving() {
        guard !isSaving, !pendingSaves.isEmpty else { return }
        isSaving = true
        saveTask = Task { [weak self, io] in
            while let self, let report = self.pendingSaves.first {
                do {
                    let mutation = try await io.save(report)
                    let saved = mutation.report ?? report
                    self.pendingSaves.removeFirst()
                    self.pendingSaveCount = self.pendingSaves.count
                    if let snapshot = mutation.snapshot { self.apply(snapshot) }
                    else { self.appliedRevision = max(self.appliedRevision, mutation.revision) }
                    self.saveErrorMessage = nil
                    if let reloadError = mutation.reloadError {
                        self.errorMessage = "报告保存操作已完成，但报告库刷新失败：\(reloadError)。请重试读取；本次不需要重新调用 AI。"
                        self.statusMessage = nil
                    } else {
                        self.errorMessage = nil
                        if mutation.location == .removed {
                            self.statusMessage = "相同报告此前已移除，缓存结果不会自动恢复这份报告。"
                        } else if mutation.snapshot?.catalog.reports.contains(where: { $0.id == saved.id }) == true {
                            self.statusMessage = "\(saved.record.moduleTitle)报告已保存，可在 AI 报告库中查看。"
                        } else {
                            self.statusMessage = "报告已保存在本地，但本次读取列表未包含它；请检查目录读取上限及读取警告后刷新。"
                        }
                    }
                } catch {
                    self.saveErrorMessage = "分析完成，报告保存失败：\(error.localizedDescription)。当前分析结果仍然保留，可重试保存。"
                    self.errorMessage = self.saveErrorMessage
                    self.isSaving = false
                    self.saveTask = nil
                    return
                }
            }
            self?.isSaving = false
            self?.saveTask = nil
        }
    }

    func removeSelectedReport() {
        guard !isRemoving, let id = selectedReportID, selectedReport != nil else { return }
        isRemoving = true
        errorMessage = nil
        removalTask = Task { [weak self, io] in
            do {
                let mutation = try await io.remove(id)
                guard let self else { return }
                if let snapshot = mutation.snapshot { self.apply(snapshot) }
                else if mutation.revision >= self.appliedRevision {
                    self.appliedRevision = mutation.revision
                    self.reports.removeAll { $0.id == id }
                    self.indexedReports.removeAll { $0.report.id == id }
                    if self.selectedReportID == id { self.selectedReportID = nil }
                    self.filter()
                }
                self.lastRemovedID = id
                self.canUndoRemoval = true
                self.statusMessage = "报告已移到本地回收目录，可以撤销移除。"
                if let reloadError = mutation.reloadError {
                    self.errorMessage = "报告已移除，但列表刷新失败：\(reloadError)。仍可撤销移除或重新读取。"
                }
                self.isRemoving = false
                self.removalTask = nil
            } catch {
                guard let self else { return }
                self.errorMessage = "移除报告失败：\(error.localizedDescription)。请重新读取后检查报告；本次没有清空列表。"
                self.isRemoving = false
                self.removalTask = nil
            }
        }
    }

    func undoRemoval() {
        guard !isRemoving, let id = lastRemovedID else { return }
        isRemoving = true
        errorMessage = nil
        removalTask = Task { [weak self, io] in
            do {
                let mutation = try await io.restore(id)
                guard let self else { return }
                if let snapshot = mutation.snapshot { self.apply(snapshot) }
                else if mutation.revision >= self.appliedRevision, let restored = mutation.report, let indexed = mutation.indexedReport {
                    self.appliedRevision = mutation.revision
                    self.reports.removeAll { $0.id == restored.id }
                    self.reports.append(restored)
                    self.reports.sort { $0.record.generatedAt > $1.record.generatedAt }
                    self.indexedReports.removeAll { $0.report.id == restored.id }
                    self.indexedReports.append(indexed)
                    self.indexedReports.sort { $0.report.record.generatedAt > $1.report.record.generatedAt }
                    self.filter()
                }
                self.lastRemovedID = nil
                self.canUndoRemoval = false
                self.statusMessage = "报告已恢复。"
                if let reloadError = mutation.reloadError {
                    self.errorMessage = "报告已恢复，但列表刷新失败：\(reloadError)。请重试读取；恢复的文件仍然保留。"
                }
                self.isRemoving = false
                self.removalTask = nil
            } catch {
                guard let self else { return }
                self.errorMessage = "恢复报告失败：\(error.localizedDescription)。回收记录仍然保留，请修复后重试。"
                self.isRemoving = false
                self.removalTask = nil
            }
        }
    }

    /// The save panel freezes this report before opening, even if selection changes.
    func exportReport(_ report: AISavedReport, to destination: URL, format: AIReportExportFormat) {
        guard !isExporting else { return }
        isExporting = true
        errorMessage = nil
        lastExportURL = nil
        exportTask = Task { [weak self, io] in
            do {
                try await io.export(report, to: destination, format: format)
                guard let self else { return }
                self.lastExportURL = destination
                self.statusMessage = "报告已导出为 \(format.title)：\(destination.lastPathComponent)。"
                self.isExporting = false
                self.exportTask = nil
            } catch {
                guard let self else { return }
                self.errorMessage = "导出报告失败：\(error.localizedDescription)"
                self.isExporting = false
                self.exportTask = nil
            }
        }
    }

    func exportSelectedReport(to destination: URL, format: AIReportExportFormat) {
        guard let report = selectedReport else { return }
        exportReport(report, to: destination, format: format)
    }

    private func apply(_ snapshot: ReportLibrarySnapshot) {
        guard snapshot.revision >= appliedRevision else { return }
        appliedRevision = snapshot.revision
        hasLoaded = true
        reports = snapshot.catalog.reports
        warnings = snapshot.catalog.warnings
        indexedReports = snapshot.indexed
        let titles = reports.reduce(into: [String: String]()) { titles, report in
            if titles[report.record.moduleID] == nil { titles[report.record.moduleID] = report.record.moduleTitle }
        }
        moduleChoices = titles.map { AIReportModuleChoice(id: $0.key, title: $0.value) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if let selectedModuleID, titles[selectedModuleID] == nil {
            self.selectedModuleID = nil
        }
        if let selectedReportID, !reports.contains(where: { $0.id == selectedReportID }) {
            self.selectedReportID = nil
        }
        filter()
    }

    private func filter(debounce: Bool = false) {
        filterTask?.cancel()
        filterOperation?.cancel()
        let generation = UUID()
        filterGeneration = generation
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        let moduleID = selectedModuleID
        let indexed = indexedReports
        isFiltering = true
        filterTask = Task { [weak self] in
            if debounce {
                do { try await Task.sleep(nanoseconds: 200_000_000) }
                catch { return }
            }
            guard !Task.isCancelled, let self, self.filterGeneration == generation else { return }
            let operation = Task.detached(priority: .userInitiated) { () -> [AISavedReport]? in
                var filtered: [AISavedReport] = []
                for item in indexed {
                    guard !Task.isCancelled else { return nil }
                    guard moduleID == nil || moduleID == item.report.record.moduleID else { continue }
                    if terms.allSatisfy({ item.searchText.contains($0) }) { filtered.append(item.report) }
                }
                return filtered
            }
            self.filterOperation = operation
            let matches = await operation.value
            guard !Task.isCancelled, self.filterGeneration == generation, let matches else { return }
            self.filteredReports = matches
            if let selected = self.selectedReportID, !matches.contains(where: { $0.id == selected }) {
                self.selectedReportID = nil
            }
            self.isFiltering = false
            self.filterTask = nil
            self.filterOperation = nil
        }
    }
}
