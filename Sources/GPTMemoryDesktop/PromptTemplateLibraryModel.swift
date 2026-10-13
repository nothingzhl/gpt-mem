import Foundation
import Combine
import GPTAnalysisKit

private struct PromptTemplateSnapshot {
    let catalog: AIPromptCatalog
    let sequence: UInt64
}

private actor PromptTemplateIO {
    private var sequence: UInt64 = 0
    let store: AIPromptTemplateStore
    init(store: AIPromptTemplateStore) { self.store = store }
    private func wrap(_ catalog: AIPromptCatalog) -> PromptTemplateSnapshot { sequence += 1; return .init(catalog: catalog, sequence: sequence) }
    func load() throws -> PromptTemplateSnapshot { wrap(try store.load()) }
    func save(_ draft: AIPromptTemplate, expected: AIPromptTemplate?) throws -> PromptTemplateSnapshot { wrap(try store.save(draft, expected: expected)) }
    func setDefault(_ id: String?, module: String) throws -> PromptTemplateSnapshot { wrap(try store.setDefault(id, for: module)) }
}

@MainActor
final class PromptTemplateLibraryModel: ObservableObject {
    @Published private(set) var catalog = AIPromptCatalog()
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var operationError: String?
    private let io: PromptTemplateIO
    private var loading: Task<Void, Never>?
    private var appliedSequence: UInt64 = 0
    init(store: AIPromptTemplateStore) { io = PromptTemplateIO(store: store) }

    func loadIfNeeded() async {
        if let loading { await loading.value; return }
        guard !hasLoaded else { return }
        await refresh()
    }
    func refresh() async {
        if let loading { await loading.value; return }
        isLoading = true
        let operation = Task { [weak self, io] in
            do {
                let snapshot = try await io.load()
                guard let self else { return }
                self.apply(snapshot)
                self.loadError = nil
            } catch { self?.loadError = error.localizedDescription }
            self?.hasLoaded = true
            self?.isLoading = false
        }
        loading = operation
        await operation.value
        loading = nil
    }
    func save(_ draft: AIPromptTemplate, expected: AIPromptTemplate?) async -> Bool {
        guard !isSaving, loadError == nil else { return false }
        isSaving = true; operationError = nil
        defer { isSaving = false }
        do { apply(try await io.save(draft, expected: expected)); return true }
        catch { operationError = error.localizedDescription; return false }
    }
    func setDefault(_ id: String?, module: String) async -> Bool {
        guard !isSaving, loadError == nil else { return false }
        isSaving = true; operationError = nil
        defer { isSaving = false }
        do { apply(try await io.setDefault(id, module: module)); return true }
        catch { operationError = error.localizedDescription; return false }
    }
    private func apply(_ snapshot: PromptTemplateSnapshot) {
        guard snapshot.sequence >= appliedSequence else { return }
        appliedSequence = snapshot.sequence
        catalog = snapshot.catalog
        hasLoaded = true
    }
}
