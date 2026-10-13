import Foundation
import Combine
import GPTSessionKit

/// Small metadata lookup shared by the UI and detached search. Original log
/// summaries remain unchanged, including their title and prompt search index.
struct SessionManagementIndex: Sendable {
    let sessions: [String: SessionManagementEntry]
    let projects: [String: SessionManagementEntry]
    private let projectTagKeys: [String: Set<String>]
    let favoriteProjects: Set<String>

    init(snapshot: SessionManagementSnapshot = .init()) {
        var sessions: [String: SessionManagementEntry] = [:]
        var projects: [String: SessionManagementEntry] = [:]
        var tagKeys: [String: Set<String>] = [:]
        var favorites: Set<String> = []
        for entry in snapshot.entries {
            switch entry.kind {
            case .session: sessions[entry.itemID] = entry
            case .project:
                projects[entry.itemID] = entry
                tagKeys[entry.itemID] = Set(entry.tags.map(SessionManagementStore.tagKey))
                if entry.isFavorite { favorites.insert(entry.itemID) }
            }
        }
        self.sessions = sessions
        self.projects = projects
        projectTagKeys = tagKeys
        favoriteProjects = favorites
    }

    func entry(for summary: CodexSessionSummary) -> SessionManagementEntry? { sessions[summary.managementID] }
    func isFavorite(_ summary: CodexSessionSummary) -> Bool { entry(for: summary)?.isFavorite ?? false }
    func isFavoriteProject(_ path: String) -> Bool { favoriteProjects.contains(Self.projectID(path)) }
    func entryForProject(_ path: String) -> SessionManagementEntry? { projects[Self.projectID(path)] }
    func hasProjectTag(_ path: String, key: String) -> Bool { projectTagKeys[Self.projectID(path)]?.contains(key) ?? false }
    func tagSearchKeys(_ path: String) -> Set<String> { projectTagKeys[Self.projectID(path)] ?? [] }

    static func projectPath(for summary: CodexSessionSummary) -> String {
        summary.projectPath.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? SessionProjectSummary.unknownID
    }

    static func projectID(_ path: String) -> String {
        path == SessionProjectSummary.unknownID ? "group:unknown-project" : path
    }
}

private enum SessionManagementPurpose: Sendable { case automatic, details, tags }

private struct SessionManagementOperation: Sendable {
    let kind: SessionManagementKind
    let itemID: String
    let change: SessionManagementChange
    let expectedEntry: SessionManagementEntry?
    let purpose: SessionManagementPurpose

    var editsDetails: Bool {
        if case .details = purpose { return true }
        if case .tags = purpose { return false }
        switch change {
        case .setDisplayName, .setNote, .setDetails: return true
        case .update(let favorite, _, _, let tags): return favorite == nil && tags == nil
        default: return false
        }
    }

    var editsTags: Bool {
        if case .tags = purpose { return true }
        if case .details = purpose { return false }
        switch change {
        case .setTags: return true
        case .update(let favorite, let name, let note, let tags):
            guard favorite == nil, tags != nil else { return false }
            if case .unchanged = name, case .unchanged = note { return true }
            return false
        default: return false
        }
    }

    init(kind: SessionManagementKind, itemID: String, change: SessionManagementChange,
         expectedEntry: SessionManagementEntry? = nil, purpose: SessionManagementPurpose = .automatic) {
        self.kind = kind
        self.itemID = itemID
        self.change = change
        self.expectedEntry = expectedEntry
        self.purpose = purpose
    }
}

private struct SessionManagementLoad: Sendable {
    let serial: UInt64
    let index: SessionManagementIndex
}

