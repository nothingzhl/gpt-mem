import Foundation

/// Provider names are a setup convenience; saved configurations still use the
/// same three protocols, so presets do not couple analysis modules to vendors.
public enum AIProviderPreset: String, CaseIterable, Identifiable {
    case openAI, deepSeek, ollama, custom

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .ollama: return "Ollama"
        case .custom: return "自定义"
        }
    }
    public var subtitle: String {
        switch self {
        case .openAI: return "官方 API"
        case .deepSeek: return "官方 API"
        case .ollama: return "本机模型"
        case .custom: return "兼容服务 / 网关"
        }
    }
    public var symbolName: String {
        switch self {
        case .openAI: return "sparkles"
        case .deepSeek: return "waveform.path"
        case .ollama: return "desktopcomputer"
        case .custom: return "network"
        }
    }
    public var kind: AIProviderKind {
        switch self {
        case .openAI: return .openAIResponses
        case .deepSeek, .custom: return .openAICompatible
        case .ollama: return .ollama
        }
    }
    public var baseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .deepSeek: return "https://api.deepseek.com"
        case .ollama: return "http://localhost:11434"
        case .custom: return ""
        }
    }
    public var defaultModel: String {
        // OpenAI account access and installed local models vary. Their lists are
        // fetched on demand rather than assuming a model is available.
        self == .deepSeek ? "deepseek-flash" : ""
    }
    public func makeConfiguration(id: UUID = UUID()) -> AIProviderConfiguration {
        AIProviderConfiguration(id: id, name: self == .custom ? "" : title,
                                kind: kind, baseURL: baseURL, model: defaultModel)
    }
    public static func matching(_ configuration: AIProviderConfiguration) -> AIProviderPreset {
        let address = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if configuration.kind == .openAICompatible,
           [AIProviderPreset.deepSeek.baseURL, "https://api.deepseek.com/v1"].contains(address) { return .deepSeek }
        return allCases.first { $0 != .custom && $0.kind == configuration.kind && $0.baseURL == address } ?? .custom
    }
}
