import Foundation
import Observation
import GPTAnalysisKit

// Normalize once when a snapshot arrives. Searching bytes avoids repeated
// locale-aware scans; grapheme boundaries preserve native substring semantics.
struct KnowledgeSearchTerm: Sendable {
    let text: String
    let original: String
    let bytes: Data
    let hasNumber: Bool
    let hasNonASCIINumber: Bool
    init(_ text: String, original: String) {
        self.text = text; self.original = original
        bytes = Data(text.utf8)
        var number = false, nonASCII = false
        for scalar in text.unicodeScalars where Self.isNumber(scalar) {
            number = true; if scalar.value > 127 { nonASCII = true }
        }
        hasNumber = number; hasNonASCIINumber = nonASCII
    }
    private static func isNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }
}
struct KnowledgeSearchText: Sendable {
    private let bytes: Data
    private let compoundCharacters: [Range<UInt32>]
    private let original: String?
    private let requiresNativeSearch: Bool
    private let hasNonASCIINumber: Bool
    init(_ text: String) {
        let folded = Self.fold(text)
        bytes = folded.bytes; hasNonASCIINumber = folded.hasNonASCIINumber
        var ranges: [Range<UInt32>] = [], offset: UInt32 = 0
        // Common prose has only independent ASCII/Han scalars. Avoid walking
        // every grapheme when there cannot be an exceptional boundary.
        if text.unicodeScalars.allSatisfy(Self.hasSimpleBoundary) {
            offset = UInt32(text.utf8.count)
        } else {
            // Preserve boundaries before folding: ß → ss and ﬃ → ffi must not
            // introduce partial matches that native search would reject.
            for character in text.precomposedStringWithCanonicalMapping {
                var length = character.utf8.count
                var compound = character.unicodeScalars.count > 1
                if character.unicodeScalars.contains(where: { $0.value > 127 && $0.properties.changesWhenCaseFolded }) {
                    let value = String(character).folding(options: .caseInsensitive, locale: .current).precomposedStringWithCanonicalMapping
                    length = value.utf8.count
                    compound = compound || value.unicodeScalars.count > 1
                }
                let end = offset + UInt32(length)
                if compound { ranges.append(offset..<end) }
                offset = end
            }
        }
        compoundCharacters = ranges
        requiresNativeSearch = Int(offset) != folded.bytes.count
        // Plain Chinese/ASCII needs no second retained string. Exceptional
        // source text shares the original buffer; only its rare boundary path
        // invokes Foundation, rather than slowing every normal query.
        original = ranges.isEmpty && !hasNonASCIINumber && !requiresNativeSearch ? nil : text
    }
    private static func hasSimpleBoundary(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0...12, 14...127, 0x3000...0x3029, 0x3030...0x303F,
             0x3400...0x9FFF, 0xFF01...0xFF60, 0x20000...0x2EBEF: return true
        default: return false
        }
    }
    static func fold(_ text: String) -> KnowledgeSearchTerm {
        .init(text.folding(options: .caseInsensitive, locale: .current).precomposedStringWithCanonicalMapping, original: text)
    }
    var byteCount: Int { bytes.count + compoundCharacters.capacity * MemoryLayout<Range<UInt32>>.stride }
    private func isCharacterBoundary(_ offset: Int) -> Bool {
        var lower = 0, upper = compoundCharacters.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let range = compoundCharacters[middle]
            if offset <= range.lowerBound { upper = middle }
            else if offset >= range.upperBound { lower = middle + 1 }
            else { return false }
        }
        return true
    }
    func contains(_ needle: KnowledgeSearchTerm) -> Bool {
        if needle.bytes.isEmpty { return true }
        if requiresNativeSearch { return original!.localizedCaseInsensitiveContains(needle.original) }
        // Native search equates numeric forms such as ①/1 and ½/1⁄2, while
        // preserving other compatibility characters. Keep that uncommon path
        // native without retaining a second copy of every indexed source.
        if needle.hasNumber && (hasNonASCIINumber || needle.hasNonASCIINumber) {
            return (original ?? String(decoding: bytes, as: UTF8.self)).localizedCaseInsensitiveContains(needle.original)
        }
        guard let range = bytes.range(of: needle.bytes) else { return false }
        if isCharacterBoundary(range.lowerBound) && isCharacterBoundary(range.upperBound) { return true }
        // Foundation handles the uncommon partial cluster case (including its
        // distinct Hangul/emoji rules); it also finds any later complete match.
        return (original ?? String(decoding: bytes, as: UTF8.self)).localizedCaseInsensitiveContains(needle.original)
    }
    func matches(_ terms: [KnowledgeSearchTerm]) -> Bool {
        for term in terms { if Task.isCancelled || !contains(term) { return false } }
        return true
    }
}
private struct IndexedKnowledgeEntry: Sendable {
    let entry: KnowledgeEntry
    let text: KnowledgeSearchText
    init(_ entry: KnowledgeEntry) {
        self.entry = entry
        let draft = entry.current
        text = .init(([draft.title, draft.body] + draft.sources.map { $0.label + " " + $0.locator }).joined(separator: "\n"))
    }
    init(entry: KnowledgeEntry, text: KnowledgeSearchText) { self.entry = entry; self.text = text }
}
private struct IndexedKnowledgeSource: Sendable {
    let source: KnowledgeSourceDocument
    let path: KnowledgeSearchText
    let text: KnowledgeSearchText
    init(_ source: KnowledgeSourceDocument) { self.source = source; path = .init(source.relativePath); text = .init(source.text) }
}
private struct KnowledgeSnapshot {
    let sequence: Int
    let catalog: KnowledgeCatalog
    let entries: [IndexedKnowledgeEntry]
}
private struct KnowledgeSourcesSnapshot {
    let catalog: KnowledgeSourceCatalog
    let sources: [IndexedKnowledgeSource]
}
private actor KnowledgeIO {
    let store: KnowledgeStore
    let originalEditor: CodexMemoryEditor
    var sequence = 0
    private var entryIndex: [String: IndexedKnowledgeEntry] = [:]
    init(store: KnowledgeStore) { self.store = store; originalEditor = CodexMemoryEditor(backupDirectory: store.directoryURL.deletingLastPathComponent().appendingPathComponent("codex-memory-backups")) }
    private func wrap(_ catalog: KnowledgeCatalog) -> KnowledgeSnapshot {
        sequence += 1
        let entries = catalog.entries.sorted { $0.versions.last!.savedAt > $1.versions.last!.savedAt }.map { entry -> IndexedKnowledgeEntry in
            if let cached = entryIndex[entry.id] {
                let before = cached.entry.current, after = entry.current
                if before.title == after.title && before.body == after.body && before.sources == after.sources {
                    return .init(entry: entry, text: cached.text)
                }
            }
            return autoreleasepool { IndexedKnowledgeEntry(entry) }
        }
        entryIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.entry.id, $0) })
        return .init(sequence: sequence, catalog: catalog, entries: entries)
    }
    func load() throws -> KnowledgeSnapshot { wrap(try store.load()) }
    func save(_ draft: KnowledgeDraft, expected: KnowledgeEntry?, reason: String) throws -> KnowledgeSnapshot {
        wrap(try store.save(draft, expected: expected, reason: reason))
    }
    func merge(_ draft: KnowledgeDraft, target: KnowledgeEntry, source: KnowledgeEntry) throws -> KnowledgeSnapshot {
        wrap(try store.merge(draft, target: target, source: source))
    }
    func trash(_ entry: KnowledgeEntry, trashed: Bool) throws -> KnowledgeSnapshot { wrap(try store.setTrashed(trashed, expected: entry)) }
    func delete(_ entry: KnowledgeEntry) throws -> KnowledgeSnapshot { wrap(try store.permanentlyDelete(expected: entry)) }
    func editOriginal(root: URL, original: String, replacement: String, action: String) throws -> CodexMemoryBackup { try originalEditor.apply(root: root, original: original, replacement: replacement, action: action) }
    func removeBackup(_ backup: CodexMemoryBackup) throws { try originalEditor.removeBackup(backup) }
    func backups() throws -> [CodexMemoryBackup] { try originalEditor.backups() }
    func restoreOriginal(_ backup: CodexMemoryBackup, root: URL) throws { _ = try originalEditor.restore(backup, root: root) }
    func sources(root: URL) throws -> KnowledgeSourcesSnapshot {
        let catalog = try CodexMemoryReader(rootURL: root).read()
        return .init(catalog: catalog, sources: catalog.documents.map { source in autoreleasepool { IndexedKnowledgeSource(source) } })
    }
}
struct KnowledgeEditRequest: Identifiable {
    let id = UUID()
    var draft: KnowledgeDraft
    let expected: KnowledgeEntry?
    var mergeSource: KnowledgeEntry? = nil
    var reason = "编辑"
}

