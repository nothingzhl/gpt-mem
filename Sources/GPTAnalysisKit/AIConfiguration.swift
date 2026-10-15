import Foundation
import Security
import Darwin

public enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAIResponses, openAICompatible, ollama
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openAIResponses: return "OpenAI Responses"
        case .openAICompatible: return "OpenAI 兼容接口"
        case .ollama: return "Ollama"
        }
    }
    public var suggestedBaseURL: String {
        switch self {
        case .openAIResponses: return "https://api.openai.com/v1"
        case .openAICompatible: return "https://api.deepseek.com/v1"
        case .ollama: return "http://localhost:11434"
        }
    }
}

public struct AIProviderConfiguration: Codable, Equatable, Identifiable {
    public static let defaultMaxOutputTokens = 8_192
    public var id: UUID
    public var name: String
    public var kind: AIProviderKind
    public var baseURL: String
    public var model: String
    public var timeoutSeconds: Double
    public var maxOutputTokens: Int
    public var jsonMode: Bool
    public var revision: Int
    public var credentialReference: UUID?
    public var credentialStorageID: UUID { credentialReference ?? id }
    public init(id: UUID = UUID(), name: String, kind: AIProviderKind, baseURL: String, model: String,
                timeoutSeconds: Double = 60, maxOutputTokens: Int = AIProviderConfiguration.defaultMaxOutputTokens,
                jsonMode: Bool = true, revision: Int = 1, credentialReference: UUID? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL; self.model = model
        self.timeoutSeconds = timeoutSeconds; self.maxOutputTokens = maxOutputTokens; self.jsonMode = jsonMode; self.revision = revision
        self.credentialReference = credentialReference
    }

    public func validated() throws -> URL {
        guard timeoutSeconds.isFinite, (1...180).contains(timeoutSeconds) else {
            throw AIAnalysisError.invalidConfiguration("请求超时必须在 1–180 秒之间。")
        }
        guard (128...16_384).contains(maxOutputTokens) else {
            throw AIAnalysisError.invalidConfiguration("最大输出 Token 必须在 128–16384 之间，建议先使用 8192。")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.count <= 128,
              revision >= 1,
              baseURL.utf8.count <= 2_048,
              let components = URLComponents(string: baseURL), let url = components.url,
              let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              scheme == "https" || (scheme == "http" && Self.isLoopback(host)) else {
            throw AIAnalysisError.invalidConfiguration("请填写来源名称、模型 ID 和合法基础地址；使用 HTTPS，本机服务可使用 HTTP，地址不能带密钥或查询参数。")
        }
        return url
    }

    public var requiresAPIKey: Bool {
        if kind == .ollama { return false }
        return !(URLComponents(string: baseURL)?.host.map(Self.isLoopback) ?? false)
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }
}

public struct AISettings: Codable, Equatable {
    public var providers: [AIProviderConfiguration]
    public var selectedProviderID: UUID?
    public init(providers: [AIProviderConfiguration] = [], selectedProviderID: UUID? = nil) {
        self.providers = providers; self.selectedProviderID = selectedProviderID
    }
    private enum CodingKeys: String, CodingKey { case version, sources, providers, selectedProviderID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 || version == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported settings version")
        }
        providers = try values.decode([AIProviderConfiguration].self, forKey: version == 1 ? .providers : .sources)
        selectedProviderID = try values.decodeIfPresent(UUID.self, forKey: .selectedProviderID)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .version)
        try values.encode(providers, forKey: .sources)
        try values.encodeIfPresent(selectedProviderID, forKey: .selectedProviderID)
    }
    public func validate() throws {
        guard Set(providers.map(\.credentialStorageID)).count == providers.count,
              providers.count <= 30, Set(providers.map(\.id)).count == providers.count,
              selectedProviderID == nil || providers.contains(where: { $0.id == selectedProviderID }) else {
            throw AIAnalysisError.invalidConfiguration("AI 来源过多、编号重复或选择的来源不存在。")
        }
        for provider in providers { _ = try provider.validated() }
    }
}

