import Foundation
import Combine
import GPTSessionKit

/// A total of recorded values. Missing usage is deliberately distinct from zero.
struct SessionTokenTotal: Sendable {
    let value: Int?
    let missingSessionCount: Int
    let isOverflow: Bool

    var displayValue: String {
        guard !isOverflow else { return "超出范围" }
        guard let value else { return "未记录" }
        let formatted = value.formatted(.number.locale(Locale(identifier: "zh_CN")))
        return missingSessionCount == 0 ? formatted : "≥ \(formatted)"
    }

    var detail: String {
        if isOverflow { return "日志记录的合计超出数值范围" }
        if value == nil { return "日志中没有这项用量" }
        if missingSessionCount > 0 { return "\(missingSessionCount) 个会话未记录，显示已知合计" }
        return "当前筛选内的日志记录值"
    }
}

private enum SessionTokenMetric: CaseIterable, Hashable, Sendable {
    case input, cachedInput, output, reasoningOutput, recordedTotal, effectiveTotal

    var keyPath: KeyPath<CodexTokenUsage, Int?> {
        switch self {
        case .input: return \.input
        case .cachedInput: return \.cachedInput
        case .output: return \.output
        case .reasoningOutput: return \.reasoningOutput
        case .recordedTotal: return \.total
        case .effectiveTotal: return \.effectiveTotal
        }
    }
}

private struct SessionFilter: Equatable, Sendable {
    let query: String
    let project: String?
    let includeArchived: Bool
    let onlyFavoriteSessions: Bool
    let projectTagKey: String?

    func includesMetadata(_ summary: CodexSessionSummary, management: SessionManagementIndex) -> Bool {
        let projectID = SessionManagementIndex.projectPath(for: summary)
        if let projectTagKey, !management.hasProjectTag(projectID, key: projectTagKey) { return false }
        return (includeArchived || !summary.isArchived) && (project == nil || project == projectID)
            && (!onlyFavoriteSessions || management.isFavorite(summary))
    }
}

private func sessionProjectPaths(_ sessions: [CodexSessionSummary]) -> [String] {
    Array(Set(sessions.map { summary in
        let path = summary.projectPath
        return path.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? SessionProjectSummary.unknownID
    })).sorted()
}

private struct SessionFilterResult: Sendable {
    let summaries: [CodexSessionSummary]
    let positions: [String: Int]
    let analytics: SessionAnalytics
    let totals: [SessionTokenMetric: SessionTokenTotal]
    let matchingUserMessageIDs: [String]