/// All disk work is synchronous inside this actor. Loads and patches therefore
/// serialize in their actual execution order without occupying the main actor.
private actor SessionManagementIO {
    let directoryURL: URL?
    let sourceRootURL: URL
    private var store: SessionManagementStore?
    private var memory = SessionManagementSnapshot()
    private var serial: UInt64 = 0

    init(directoryURL: URL?, sourceRootURL: URL) {
        self.directoryURL = directoryURL
        self.sourceRootURL = sourceRootURL
    }

    private func diskStore() throws -> SessionManagementStore? {
        guard let directoryURL else { return nil }
        if let store { return store }
        let result = try SessionManagementStore(directoryURL: directoryURL, sourceRootURL: sourceRootURL)
        store = result
        return result
    }

    private func result(_ snapshot: SessionManagementSnapshot) -> SessionManagementLoad {
        serial &+= 1
        return SessionManagementLoad(serial: serial, index: SessionManagementIndex(snapshot: snapshot))
    }

    func load() throws -> SessionManagementLoad {
        let snapshot = try diskStore()?.load() ?? memory
        return result(snapshot)
    }

    func patch(_ operation: SessionManagementOperation) throws -> SessionManagementLoad {
        if let store = try diskStore() {
            return result(try store.patch(kind: operation.kind, itemID: operation.itemID, change: operation.change,
                                          expectedEntry: operation.expectedEntry))
        }
        // Nil storage is an isolated in-memory backend for previews/fixtures.
        // Shipping DesktopModel always supplies its private data directory.
        var entries = memory.entries
        let existing = entries.first { $0.kind == operation.kind && $0.itemID == operation.itemID }
        let changed = try SessionManagementStore.applying(change: operation.change,
            to: existing ?? .init(kind: operation.kind, itemID: operation.itemID), expectedEntry: operation.expectedEntry)
        entries.removeAll { $0.kind == operation.kind && $0.itemID == operation.itemID }
        if changed.isFavorite || changed.displayName != nil || changed.note != nil || !changed.tags.isEmpty {
            entries.append(changed)
        }
        memory = .init(revision: memory.revision &+ 1, entries: entries)
        return result(memory)
    }

}