/// This file contains service metadata only. Credentials live in a separate credential store.
public final class AIConfigurationStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    /// Keep read/check/write mutations in one cross-process critical section.
    /// Requests use immutable credential references, so readers need no lock.
    public func withExclusiveAccess<T>(_ action: () throws -> T) throws -> T {
        guard url.isFileURL else { throw AIAnalysisError.invalidConfiguration("AI 设置必须保存到本机文件。") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AIAnalysisError.invalidConfiguration("无法打开 AI 配置锁。") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            throw AIAnalysisError.invalidConfiguration("AI 配置锁不是当前用户的私有普通文件。")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw AIAnalysisError.invalidConfiguration("其他实例正在修改 AI 来源，请稍后重试。")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
    public func load() throws -> AISettings {
        guard url.isFileURL else { throw AIAnalysisError.invalidConfiguration("AI 设置必须保存到本机文件。") }
        guard FileManager.default.fileExists(atPath: url.path) else { return AISettings() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 131_072 else {
            throw AIAnalysisError.invalidConfiguration("AI 配置文件超过允许大小。")
        }
        do {
            let settings = try AIAnalysisCodec.decoder().decode(AISettings.self, from: Data(contentsOf: url))
            try settings.validate()
            return settings
        } catch {
            throw AIAnalysisError.invalidConfiguration("AI 配置文件损坏或内容无效；请修正文件后重新加载，现有配置不会被自动覆盖。")
        }
    }
    public func save(_ settings: AISettings) throws {
        guard url.isFileURL else { throw AIAnalysisError.invalidConfiguration("AI 设置必须保存到本机文件。") }
        try settings.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try AIAnalysisCodec.encoder(pretty: true).encode(settings)
        guard data.count <= 131_072 else { throw AIAnalysisError.invalidConfiguration("AI 配置文件超过允许大小。") }
        // Complete every fallible write/permission operation before replacing the
        // existing configuration. Immutable credential references keep failures safe.
        var path = Array(url.deletingLastPathComponent().appendingPathComponent(".ai-services-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&path) // Creates the staging file with mode 0600.
        guard descriptor >= 0 else { throw AIAnalysisError.invalidConfiguration("无法创建 AI 配置临时文件（\(errno)）。") }
        let staging = URL(fileURLWithPath: String(cString: path))
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: staging) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        let result = staging.path.withCString { source in url.path.withCString { destination in Darwin.rename(source, destination) } }
        guard result == 0 else { throw AIAnalysisError.invalidConfiguration("无法保存 AI 配置（\(errno)），原配置未替换。") }
    }
}

public protocol AICredentialStore {
    func key(for providerID: UUID) throws -> String?
    func setKey(_ key: String, for providerID: UUID) throws
    func deleteKey(for providerID: UUID) throws
}

public final class KeychainAICredentialStore: AICredentialStore {
    private let service: String
    public init(service: String = "local.gpt-manager.ai") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
    public func key(for providerID: UUID) throws -> String? {
        var request = query(providerID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AIAnalysisError.invalidConfiguration("无法读取系统钥匙串（\(status)），请检查钥匙串权限。")
        }
        return value
    }
    public func setKey(_ key: String, for providerID: UUID) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8_192,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw AIAnalysisError.invalidConfiguration("API Key 不能为空、过长或包含控制字符。")
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query(providerID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(providerID)
            request[kSecValueData as String] = Data(value.utf8)
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(request as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIAnalysisError.invalidConfiguration("无法保存 API Key 到系统钥匙串（\(status)）。") }
    }
    public func deleteKey(for providerID: UUID) throws {
        let status = SecItemDelete(query(providerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIAnalysisError.invalidConfiguration("无法移除系统钥匙串中的 API Key（\(status)）。")
        }
    }
}