    static func make(sessions: [CodexSessionSummary], filter: SessionFilter,
                     previousMatches: Set<String>?, transcriptIndex: SessionTranscriptIndex?, selectedSessionID: String?,
                     management: SessionManagementIndex) -> SessionFilterResult? {
        var favorites: [CodexSessionSummary] = []
        var others: [CodexSessionSummary] = []
        let terms = filter.query.split(whereSeparator: \.isWhitespace).map(String.init)
        let tagTerms = terms.map(SessionManagementStore.tagKey)
        for summary in sessions {
            guard !Task.isCancelled else { return nil }
            guard filter.includesMetadata(summary, management: management) else { continue }
            if let previousMatches {
                guard previousMatches.contains(summary.id) else { continue }
            } else if !filter.query.isEmpty {
                let metadata = management.entry(for: summary)
                let tagKeys = management.tagSearchKeys(SessionManagementIndex.projectPath(for: summary))
                let matches = terms.indices.allSatisfy { term in
                    let value = terms[term]
                    return summary.matches(query: value)
                        || (metadata?.displayName?.localizedCaseInsensitiveContains(value) ?? false)
                        || (metadata?.note?.localizedCaseInsensitiveContains(value) ?? false)
                        || tagKeys.contains { $0.contains(tagTerms[term]) }
                }
                guard matches else { continue }
            }
            if management.isFavorite(summary) { favorites.append(summary) }
            else { others.append(summary) }
        }
        // Stable partition preserves the existing newest-first order inside each
        // group. Bookmarking does not alter the source log or analytics identity.
        let summaries = favorites + others
        let positions = Dictionary(summaries.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        var totals: [SessionTokenMetric: SessionTokenTotal] = [:]
        for metric in SessionTokenMetric.allCases {
            guard !Task.isCancelled else { return nil }
            var sum = 0, recorded = 0, missing = 0
            var overflow = false
            for summary in summaries {
                if summary.tokens.hasOverflow(for: metric.keyPath) { overflow = true }
                guard let value = summary.tokens[keyPath: metric.keyPath] else { missing += 1; continue }
                recorded += 1
                let next = sum.addingReportingOverflow(value)
                if next.overflow { overflow = true } else { sum = next.partialValue }
            }
            totals[metric] = SessionTokenTotal(value: recorded > 0 && !overflow ? sum : nil,
                missingSessionCount: missing, isOverflow: overflow)
        }
        guard !Task.isCancelled else { return nil }
        let hasVisibleDetail = selectedSessionID.map { positions[$0] != nil } ?? false
        let matches = hasVisibleDetail ? transcriptIndex?.matchingUserMessages(query: filter.query) ?? [] : []
        guard !Task.isCancelled else { return nil }
        return SessionFilterResult(summaries: summaries, positions: positions, analytics: SessionAnalytics(sessions: summaries),
                                   totals: totals, matchingUserMessageIDs: matches)
    }
}

/// Built alongside the file read off the main actor. UI redraws only look up
/// existing indexes, including when a query or a message disclosure changes.
struct SessionTranscriptIndex: Sendable {
    let prompts: [SessionMessage]
    private let indicesByID: [String: Int]
    private let callsByID: [String: [SessionMessage]]
    private let resultsByID: [String: [SessionMessage]]

    init(messages: [SessionMessage]) throws {
        var prompts: [SessionMessage] = []
        var indices: [String: Int] = [:]
        var calls: [String: [SessionMessage]] = [:]
        var results: [String: [SessionMessage]] = [:]
        for (index, message) in messages.enumerated() {
            try Task.checkCancellation()
            if indices[message.id] == nil { indices[message.id] = index }
            if message.kind == .user { prompts.append(message) }
            if let callID = message.callID {
                if message.kind == .toolCall { calls[callID, default: []].append(message) }
                if message.kind == .toolResult { results[callID, default: []].append(message) }
            }
        }
        self.prompts = prompts
        indicesByID = indices
        callsByID = calls
        resultsByID = results
    }

    func index(of id: String) -> Int? { indicesByID[id] }

    func relatedMessages(for message: SessionMessage) -> [SessionMessage] {
        guard let callID = message.callID else { return [] }
        switch message.kind {
        case .toolCall: return resultsByID[callID] ?? []
        case .toolResult: return callsByID[callID] ?? []
        default: return []
        }
    }

    func matchingUserMessages(query: String) -> [String] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        var matches: [String] = []
        for prompt in prompts {
            guard !Task.isCancelled else { return [] }
            if terms.allSatisfy({ prompt.text.localizedCaseInsensitiveContains($0) }) { matches.append(prompt.id) }
        }
        return matches
    }
}

/// Non-overlapping pages keep earlier/next navigation and directory jumps consistent.
enum SessionMessagePage {
    static let size = 100
    static func latestStart(messageCount: Int) -> Int { max(0, (messageCount - 1) / size * size) }
    static func start(containing index: Int) -> Int { max(0, index / size * size) }
}

private struct SessionTranscriptLoad: Sendable {
    let transcript: SessionTranscript
    let index: SessionTranscriptIndex
    let matchingUserMessageIDs: [String]
}

/// Search may finish hundreds of small logs between two screen frames. Do not
/// enqueue one main-actor task for every log just to update a progress label.
private final class SessionSearchProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPublished = -Double.infinity

    func shouldPublish(_ count: Int, total: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard count == total || now - lastPublished >= 0.1 else { return false }
        lastPublished = now
        return true
    }
}

