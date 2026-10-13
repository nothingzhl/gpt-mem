import Foundation
import CryptoKit

/// The coordinator is independent of memory, disk, network, or other domain modules.
public actor AIAnalysisCoordinator {
    private let client: any AIProviderClient
    private let credentials: any AICredentialStore
    private var cache: [String: AIAnalysisRecord] = [:]
    private var cacheOrder: [String] = []

    public init(client: any AIProviderClient = HTTPAIProviderClient(), credentials: any AICredentialStore = KeychainAICredentialStore()) {
        self.client = client; self.credentials = credentials
    }

    public func analyze(module: any AIAnalysisModule, configuration: AIProviderConfiguration) async throws -> AIAnalysisRecord {
        try Task.checkCancellation()
        _ = try configuration.validated()
        let input = try module.makeInput()
        let payload = try input.validated()
        let key = try credentials.key(for: configuration.id)
        return try await perform(input: input, payload: payload, configuration: configuration, apiKey: key)
    }

    /// Callers with a confirmation flow can bind the approved destination and its
    /// credential snapshot before launching an asynchronous task.
    public func analyze(module: any AIAnalysisModule, configuration: AIProviderConfiguration, apiKey: String?) async throws -> AIAnalysisRecord {
        try Task.checkCancellation()
        _ = try configuration.validated()
        let input = try module.makeInput()
        let payload = try input.validated()
        return try await perform(input: input, payload: payload, configuration: configuration, apiKey: apiKey)
    }

    private func perform(input: AIAnalysisInput, payload: Data, configuration: AIProviderConfiguration, apiKey: String?) async throws -> AIAnalysisRecord {
        try Task.checkCancellation()
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if configuration.requiresAPIKey, key.isEmpty { throw AIAnalysisError.missingCredential }
        guard !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw AIAnalysisError.invalidConfiguration("API Key 不能包含控制字符。")
        }
        var fingerprintData = Data("analysis-contract-v1\n".utf8)
        fingerprintData.append(try AIAnalysisCodec.encoder().encode(configuration))
        fingerprintData.append(payload)
        // API dates stay readable, while cache identity retains full timestamp
        // precision and changes when the key changes even outside the settings UI.
        fingerprintData.append(try JSONEncoder().encode([input.windowStart.timeIntervalSince1970, input.windowEnd.timeIntervalSince1970]))
        fingerprintData.append(Data(SHA256.hash(data: Data(key.utf8))))
        let fingerprint = SHA256.hash(data: fingerprintData).map { String(format: "%02x", $0) }.joined()
        if var cached = cache[fingerprint] {
            cached.wasCached = true
            return cached
        }
        let result: AIAnalysisResult
        do {
            result = try await client.analyze(input: input, configuration: configuration, apiKey: key)
            try Task.checkCancellation()
        } catch is CancellationError { throw AIAnalysisError.cancelled }
        try result.validate(against: input)
        let record = AIAnalysisRecord(moduleID: input.moduleID, moduleTitle: input.moduleTitle, providerID: configuration.id,
                                      providerName: configuration.name, model: configuration.model, inputFingerprint: fingerprint,
                                      windowStart: input.windowStart, windowEnd: input.windowEnd, result: result)
        cache[fingerprint] = record
        cacheOrder.removeAll { $0 == fingerprint }
        cacheOrder.append(fingerprint)
        while cacheOrder.count > 16 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        return record
    }

    public func clearCache() { cache.removeAll(); cacheOrder.removeAll() }
}
