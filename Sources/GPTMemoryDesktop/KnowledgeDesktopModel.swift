import Foundation
import Combine
import GPTAnalysisKit

private struct KnowledgeSnapshot { let sequence: Int; let catalog: KnowledgeCatalog }
private actor KnowledgeIO {
    let store: KnowledgeStore
    var sequence = 0
    init(store: KnowledgeStore) { self.store = store }
    private func wrap(_ catalog: KnowledgeCatalog) -> KnowledgeSnapshot { sequence += 1; return .init(sequence: sequence, catalog: catalog) }
    func load() throws -> KnowledgeSnapshot { wrap(try store.load()) }
    func save(_ draft: KnowledgeDraft, expected: KnowledgeEntry?, reason: String) throws -> KnowledgeSnapshot {
        wrap(try store.save(draft, expected: expected, reason: reason))
    }
    func merge(_ draft: KnowledgeDraft, target: KnowledgeEntry, source: KnowledgeEntry) throws -> KnowledgeSnapshot {
        wrap(try store.merge(draft, target: target, source: source))
    }
    func sources(root: URL) throws -> KnowledgeSourceCatalog { try CodexMemoryReader(rootURL: root).read() }
}
struct KnowledgeEditRequest: Identifiable {
    let id = UUID()
    var draft: KnowledgeDraft
    let expected: KnowledgeEntry?
    var mergeSource: KnowledgeEntry? = nil
    var reason = "编辑"
}

@MainActor
final class KnowledgeDesktopModel: ObservableObject {
    @Published private(set) var catalog = KnowledgeCatalog()
    @Published private(set) var sourceCatalog = KnowledgeSourceCatalog()
    @Published private(set) var filteredEntries: [KnowledgeEntry] = []
    @Published private(set) var filteredSources: [KnowledgeSourceDocument] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isReadingSources = false
    @Published private(set) var isFiltering = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var operationError: String?
    @Published private(set) var sourceError: String?
    @Published private(set) var status: String?
    @Published var editor: KnowledgeEditRequest?
    @Published var query = "" { didSet { filter() } }
    @Published var projectFilter = "" { didSet { filter() } }
    @Published var originFilter: KnowledgeOrigin? { didSet { filter() } }
    @Published var stateFilter: KnowledgeState? { didSet { filter() } }
    @Published var includeArchived = false { didSet { filter() } }
    let directoryURL: URL
    @Published private(set) var sourceRoot: URL
    private let io: KnowledgeIO
    private var appliedSequence = 0
    private var filterTask: Task<Void, Never>?
    private var filterGeneration = UUID()
    init(directoryURL: URL, sourceRoot: URL) {
        self.directoryURL = directoryURL; self.sourceRoot = sourceRoot
        io = KnowledgeIO(store: KnowledgeStore(directoryURL: directoryURL))
    }
    func loadIfNeeded() async {
        if !hasLoaded { await reload() }
    }
    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        do { apply(try await io.load()); loadError = nil; hasLoaded = true }
        catch { loadError = error.localizedDescription; hasLoaded = true }
        isLoading = false
    }
    func readSources(root: URL? = nil) async {
        guard !isReadingSources else { return }
        if let root { sourceRoot = root }
        isReadingSources = true
        do { sourceCatalog = try await io.sources(root: sourceRoot); sourceError = nil }
        catch { sourceCatalog = .init(); sourceError = error.localizedDescription }
        isReadingSources = false; filter()
    }
    func save(_ request: KnowledgeEditRequest) async -> Bool {
        guard !isSaving else { return false }
        guard hasLoaded, loadError == nil else { operationError = "请先成功读取记忆库。"; return false }
        isSaving = true; operationError = nil
        do {
            let result: KnowledgeSnapshot
            if let source = request.mergeSource, let target = request.expected {
                result = try await io.merge(request.draft, target: target, source: source)
            } else { result = try await io.save(request.draft, expected: request.expected, reason: request.reason) }
            apply(result); status = "已保存：" + request.draft.title + "（仅 GPT Manager）"; isSaving = false
            return true
        } catch { operationError = error.localizedDescription; isSaving = false; return false }
    }
    func changeState(_ entry: KnowledgeEntry, to state: KnowledgeState) async {
        var draft = entry.current; draft.state = state
        _ = await save(.init(draft: draft, expected: entry, reason: state.title))
    }
    func beginMerge(_ entries: [KnowledgeEntry]) {
        guard entries.count == 2, entries[0].current.scopeIdentity == entries[1].current.scopeIdentity,
              entries.allSatisfy({ $0.current.state != .archived }) else {
            operationError = "请选择同一范围、同一项目或会话的两条非归档记忆，再审核合并正文。"; return
        }
        let target = entries[0], source = entries[1]
        var draft = target.current
        draft.body = target.current.body + "\n\n" + source.current.body
        editor = .init(draft: draft, expected: target, mergeSource: source, reason: "合并记忆")
    }
    private func apply(_ snapshot: KnowledgeSnapshot) {
        guard snapshot.sequence > appliedSequence else { return }
        appliedSequence = snapshot.sequence; catalog = snapshot.catalog; filter()
    }
    private func filter() {
        filterTask?.cancel(); let generation = UUID(); filterGeneration = generation; isFiltering = true
        let entries = catalog.entries, sources = sourceCatalog.documents
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let project = projectFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = originFilter, state = stateFilter, archived = includeArchived
        filterTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            let operation = Task.detached(priority: .utility) { () -> ([KnowledgeEntry], [KnowledgeSourceDocument]) in
                let matchingEntries = entries.filter { entry in
                    let value = entry.current
                    guard (archived || state == .archived || value.state != .archived), state == nil || value.state == state,
                          origin == nil || (origin == .manual ? value.sources.isEmpty || value.sources.contains { $0.origin == .manual } : value.sources.contains { $0.origin == origin }),
                          project.isEmpty || value.projectPath.localizedCaseInsensitiveContains(project) else { return false }
                    let text = value.title + "\n" + value.body + "\n" + value.sources.map { $0.label + " " + $0.locator }.joined(separator: "\n")
                    return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
                }.sorted { $0.versions.last!.savedAt > $1.versions.last!.savedAt }
                let matchingSources = sources.filter { value in
                    guard project.isEmpty || value.text.localizedCaseInsensitiveContains(project) else { return false }
                    return terms.allSatisfy { value.relativePath.localizedCaseInsensitiveContains($0) || value.text.localizedCaseInsensitiveContains($0) }
                }
                return (matchingEntries, matchingSources)
            }
            let result = await operation.value
            guard !Task.isCancelled, let self, self.filterGeneration == generation else { return }
            self.filteredEntries = result.0; self.filteredSources = result.1; self.isFiltering = false
        }
    }
}