@MainActor
final class SessionDesktopModel: ObservableObject {
    @Published private(set) var sessions: [CodexSessionSummary] = []
    @Published private(set) var filteredSessions: [CodexSessionSummary] = []
    @Published private(set) var catalogWarnings: [String] = []
    @Published private(set) var transcript: SessionTranscript?
    @Published private(set) var transcriptIndex: SessionTranscriptIndex?
    @Published private(set) var matchingUserMessageIDs: Set<String> = []
    @Published private(set) var firstMatchingUserMessageID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingTranscript = false
    @Published private(set) var isFiltering = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var transcriptErrorMessage: String?
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var projectPaths: [String] = []
    @Published private(set) var availableProjectTags: [String] = []
    @Published private(set) var analytics = SessionAnalytics(sessions: [])
    @Published private(set) var displayedProjects: [SessionProjectSummary] = []
    @Published var query = "" { didSet { if query != oldValue { updateFilteredSessions(debounce: true) } } }
    @Published var selectedProject: String? { didSet { if selectedProject != oldValue { updateFilteredSessions() } } }
    @Published var includeArchived = false { didSet { if includeArchived != oldValue { updateFilteredSessions() } } }
    @Published var onlyFavoriteSessions = false { didSet { if onlyFavoriteSessions != oldValue { updateFilteredSessions() } } }
    @Published var onlyFavoriteProjects = false {
        didSet { if onlyFavoriteProjects != oldValue { updateDisplayedProjects() } }
    }
    @Published var selectedProjectTag: String? {
        didSet {
            guard selectedProjectTag != oldValue else { return }
            updateTagChoices()
            updateFilteredSessions()
        }
    }

    let rootURL: URL
    let management: SessionManagementModel
    private var managementSubscription: AnyCancellable?
    private let catalogLoader: @Sendable () throws -> SessionCatalog
    private let transcriptLoader: @Sendable (CodexSessionSummary) throws -> SessionTranscript
    private let searchTranscriptLoader: @Sendable (CodexSessionSummary) throws -> SessionTranscript
    private var catalogGeneration = UUID()
    private var transcriptGeneration = UUID()
    private var catalogTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var catalogOperation: Task<Result<SessionCatalog, Error>, Never>?
    private var transcriptOperation: Task<Result<SessionTranscriptLoad, Error>, Never>?
    private var filterTask: Task<Void, Never>?
    private var filterOperation: Task<SessionFilterResult?, Never>?
    private var filterGeneration = UUID()
    private var lastAppliedFilter: SessionFilter?
    private var lastMatchedIDs: Set<String> = []
    private var tokenTotals: [SessionTokenMetric: SessionTokenTotal] = [:]
    private var pendingSelectionReload = false
    private var catalogProjectTags: [String] = []
    private var sessionPositions: [String: Int] = [:]
    private var filteredSessionPositions: [String: Int] = [:]

    init(rootURL: URL = CodexSessionRepository.defaultRootURL, indexDirectoryURL: URL? = nil,
         managementDirectoryURL: URL? = nil) {
        let repository = CodexSessionRepository(rootURL: rootURL, indexDirectoryURL: indexDirectoryURL)
        self.rootURL = rootURL
        management = SessionManagementModel(directoryURL: managementDirectoryURL, sourceRootURL: rootURL)
        catalogLoader = { try repository.loadCatalog() }
        transcriptLoader = { try repository.loadTranscript(for: $0) }
        searchTranscriptLoader = { try repository.loadTranscriptForSearch(for: $0) }
        connectManagement()
    }

    /// Fixtures inject loaders, so checks never touch the user's real sessions.
    init(rootURL: URL,
         catalogLoader: @escaping @Sendable () throws -> SessionCatalog,
         transcriptLoader: @escaping @Sendable (CodexSessionSummary) throws -> SessionTranscript,
         managementDirectoryURL: URL? = nil) {
        self.rootURL = rootURL
        management = SessionManagementModel(directoryURL: managementDirectoryURL, sourceRootURL: rootURL)
        self.catalogLoader = catalogLoader
        self.transcriptLoader = transcriptLoader
        searchTranscriptLoader = transcriptLoader
        connectManagement()
    }

    private func connectManagement() {
        managementSubscription = management.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        management.didChange = { [weak self] in
            guard let self else { return }
            self.sortProjectPaths()
            self.updateDisplayedProjects()
            self.lastAppliedFilter = nil
            self.lastMatchedIDs = []
            self.updateFilteredSessions()
        }
    }

