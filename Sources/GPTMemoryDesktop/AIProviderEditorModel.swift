import Foundation
import Combine
import GPTAnalysisKit

/// An isolated editing draft. Looking up models never saves settings or credentials.
@MainActor
final class AIProviderEditorModel: ObservableObject {
    @Published var configuration: AIProviderConfiguration {
        didSet {
            guard !isApplyingPreset else { return }
            let changedDestination = configuration.kind != oldValue.kind
                || normalizedAddress(configuration.baseURL) != normalizedAddress(oldValue.baseURL)
            if configuration.kind != oldValue.kind || configuration.baseURL != oldValue.baseURL {
                selectedPreset = AIProviderPreset.matching(configuration)
            }
            if changedDestination {
                // Editing an endpoint is another way to change services. A key
                // typed for the previous destination must not follow that edit.
                key = ""
            }
            if configuration.kind != oldValue.kind || configuration.baseURL != oldValue.baseURL
                || configuration.timeoutSeconds != oldValue.timeoutSeconds {
                invalidateCatalog()
            }
        }
    }
    @Published var key = "" {
        didSet { if key != oldValue && !isApplyingPreset { invalidateCatalog() } }
    }
    @Published var clearKey = false {
        didSet { if clearKey != oldValue && !isApplyingPreset { invalidateCatalog() } }
    }
    @Published private(set) var selectedPreset: AIProviderPreset
    @Published private(set) var models: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var modelError: String?
    @Published private(set) var statusMessage: String?

    private let catalog: any AIModelCatalogClient
    private let credentialResolver: (AIProviderConfiguration, String, Bool) throws -> String?
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var isApplyingPreset = false

    init(configuration: AIProviderConfiguration,
         catalog: any AIModelCatalogClient = HTTPAIModelCatalogClient(),
         credentialResolver: @escaping (AIProviderConfiguration, String, Bool) throws -> String?) {
        self.configuration = configuration
        selectedPreset = AIProviderPreset.matching(configuration)
        self.catalog = catalog
        self.credentialResolver = credentialResolver
    }

    deinit { task?.cancel() }

    func selectPreset(_ preset: AIProviderPreset) {
        guard preset != selectedPreset else { return }
        invalidateCatalog()
        let defaults = preset.makeConfiguration(id: configuration.id)
        var updated = configuration
        updated.name = defaults.name
        updated.kind = defaults.kind
        updated.baseURL = defaults.baseURL
        updated.model = defaults.model
        isApplyingPreset = true
        configuration = updated
        selectedPreset = preset
        // A secret typed for one service must never follow a preset to another service.
        key = ""
        clearKey = false
        isApplyingPreset = false
    }

    func fetchModels() {
        invalidateCatalog()
        let frozenConfiguration = configuration
        let apiKey: String?
        do {
            apiKey = try credentialResolver(frozenConfiguration, key, clearKey)
        } catch {
            modelError = safeErrorMessage(error)
            return
        }
        let id = UUID()
        let startedWithEmptyModel = frozenConfiguration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        requestID = id
        isLoading = true
        task = Task { [weak self, catalog, apiKey] in
            do {
                try Task.checkCancellation()
                let available = try await catalog.models(configuration: frozenConfiguration, apiKey: apiKey)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.models = available
                if available.count == 1, startedWithEmptyModel,
                   self.configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.configuration.model = available[0]
                }
                self.statusMessage = available.isEmpty
                    ? "未发现可用模型，可以手动填写模型 ID。"
                    : "已获取 \(available.count) 个模型；也可以手动填写模型 ID。"
                self.finishRequest(id)
            } catch {
                guard let self, self.requestID == id else { return }
                if error is CancellationError || self.isCancelled(error) {
                    self.modelError = nil
                } else {
                    self.modelError = self.safeErrorMessage(error)
                }
                self.finishRequest(id)
            }
        }
    }

    func cancelFetch() {
        guard isLoading else { return }
        invalidateCatalog()
        statusMessage = "获取模型已取消。"
    }

    private func invalidateCatalog() {
        task?.cancel()
        requestID = nil
        task = nil
        isLoading = false
        models = []
        modelError = nil
        statusMessage = nil
    }

    private func finishRequest(_ id: UUID) {
        guard requestID == id else { return }
        requestID = nil
        task = nil
        isLoading = false
    }

    private func safeErrorMessage(_ error: Error) -> String {
        // Only the catalog's typed errors are designed for display. Arbitrary
        // resolver/network errors can contain credentials or response bodies.
        if let safe = error as? AIAnalysisError { return "获取模型失败：\(safe.localizedDescription)" }
        return "获取模型失败，请检查来源地址和密钥后重试；也可以手动填写模型 ID。"
    }

    private func isCancelled(_ error: Error) -> Bool {
        if let typed = error as? AIAnalysisError, case .cancelled = typed { return true }
        return false
    }

    private func normalizedAddress(_ value: String) -> String {
        var address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while address.hasSuffix("/") { address.removeLast() }
        return address
    }
}
