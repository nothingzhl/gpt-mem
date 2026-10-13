import Foundation
import Combine
import GPTAnalysisKit

struct AIAnalysisPreview: Identifiable {
    let id = UUID()
    let input: AIAnalysisInput
    let configuration: AIProviderConfiguration
    let subjectLabels: [String: String]
    let windowSelectionSeconds: TimeInterval
    let json: String
}

private struct FrozenAIAnalysisModule: AIAnalysisModule {
    let input: AIAnalysisInput
    func makeInput() throws -> AIAnalysisInput { input }
}

/// Shared desktop state for provider settings and manual analysis of any module.
@MainActor
final class DesktopAIModel: ObservableObject {
    @Published private(set) var settings = AISettings()
    @Published private(set) var configurationError: String?
    @Published private(set) var operationError: String?
    @Published private(set) var analysisError: String?
    @Published private(set) var outputLimitFailureConfiguration: AIProviderConfiguration?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var record: AIAnalysisRecord?
    @Published private(set) var recordInput: AIAnalysisInput?
    @Published private(set) var recordSubjectLabels: [String: String] = [:]
    @Published private(set) var statusMessage: String?
    @Published var preview: AIAnalysisPreview?
    @Published var activityContext = ""
    @Published private(set) var currentWindowStart: Date?
    @Published private(set) var currentWindowEnd: Date?
    @Published private(set) var currentWindowSelectionSeconds: TimeInterval = 1800

    private let configurationStore: AIConfigurationStore
    private let credentials: AICredentialStore
    private let coordinator: AIAnalysisCoordinator
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var recordWindowSelectionSeconds: TimeInterval?
    private var recordConfiguration: AIProviderConfiguration?

    init(configurationStore: AIConfigurationStore,
         credentials: AICredentialStore = KeychainAICredentialStore(),
         coordinator: AIAnalysisCoordinator? = nil) {
        self.configurationStore = configurationStore
        self.credentials = credentials
        self.coordinator = coordinator ?? AIAnalysisCoordinator(credentials: credentials)
        reloadSettings()
    }

    var selectedProvider: AIProviderConfiguration? {
        settings.providers.first { $0.id == settings.selectedProviderID }
    }

    var suggestedOutputLimitAfterFailure: Int? {
        guard !isAnalyzing, configurationError == nil,
              let failed = outputLimitFailureConfiguration, selectedProvider == failed,
              failed.maxOutputTokens < 16_384 else { return nil }
        return min(16_384, max(8_192, failed.maxOutputTokens * 2))
    }

    /// Recovery changes the same source's budget only; the caller then opens a new preview.
    @discardableResult
    func increaseOutputLimitAfterFailure() -> Bool {
        guard !isAnalyzing, let failed = outputLimitFailureConfiguration else { return false }
        reloadSettings()
        guard configurationError == nil, selectedProvider == failed,
              failed.maxOutputTokens < 16_384 else {
            operationError = "AI 来源已变化或无法读取，请重新预览分析摘要；本次未修改输出上限。"
            return false
        }
        var updated = failed
        updated.maxOutputTokens = min(16_384, max(8_192, failed.maxOutputTokens * 2))
        // No destination or credential changes: an empty key preserves the existing key.
        guard saveProvider(updated, key: "", clearKey: false) else { return false }
        outputLimitFailureConfiguration = nil
        return true
    }

    /// Upgrade a low-budget preview while retaining the exact frozen facts and local mapping.
    @discardableResult
    func increaseOutputLimitForPreview(_ prepared: AIAnalysisPreview) -> Bool {
        guard !isAnalyzing else { return false }
        reloadSettings()
        guard configurationError == nil, preview?.id == prepared.id,
              selectedProvider == prepared.configuration,
              settings.providers.first(where: { $0.id == prepared.configuration.id }) == prepared.configuration,
              prepared.configuration.maxOutputTokens < 8_192 else {
            operationError = "AI 预览或来源已变化，请重新预览分析摘要；本次未修改输出上限。"
            return false
        }
        var updated = prepared.configuration
        updated.maxOutputTokens = 8_192
        guard saveProvider(updated, key: "", clearKey: false) else { return false }
        guard let saved = settings.providers.first(where: { $0.id == updated.id }) else { return false }
        preview = AIAnalysisPreview(input: prepared.input, configuration: saved,
                                    subjectLabels: prepared.subjectLabels,
                                    windowSelectionSeconds: prepared.windowSelectionSeconds, json: prepared.json)
        outputLimitFailureConfiguration = nil
        statusMessage = "输出上限已提高到 8192 Token；摘要保持不变，请重新确认发送。"
        return true
    }

    var resultIsStale: Bool {
        guard let record else { return false }
        return record.windowStart != currentWindowStart || record.windowEnd != currentWindowEnd
            || recordWindowSelectionSeconds != currentWindowSelectionSeconds
            || selectedProvider != recordConfiguration
            || recordInput?.context != activityContext
    }