    private func sortProjectPaths() {
        let favorites = management.index.favoriteProjects
        projectPaths = sessionProjectPaths(sessions).sorted {
            let left = favorites.contains(SessionManagementIndex.projectID($0))
            let right = favorites.contains(SessionManagementIndex.projectID($1))
            if left != right { return left }
            return $0 < $1
        }
        var labels: [String: String] = [:]
        for path in projectPaths {
            for tag in projectTags(path) {
                let key = SessionManagementStore.tagKey(tag)
                if let previous = labels[key] { labels[key] = min(previous, tag) }
                else { labels[key] = tag }
            }
        }
        catalogProjectTags = labels.values.sorted {
            let left = SessionManagementStore.tagKey($0), right = SessionManagementStore.tagKey($1)
            return left == right ? $0 < $1 : left < right
        }
        updateTagChoices()
    }

    private func updateTagChoices() {
        var choices = catalogProjectTags
        if let selectedProjectTag {
            let key = SessionManagementStore.tagKey(selectedProjectTag)
            if let index = choices.firstIndex(where: { SessionManagementStore.tagKey($0) == key }) {
                choices[index] = selectedProjectTag
            } else { choices.append(selectedProjectTag) }
        }
        availableProjectTags = choices
    }

    private func updateDisplayedProjects() {
        var favorites: [SessionProjectSummary] = [], others: [SessionProjectSummary] = []
        for project in analytics.projects {
            if isFavoriteProject(project.id) { favorites.append(project) }
            else if !onlyFavoriteProjects { others.append(project) }
        }
        displayedProjects = favorites + others
    }

    func localTitle(for summary: CodexSessionSummary) -> String { management.index.entry(for: summary)?.displayName ?? "" }
    func displayTitle(for summary: CodexSessionSummary) -> String {
        management.index.entry(for: summary)?.displayName ?? summary.title
    }
    func note(for summary: CodexSessionSummary) -> String { management.index.entry(for: summary)?.note ?? "" }
    func isFavorite(_ summary: CodexSessionSummary) -> Bool { management.index.isFavorite(summary) }
    func isFavoriteProject(_ path: String) -> Bool { management.index.isFavoriteProject(path) }
    func projectTags(_ path: String) -> [String] { management.index.entryForProject(path)?.tags ?? [] }

    /// Frozen editor targets can survive normal refreshes and detail loads, but
    /// may not write metadata for a file whose actual session identity changed.
    private func currentManagementTarget(_ summary: CodexSessionSummary) -> Bool {
        guard !isLoading, let position = sessionPositions[summary.id] else { return false }
        let current = sessions[position]
        return current.managementID == summary.managementID
            && current.fileURL.standardizedFileURL == summary.fileURL.standardizedFileURL
    }

    func toggleSessionFavorite(_ summary: CodexSessionSummary) {
        guard currentManagementTarget(summary), !management.isSaving else { return }
        management.setFavorite(kind: .session, itemID: summary.managementID, value: !isFavorite(summary))
    }

    func toggleProjectFavorite(_ path: String) {
        guard projectPaths.contains(path), !management.isSaving else { return }
        management.setFavorite(kind: .project, itemID: SessionManagementIndex.projectID(path),
                               value: !isFavoriteProject(path))
    }

    func saveSessionMetadata(_ summary: CodexSessionSummary, title: String, note: String,
                             baseline: SessionManagementEntry? = nil) async -> Bool {
        guard currentManagementTarget(summary) else {
            management.reportError("会话正在刷新或来源已变化，请重新选择会话后编辑。", detailsItemID: summary.managementID)
            return false
        }
        guard !management.isSaving else { return false }
        return await management.saveDetails(itemID: summary.managementID, title: title, note: note, baseline: baseline)
    }

    func discardFailedSessionMetadata(_ summary: CodexSessionSummary) {
        management.discardFailedDetails(itemID: summary.managementID)
    }