@MainActor @Observable
final class KnowledgeDesktopModel {
    private(set) var catalog = KnowledgeCatalog()
    private(set) var sourceCatalog = KnowledgeSourceCatalog()
    private(set) var filteredEntries: [KnowledgeEntry] = []
    private(set) var filteredSources: [KnowledgeSourceDocument] = []
    private(set) var isLoading = false
    private(set) var isReadingSources = false
    private(set) var isFiltering = false
    private(set) var isSaving = false
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var operationError: String?
    private(set) var sourceError: String?
    private(set) var status: String?
    private(set) var originalBackups: [CodexMemoryBackup] = []
    var editor: KnowledgeEditRequest?
    var query = "" { didSet { if query != oldValue { filter() } } }
    var projectFilter = "" { didSet { if projectFilter != oldValue { filter() } } }
    var originFilter: KnowledgeOrigin? { didSet { if originFilter != oldValue { filter() } } }
    var stateFilter: KnowledgeState? { didSet { if stateFilter != oldValue { filter() } } }
    var showTrash = false { didSet { if showTrash != oldValue { filter() } } }
    var includeArchived = false { didSet { if includeArchived != oldValue { filter() } } }
    let directoryURL: URL
    private(set) var sourceRoot: URL
    private let io: KnowledgeIO
    @ObservationIgnored private var appliedSequence = 0
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var filterOperation: Task<([KnowledgeEntry], [KnowledgeSourceDocument])?, Never>?
    @ObservationIgnored private var filterGeneration = UUID()
    @ObservationIgnored private var indexedEntries: [IndexedKnowledgeEntry] = []
    @ObservationIgnored private var indexedSources: [IndexedKnowledgeSource] = []
    @ObservationIgnored private var snapshotVersion = 0
    @ObservationIgnored private var publishedSnapshotVersion = -1
    init(directoryURL: URL, sourceRoot: URL) {
        self.directoryURL = directoryURL; self.sourceRoot = sourceRoot
        io = KnowledgeIO(store: KnowledgeStore(directoryURL: directoryURL))
    }
    /// Account for owned normalized buffers; original strings remain shared by value.
    var searchIndexByteCount: Int {
        indexedEntries.reduce(0) { $0 + $1.text.byteCount }
            + indexedSources.reduce(0) { $0 + $1.path.byteCount + $1.text.byteCount }
    }
    deinit { filterTask?.cancel(); filterOperation?.cancel() }
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
        do {
            let snapshot = try await io.sources(root: sourceRoot)
            sourceCatalog = snapshot.catalog; indexedSources = snapshot.sources; snapshotVersion += 1; sourceError = nil
        }
        catch { sourceCatalog = .init(); indexedSources = []; snapshotVersion += 1; sourceError = error.localizedDescription }
        isReadingSources = false; filter()
    }
    func loadOriginalBackups() async {
        do { originalBackups = try await io.backups() } catch { sourceError = error.localizedDescription }
    }
    func editOriginal(source: KnowledgeSourceDocument, replacement: String, action: String) async -> Bool {
        guard !isSaving, source.relativePath == "MEMORY.md", source.fileURL.standardizedFileURL == sourceRoot.appendingPathComponent("MEMORY.md").standardizedFileURL else { return false }
        let root = sourceRoot
        isSaving = true; sourceError = nil
        defer { isSaving = false }
        do {
            _ = try await io.editOriginal(root: root, original: source.text, replacement: replacement, action: action)
            status = "已修改 Codex 的 MEMORY.md，操作前后原文已备份。"
            await readSources(); await loadOriginalBackups(); return true
        } catch { sourceError = error.localizedDescription; return false }
    }
    func removeOriginalBackup(_ backup: CodexMemoryBackup) async {
        guard !isSaving else { return }
        isSaving = true; sourceError = nil
        defer { isSaving = false }
        do { try await io.removeBackup(backup); await loadOriginalBackups() }
        catch { sourceError = error.localizedDescription }
    }
    func restoreOriginal(_ backup: CodexMemoryBackup) async -> Bool {
        guard !isSaving else { return false }
        let root = sourceRoot
        isSaving = true; sourceError = nil
        defer { isSaving = false }
        do {
            try await io.restoreOriginal(backup, root: root)
            status = "已恢复 MEMORY.md，同时备份了恢复前的文件。"
            await readSources(); await loadOriginalBackups(); return true
        } catch { sourceError = error.localizedDescription; return false }
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
    func trash(_ entry: KnowledgeEntry, restore: Bool = false, permanently: Bool = false) async {
        guard !isSaving, hasLoaded, loadError == nil else { return }
        isSaving = true; operationError = nil
        defer { isSaving = false }
        do {
            if permanently { apply(try await io.delete(entry)) }
            else { apply(try await io.trash(entry, trashed: !restore)) }
            status = permanently ? "已永久删除该记忆及全部版本。" : (restore ? "已恢复记忆，保留删除前的状态。" : "已移入回收站，可恢复。")
        } catch { operationError = error.localizedDescription }
    }
    func changeState(_ entry: KnowledgeEntry, to state: KnowledgeState) async {
        var draft = entry.current; draft.state = state
        _ = await save(.init(draft: draft, expected: entry, reason: state.title))
    }
    func beginMerge(_ entries: [KnowledgeEntry]) {
        guard entries.count == 2, entries[0].current.scopeIdentity == entries[1].current.scopeIdentity,
              entries.allSatisfy({ $0.deletedAt == nil && $0.current.state != .archived }) else {
            operationError = "请选择同一范围、同一项目或会话的两条非归档记忆，再审核合并正文。"; return
        }
        let target = entries[0], source = entries[1]
        var draft = target.current
        draft.body = target.current.body + "\n\n" + source.current.body
        editor = .init(draft: draft, expected: target, mergeSource: source, reason: "合并记忆")
    }
    private func apply(_ snapshot: KnowledgeSnapshot) {
        guard snapshot.sequence > appliedSequence else { return }
        appliedSequence = snapshot.sequence; catalog = snapshot.catalog; indexedEntries = snapshot.entries; snapshotVersion += 1; filter()
    }
    private func filter() {
        filterTask?.cancel(); filterOperation?.cancel()
        let generation = UUID(); filterGeneration = generation
        let entries = indexedEntries, sources = indexedSources
        let terms = query.split(whereSeparator: \.isWhitespace).map { KnowledgeSearchText.fold(String($0)) }
        let project = projectFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectTerm = KnowledgeSearchText.fold(project)
        let origin = originFilter, state = stateFilter, archived = includeArchived, trash = showTrash
        let matchesMetadata: @Sendable (KnowledgeEntry) -> Bool = { entry in
            let value = entry.current
            return (entry.deletedAt != nil) == trash && (trash || archived || state == .archived || value.state != .archived)
                && (state == nil || value.state == state)
                && (origin == nil || (origin == .manual ? value.sources.isEmpty || value.sources.contains { $0.origin == .manual } : value.sources.contains { $0.origin == origin }))
                && (project.isEmpty || value.projectPath.localizedCaseInsensitiveContains(project))
        }
        // Metadata-only changes are bounded by the 200-entry catalog and need no
        // task, debounce, scan, or body copy. Clearing search updates immediately.
        if terms.isEmpty && project.isEmpty {
            publish(entries.compactMap { matchesMetadata($0.entry) ? $0.entry : nil }, sources.map(\.source))
            filterTask = nil; filterOperation = nil; isFiltering = false; return
        }
        if !isFiltering { isFiltering = true }
        let operation = Task.detached(priority: .userInitiated) { () -> ([KnowledgeEntry], [KnowledgeSourceDocument])? in
            var matchingEntries: [KnowledgeEntry] = [], matchingSources: [KnowledgeSourceDocument] = []
            for value in entries {
                if Task.isCancelled { return nil }
                if matchesMetadata(value.entry) && value.text.matches(terms) { matchingEntries.append(value.entry) }
            }
            for value in sources {
                if Task.isCancelled { return nil }
                guard project.isEmpty || value.text.contains(projectTerm) else { continue }
                var matches = true
                for term in terms {
                    if Task.isCancelled { return nil }
                    if !value.path.contains(term) && !value.text.contains(term) { matches = false; break }
                }
                if matches { matchingSources.append(value.source) }
            }
            return (matchingEntries, matchingSources)
        }
        filterOperation = operation
        filterTask = Task { [weak self] in
            let result = await operation.value
            guard !Task.isCancelled, let result, let self, self.filterGeneration == generation else { return }
            self.publish(result.0, result.1); self.isFiltering = false
            self.filterTask = nil; self.filterOperation = nil
        }
    }
    private func publish(_ entries: [KnowledgeEntry], _ sources: [KnowledgeSourceDocument]) {
        // Snapshot objects already hold the current content. Within one snapshot,
        // equal IDs mean equal content and avoid unnecessary SwiftUI list updates.
        let changed = publishedSnapshotVersion != snapshotVersion
        if changed || filteredEntries.map(\.id) != entries.map(\.id) { filteredEntries = entries }
        if changed || filteredSources.map(\.id) != sources.map(\.id) { filteredSources = sources }
        publishedSnapshotVersion = snapshotVersion
    }
}