    func reloadSettings() {
        do {
            let loaded = try configurationStore.load()
            settings = loaded
            configurationError = nil
        } catch {
            configurationError = "AI 配置无法读取：\(error.localizedDescription)。请先修复配置文件，再点击重新读取；当前禁止覆盖保存。"
        }
    }

    func updateWindow(start: Date?, end: Date?, selectionSeconds: TimeInterval) {
        currentWindowStart = start
        currentWindowEnd = end
        currentWindowSelectionSeconds = selectionSeconds
    }

    @discardableResult
    func selectProvider(_ id: UUID?) -> Bool {
        guard configurationError == nil else { return false }
        guard refreshSettingsForMutation() else { return false }
        guard id == nil || settings.providers.contains(where: { $0.id == id }) else { return false }
        var updated = settings
        updated.selectedProviderID = id
        return persistSettings(updated)
    }

    /// Resolve credentials only after the user explicitly asks to fetch models.
    /// Unsaved edits must not reuse a saved key against a different destination.
    func modelDiscoveryKey(configuration: AIProviderConfiguration, draftKey: String, clearKey: Bool) throws -> String? {
        if clearKey { return nil }
        let value = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        // A saved secret must be resolved against current persisted metadata,
        // including when a source was edited outside this open draft.
        reloadSettings()
        guard configurationError == nil else {
            throw AIAnalysisError.invalidConfiguration("AI 配置无法读取，请先重新读取来源设置；也可以填写这个来源的 API Key。")
        }
        guard let saved = settings.providers.first(where: { $0.id == configuration.id }) else { return nil }
        guard sameDestination(saved, configuration) else {
            if configuration.requiresAPIKey {
                throw AIAnalysisError.invalidConfiguration("服务地址或协议已改变，请填写这个来源的 API Key 后拉取模型。")
            }
            return nil
        }
        return try credentials.key(for: saved.id)
    }

    private func sameDestination(_ first: AIProviderConfiguration, _ second: AIProviderConfiguration) -> Bool {
        func normalized(_ address: String) -> String {
            address.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return first.kind == second.kind && normalized(first.baseURL) == normalized(second.baseURL)
    }

    /// Empty key means keep the existing secret. Clearing is a separate choice.
    @discardableResult
    func saveProvider(_ draft: AIProviderConfiguration, key: String, clearKey: Bool,
                      expectedProvider: AIProviderConfiguration? = nil) -> Bool {
        guard configurationError == nil else { return false }
        operationError = nil
        let original = expectedProvider ?? settings.providers.first { $0.id == draft.id }
        guard refreshSettingsForMutation() else { return false }
        guard settings.providers.first(where: { $0.id == draft.id }) == original else {
            operationError = "这个 AI 来源在编辑期间已变化。请关闭编辑页后重新打开；本次未覆盖配置或密钥。"
            return false
        }
        var provider = draft
        provider.name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try provider.validated()
            let previous = settings.providers.first { $0.id == provider.id }
            if let previous, !sameDestination(previous, provider), !clearKey,
               key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               try credentials.key(for: provider.id) != nil {
                throw AIAnalysisError.invalidConfiguration("服务地址或协议已改变，请填写新来源的 API Key；不需要密钥时，可在高级设置中清除已保存的密钥。")
            }
            provider.revision = (previous?.revision ?? 0) + 1
            var updated = settings
            if let index = updated.providers.firstIndex(where: { $0.id == provider.id }) {
                updated.providers[index] = provider
            } else {
                updated.providers.append(provider)
                if updated.selectedProviderID == nil { updated.selectedProviderID = provider.id }
            }
            try updated.validate()
            let changedKey = clearKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let previousKey = changedKey ? try credentials.key(for: provider.id) : nil
            if changedKey {
                if clearKey { try credentials.deleteKey(for: provider.id) }
                else { try credentials.setKey(key.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.id) }
            }
            do {
                try configurationStore.save(updated)
            } catch {
                if changedKey {
                    do {
                        if let previousKey { try credentials.setKey(previousKey, for: provider.id) }
                        else { try credentials.deleteKey(for: provider.id) }
                    } catch {
                        operationError = "配置保存失败，密钥还原也失败。请重新编辑这个来源并检查钥匙串。"
                        return false
                    }
                }
                throw error
            }
            settings = updated
            if preview?.configuration.id == provider.id { preview = nil }
            statusMessage = "来源已保存；模型列表与分析请求均需手动发起。"
            return true
        } catch {
            operationError = "保存来源失败：\(error.localizedDescription)"
            return false
        }
    }