    func saveProjectTags(_ path: String, tags: [String], baseline: SessionManagementEntry) async -> Bool {
        guard !isLoading, projectPaths.contains(path) else {
            management.reportProjectTagsError("项目正在刷新或来源已变化，请重新选择项目后编辑。",
                                              itemID: SessionManagementIndex.projectID(path))
            return false
        }
        guard !management.isSaving else { return false }
        return await management.saveProjectTags(itemID: SessionManagementIndex.projectID(path), tags: tags, baseline: baseline)
    }

    func discardFailedProjectTags(_ path: String) {
        management.discardFailedProjectTags(itemID: SessionManagementIndex.projectID(path))
    }

    private var currentFilter: SessionFilter {
        SessionFilter(query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                      project: selectedProject, includeArchived: includeArchived, onlyFavoriteSessions: onlyFavoriteSessions,
                      projectTagKey: selectedProjectTag.map(SessionManagementStore.tagKey))
    }

    private func updateFilteredSessions(debounce: Bool = false, reloadSelection: Bool = false,
                                        reuseMatches: Bool = false) {
        filterTask?.cancel()
        filterOperation?.cancel()
        filterTask = nil
        filterOperation = nil
        let generation = UUID()
        filterGeneration = generation
        pendingSelectionReload = pendingSelectionReload || reloadSelection
        let filter = currentFilter
        let metadata = management.index
        // Project/archive changes need no transcript search to discard hidden detail.
        if let selectedSession, !filter.includesMetadata(selectedSession, management: metadata) { clearSelection() }
        let previousMatches = reuseMatches && lastAppliedFilter == filter ? lastMatchedIDs : nil
        let snapshot = sessions
        let index = transcriptIndex
        let selectedID = selectedSessionID
        isFiltering = true
        filterTask = Task { [weak self] in
            if debounce && !filter.query.isEmpty {
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
            }
            guard let self, self.filterGeneration == generation, !Task.isCancelled else { return }
            let operation = Task.detached(priority: .userInitiated) {
                SessionFilterResult.make(sessions: snapshot, filter: filter, previousMatches: previousMatches,
                                         transcriptIndex: index, selectedSessionID: selectedID, management: metadata)
            }
            self.filterOperation = operation
            let result = await operation.value
            guard self.filterGeneration == generation, !Task.isCancelled else { return }
            // A completed Task keeps its value alive as long as its handle does.
            // Publish the result without keeping another catalog-sized snapshot.
            self.filterOperation = nil
            self.filterTask = nil
            guard let result else { self.isFiltering = false; return }
            self.filteredSessionPositions = result.positions
            self.filteredSessions = result.summaries
            self.tokenTotals = result.totals
            self.analytics = result.analytics
            self.updateDisplayedProjects()
            self.matchingUserMessageIDs = Set(result.matchingUserMessageIDs)
            self.firstMatchingUserMessageID = result.matchingUserMessageIDs.first
            self.lastAppliedFilter = filter
            self.lastMatchedIDs = Set(result.summaries.map(\.id))
            self.isFiltering = false
            self.reconcileSelection()
            let needsReload = self.pendingSelectionReload
            self.pendingSelectionReload = false
            if needsReload, let selected = self.selectedSession {
                self.select(selected.id, forceReload: true)
            }
        }
    }

    var selectedSession: CodexSessionSummary? {
        guard let selectedSessionID, let position = filteredSessionPositions[selectedSessionID] else { return nil }
        return filteredSessions[position]
    }

    func total(_ keyPath: KeyPath<CodexTokenUsage, Int?>) -> SessionTokenTotal {
        guard let metric = SessionTokenMetric.allCases.first(where: { $0.keyPath == keyPath }),
              let total = tokenTotals[metric] else {
            return SessionTokenTotal(value: nil, missingSessionCount: filteredSessions.count, isOverflow: false)
        }
        return total
    }

    func selectProject(_ path: String?) {
        selectedProject = path
    }

    @Published private(set) var fullTextResult: SessionSearchResult?
    @Published private(set) var isSearchingFullText = false
    @Published private(set) var fullTextScanned = 0
    @Published private(set) var fullTextTotal = 0
    @Published private(set) var fullTextError: String?
    private var fullTextTask: Task<Void, Never>?
    private var fullTextOperation: Task<SessionSearchResult, Error>?
    private var fullTextGeneration = UUID()