@MainActor
final class SessionManagementModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasPendingRetry = false
    @Published private(set) var index = SessionManagementIndex()

    /// Invoked after publishing committed values. Parent search receives the new
    /// immutable index, rather than Combine's pre-change objectWillChange state.
    var didChange: (() -> Void)?
    private let io: SessionManagementIO
    private var appliedSerial: UInt64 = 0
    private var loadGeneration = UUID()
    private var loadTask: Task<Bool, Never>?
    private var mutationTask: Task<Bool, Never>?
    private var mutationGeneration = UUID()
    private var pendingCount = 0
    private var failedOperation: SessionManagementOperation?
    private var lastSaveError: String?
    private var directDetailsError: (itemID: String, message: String)?
    private var directTagsError: (itemID: String, message: String)?

    init(directoryURL: URL?, sourceRootURL: URL) {
        io = SessionManagementIO(directoryURL: directoryURL, sourceRootURL: sourceRootURL)
    }

    func loadIfNeeded() {
        guard !hasLoaded, !isLoading else { return }
        refresh()
    }

    func refresh() {
        loadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self, io] () -> Bool in
            do {
                let loaded = try await io.load()
                guard let self, self.loadGeneration == generation, !Task.isCancelled else { return false }
                self.loadTask = nil
                self.isLoading = false
                self.hasLoaded = true
                self.apply(loaded)
                if self.failedOperation != nil { self.errorMessage = self.lastSaveError }
                return true
            } catch {
                guard let self, self.loadGeneration == generation, !Task.isCancelled else { return false }
                self.loadTask = nil
                self.isLoading = false
                self.errorMessage = "读取收藏与备注失败：\(error.localizedDescription)"
                return false
            }
        }
    }

    /// Editors use this result to update a frozen baseline only after a real
    /// successful read, even if an earlier failed save still has a retry banner.
    func reload() async -> Bool {
        refresh()
        guard let task = loadTask else { return false }
        return await task.value
    }

    private func apply(_ loaded: SessionManagementLoad) {
        guard loaded.serial >= appliedSerial else { return }
        appliedSerial = loaded.serial
        index = loaded.index
        didChange?()
    }

    private func enqueue(_ operation: SessionManagementOperation) -> Task<Bool, Never>? {
        guard hasLoaded, !isLoading else {
            errorMessage = "收藏与备注尚未完成读取，请重新读取后再保存。"
            return nil
        }
        let previous = mutationTask
        let generation = UUID()
        mutationGeneration = generation
        pendingCount += 1
        isSaving = true
        errorMessage = nil
        directDetailsError = nil
        directTagsError = nil
        let task = Task { [weak self, io] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            let succeeded: Bool
            do {
                let loaded = try await io.patch(operation)
                self.apply(loaded)
                self.failedOperation = nil
                self.lastSaveError = nil
                self.hasPendingRetry = false
                self.errorMessage = nil
                succeeded = true
            } catch {
                self.failedOperation = operation
                self.hasPendingRetry = true
                self.lastSaveError = "保存收藏与备注失败：\(error.localizedDescription)"
                self.errorMessage = self.lastSaveError
                succeeded = false
            }
            self.pendingCount -= 1
            self.isSaving = self.pendingCount > 0
            if self.mutationGeneration == generation { self.mutationTask = nil }
            return succeeded
        }
        mutationTask = task
        return task
    }

    func setFavorite(kind: SessionManagementKind, itemID: String, value: Bool) {
        _ = enqueue(.init(kind: kind, itemID: itemID, change: .setFavorite(value)))
    }

    func saveDetails(itemID: String, title: String, note: String,
                     baseline: SessionManagementEntry? = nil) async -> Bool {
        let change: SessionManagementChange
        if let baseline {
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedNote = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : note
            let displayName: SessionManagementTextChange = normalizedTitle == (baseline.displayName ?? "") ? .unchanged : .set(title)
            let noteChange: SessionManagementTextChange = normalizedNote == (baseline.note ?? "") ? .unchanged : .set(note)
            change = .update(isFavorite: nil, displayName: displayName, note: noteChange)
        } else {
            change = .setDetails(displayName: title, note: note)
        }
        guard let task = enqueue(.init(kind: .session, itemID: itemID,
                                      change: change, expectedEntry: baseline, purpose: .details)) else { return false }
        return await task.value
    }

    func retryLastMutation() {
        guard !isSaving, let failedOperation else { return }
        _ = enqueue(failedOperation)
    }

    func saveProjectTags(itemID: String, tags: [String], baseline: SessionManagementEntry) async -> Bool {
        let tagsChange: [String]?
        do {
            let normalized = try SessionManagementStore.normalizedTags(tags)
            tagsChange = normalized == baseline.tags ? nil : normalized
        } catch {
            // Keep the validation failure in the same owned retry/discard path
            // as a disk failure, without touching any file before validation.
            guard let task = enqueue(.init(kind: .project, itemID: itemID,
                                          change: .setTags(tags), expectedEntry: baseline, purpose: .tags)) else { return false }
            return await task.value
        }
        guard let task = enqueue(.init(kind: .project, itemID: itemID,
            change: .update(isFavorite: nil, tags: tagsChange), expectedEntry: baseline, purpose: .tags)) else { return false }
        return await task.value
    }

    /// Discarding an editor draft is purely local. It must not leave that draft
    /// queued for the library's retry button after the editor has been cancelled.
    /// Favorites, other sessions and a later read failure keep their own state.
    func discardFailedDetails(itemID: String) {
        guard !isSaving else { return }
        if let failedOperation, failedOperation.kind == .session,
           failedOperation.itemID == itemID, failedOperation.editsDetails {
            let ownedError = lastSaveError
            self.failedOperation = nil
            lastSaveError = nil
            hasPendingRetry = false
            if errorMessage == ownedError { errorMessage = nil }
        }
        if let directDetailsError, directDetailsError.itemID == itemID {
            self.directDetailsError = nil
            if errorMessage == directDetailsError.message { errorMessage = lastSaveError }
        }
    }

    func discardFailedProjectTags(itemID: String) {
        guard !isSaving else { return }
        if let failedOperation, failedOperation.kind == .project,
           failedOperation.itemID == itemID, failedOperation.editsTags {
            let ownedError = lastSaveError
            self.failedOperation = nil
            lastSaveError = nil
            hasPendingRetry = false
            if errorMessage == ownedError { errorMessage = nil }
        }
        if let directTagsError, directTagsError.itemID == itemID {
            self.directTagsError = nil
            if errorMessage == directTagsError.message { errorMessage = lastSaveError }
        }
    }

    func dismissError() { errorMessage = nil }
    func reportError(_ message: String, detailsItemID: String? = nil) {
        if let detailsItemID { directDetailsError = (detailsItemID, message) }
        errorMessage = message
    }
    func reportProjectTagsError(_ message: String, itemID: String) {
        directTagsError = (itemID, message)
        errorMessage = message
    }

    func waitForPendingMutations() async {
        while let task = mutationTask { _ = await task.value }
    }
}