    func removeProvider(_ id: UUID, expectedProvider: AIProviderConfiguration? = nil) {
        guard configurationError == nil else { return }
        let original = expectedProvider ?? settings.providers.first { $0.id == id }
        guard refreshSettingsForMutation() else { return }
        guard let original, settings.providers.first(where: { $0.id == id }) == original else {
            operationError = "这个 AI 来源已变化或被移除，请重新检查后操作；本次未删除配置或密钥。"
            return
        }
        var updated = settings
        updated.providers.removeAll { $0.id == id }
        if updated.selectedProviderID == id { updated.selectedProviderID = updated.providers.first?.id }
        guard persistSettings(updated) else { return }
        if preview?.configuration.id == id { preview = nil }
        do { try credentials.deleteKey(for: id) }
        catch { operationError = "来源已移除，但钥匙串中的密钥未能删除：\(error.localizedDescription)" }
    }

    func prepare(module: any AIAnalysisModule, subjectLabels: [String: String] = [:],
                 windowSelectionSeconds: TimeInterval) {
        guard !isAnalyzing else { return }
        analysisError = nil
        guard configurationError == nil, let provider = selectedProvider else {
            analysisError = "请先在设置中添加并选择 AI 来源。"
            return
        }
        do {
            _ = try provider.validated()
            let input = try module.makeInput()
            _ = try input.validated()
            let data = try AIAnalysisCodec.encoder(pretty: true).encode(input)
            guard let json = String(data: data, encoding: .utf8) else { return }
            preview = AIAnalysisPreview(input: input, configuration: provider, subjectLabels: subjectLabels,
                                        windowSelectionSeconds: windowSelectionSeconds, json: json)
        } catch {
            analysisError = "无法准备分析摘要：\(error.localizedDescription)"
        }
    }

    func beginAnalysis(_ prepared: AIAnalysisPreview) {
        guard !isAnalyzing else { return }
        // Recheck persisted metadata before binding a credential to the approved destination.
        reloadSettings()
        guard configurationError == nil,
              settings.providers.first(where: { $0.id == prepared.configuration.id }) == prepared.configuration else {
            preview = nil
            analysisError = "AI 来源配置已变化或无法读取。请重新预览摘要后再发送，本次没有发送请求。"
            return
        }
        let apiKey: String?
        do {
            apiKey = try credentials.key(for: prepared.configuration.id)
            if prepared.configuration.requiresAPIKey,
               apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw AIAnalysisError.missingCredential
            }
        } catch {
            preview = nil
            analysisError = "无法开始 AI 分析：\(error.localizedDescription)。本次没有发送请求。"
            return
        }
        // The user approves a frozen input and configuration, even if new samples arrive.
        preview = nil
        analysisError = nil
        outputLimitFailureConfiguration = nil
        statusMessage = nil
        isAnalyzing = true
        let id = UUID()
        requestID = id
        let module = FrozenAIAnalysisModule(input: prepared.input)
        task = Task { [weak self, coordinator, apiKey] in
            do {
                let output = try await coordinator.analyze(module: module, configuration: prepared.configuration, apiKey: apiKey)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.record = output
                self.recordInput = prepared.input
                self.recordSubjectLabels = prepared.subjectLabels
                self.recordConfiguration = prepared.configuration
                self.recordWindowSelectionSeconds = prepared.windowSelectionSeconds
                self.statusMessage = output.wasCached ? "已读取相同摘要的本机缓存。" : "分析完成。"
                self.finishRequest(id)
            } catch {
                guard let self, self.requestID == id else { return }
                if let typed = error as? AIAnalysisError, case .generationLengthLimit = typed {
                    self.outputLimitFailureConfiguration = prepared.configuration
                }
                self.analysisError = error is CancellationError ? nil : "AI 分析失败：\(error.localizedDescription)。已有本地分析和上次 AI 结果仍然保留。"
                self.finishRequest(id)
            }
        }
    }

    func cancelAnalysis() {
        task?.cancel()
        requestID = nil
        task = nil
        isAnalyzing = false
        statusMessage = "本次分析已取消；已发出的请求可能已由来源处理。"
    }

    func clearStatus() {
        operationError = nil; analysisError = nil; statusMessage = nil
        outputLimitFailureConfiguration = nil
    }

    private func finishRequest(_ id: UUID) {
        guard requestID == id else { return }
        isAnalyzing = false
        task = nil
        requestID = nil
    }

    private func persistSettings(_ updated: AISettings) -> Bool {
        do {
            try configurationStore.save(updated)
            settings = updated
            operationError = nil
            return true
        } catch {
            operationError = "保存 AI 配置失败：\(error.localizedDescription)"
            return false
        }
    }

    private func refreshSettingsForMutation() -> Bool {
        reloadSettings()
        guard configurationError == nil else {
            operationError = "AI 配置无法读取，本次未保存。请修复后点击重新读取。"
            return false
        }
        return true
    }
}