    func searchFullText(query: String, scope: SessionSearchScope, project: String?, archived: Bool) {
        cancelFullTextSearch()
        fullTextResult = nil
        fullTextError = nil
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = UUID()
        fullTextGeneration = generation
        let candidates = sessions.filter { (archived || !$0.isArchived) &&
            (project == nil || SessionManagementIndex.projectPath(for: $0) == project) }
        let loader = searchTranscriptLoader
        fullTextScanned = 0
        fullTextTotal = candidates.count
        isSearchingFullText = true
        let operation = Task.detached(priority: .utility) {
            let gate = SessionSearchProgressGate()
            return try SessionFullTextSearch.search(sessions: candidates, query: query, scope: scope, progress: { [weak self] count, total in
                guard gate.shouldPublish(count, total: total) else { return }
                Task { @MainActor in
                    guard let self, self.fullTextGeneration == generation, self.isSearchingFullText else { return }
                    self.fullTextScanned = count
                }
            }, loader: loader)
        }
        fullTextOperation = operation
        fullTextTask = Task { [weak self] in
            do {
                let result = try await operation.value
                guard let self, self.fullTextGeneration == generation, !Task.isCancelled else { return }
                self.fullTextResult = result
                self.fullTextScanned = result.scannedSessions + result.skippedSessions
                self.isSearchingFullText = false
                self.fullTextOperation = nil
                self.fullTextTask = nil
            } catch {
                guard let self, self.fullTextGeneration == generation, !Task.isCancelled else { return }
                self.isSearchingFullText = false
                self.fullTextOperation = nil
                self.fullTextTask = nil
                if !(error is CancellationError) { self.fullTextError = "全文搜索失败：\(error.localizedDescription)" }
            }
        }
    }

    func cancelFullTextSearch() {
        fullTextTask?.cancel()
        fullTextOperation?.cancel()
        fullTextTask = nil
        fullTextOperation = nil
        fullTextGeneration = UUID()
        isSearchingFullText = false
    }

    func loadIfNeeded() {
        management.loadIfNeeded()
        guard !hasLoaded, !isLoading else { return }
        refresh()
    }

    func refresh() {
        if !management.isLoading { management.refresh() }
        catalogTask?.cancel()
        catalogOperation?.cancel()
        catalogTask = nil
        catalogOperation = nil
        // A pending detail read shares the repository lock with the catalog.
        // Stop it before scanning, so refresh does not queue behind obsolete I/O.
        if isLoadingTranscript {
            transcriptTask?.cancel()
            transcriptOperation?.cancel()
            transcriptTask = nil
            transcriptOperation = nil
            transcriptGeneration = UUID()
        }
        let generation = UUID()
        catalogGeneration = generation
        isLoading = true
        errorMessage = nil
        let loader = catalogLoader
        let operation = Task.detached(priority: .utility) { Result { try loader() } }
        catalogOperation = operation
        catalogTask = Task { [weak self] in
            let result = await operation.value
            guard let self, self.catalogGeneration == generation, !Task.isCancelled else { return }
            self.catalogOperation = nil
            self.catalogTask = nil
            self.isLoading = false
            self.hasLoaded = true
            switch result {
            case .success(let catalog):
                // A detail read started from the old catalog must not put its stale
                // summary back while the new catalog's filters finish in background.
                self.transcriptTask?.cancel()
                self.transcriptOperation?.cancel()
                self.transcriptTask = nil
                self.transcriptOperation = nil
                self.transcriptGeneration = UUID()
                self.isLoadingTranscript = false
                self.sessions = catalog.sessions
                self.sessionPositions = Dictionary(catalog.sessions.enumerated().map { ($0.element.id, $0.offset) },
                                                    uniquingKeysWith: { first, _ in first })
                self.catalogWarnings = catalog.warnings
                self.sortProjectPaths()
                self.lastAppliedFilter = nil
                self.lastMatchedIDs = []
                if let project = self.selectedProject, !self.projectPaths.contains(project) {
                    self.selectedProject = nil
                }
                self.updateFilteredSessions(reloadSelection: true)
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                // Keep a previous successful catalog available after a refresh failure.
                self.errorMessage = "读取 Codex 会话失败：\(error.localizedDescription)"
                self.isLoadingTranscript = false
                if self.transcript == nil, self.selectedSessionID != nil {
                    self.updateFilteredSessions(reloadSelection: true)
                }
            }
        }
    }

    func select(_ id: String, forceReload: Bool = false) {
        guard !isFiltering else { return }
        guard let position = filteredSessionPositions[id] else {
            clearSelection()
            return
        }
        let summary = filteredSessions[position]
        if !forceReload, selectedSessionID == id,
           (transcript != nil || isLoadingTranscript) { return }
        transcriptTask?.cancel()
        transcriptOperation?.cancel()
        transcriptTask = nil
        transcriptOperation = nil
        let generation = UUID()
        transcriptGeneration = generation
        selectedSessionID = id
        transcript = nil
        transcriptIndex = nil
        matchingUserMessageIDs = []
        firstMatchingUserMessageID = nil
        transcriptErrorMessage = nil
        isLoadingTranscript = true
        let loader = transcriptLoader
        let requestedFilter = currentFilter
        let operation = Task.detached(priority: .utility) {
            Result {
                let transcript = try loader(summary)
                let index = try SessionTranscriptIndex(messages: transcript.messages)
                return SessionTranscriptLoad(transcript: transcript, index: index,
                    matchingUserMessageIDs: index.matchingUserMessages(query: requestedFilter.query))
            }
        }
        transcriptOperation = operation
        transcriptTask = Task { [weak self] in
            let result = await operation.value
            guard let self, self.transcriptGeneration == generation,
                  self.selectedSessionID == id, self.selectedSession != nil,
                  !Task.isCancelled else { return }
            self.transcriptOperation = nil
            self.transcriptTask = nil
            self.isLoadingTranscript = false
            switch result {
            case .success(let loaded):
                let transcript = loaded.transcript
                guard transcript.summary.id == id else {
                    self.transcriptErrorMessage = "会话文件标识已变化，请刷新后重新选择。"
                    return
                }
                self.transcript = transcript
                self.transcriptIndex = loaded.index
                var unchangedSearchFields = false
                if let index = self.sessionPositions[id] {
                    let previous = self.sessions[index]
                    // Opening a previously indexed log changes only visible detail.
                    // Rebuilding every project and chart here blocked rapid selection
                    // even though all catalog/filter/analytics inputs were identical.
                    if previous == transcript.summary, self.currentFilter == requestedFilter,
                       self.lastAppliedFilter == requestedFilter, !self.isFiltering {
                        self.matchingUserMessageIDs = Set(loaded.matchingUserMessageIDs)
                        self.firstMatchingUserMessageID = loaded.matchingUserMessageIDs.first
                        return
                    }
                    unchangedSearchFields = previous.title == transcript.summary.title
                        && previous.managementID == transcript.summary.managementID
                        && previous.projectPath == transcript.summary.projectPath
                        && previous.sessionID == transcript.summary.sessionID
                        && previous.isArchived == transcript.summary.isArchived
                        && previous.searchText == transcript.summary.searchText
                    self.sessions[index] = transcript.summary
                }
                self.sortProjectPaths()
                self.updateFilteredSessions(reuseMatches: unchangedSearchFields)
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                self.transcriptErrorMessage = "读取会话内容失败：\(error.localizedDescription)"
            }
        }
    }

    func clearSelection() {
        transcriptTask?.cancel()
        transcriptOperation?.cancel()
        transcriptTask = nil
        transcriptOperation = nil
        transcriptGeneration = UUID()
        selectedSessionID = nil
        transcript = nil
        transcriptIndex = nil
        matchingUserMessageIDs = []
        firstMatchingUserMessageID = nil
        transcriptErrorMessage = nil
        isLoadingTranscript = false
    }

    private func reconcileSelection() {
        guard selectedSessionID != nil, selectedSession == nil else { return }
        clearSelection()
    }
}
