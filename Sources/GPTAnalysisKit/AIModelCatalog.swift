import Foundation

/// Lists model identifiers independently of any analysis module or saved credentials.
/// Callers may pass a draft configuration before filling its name or selecting a model.
public protocol AIModelCatalogClient {
    func models(configuration: AIProviderConfiguration, apiKey: String?) async throws -> [String]
}

public final class HTTPAIModelCatalogClient: AIModelCatalogClient {
    private let session: URLSession
    private let ownsSession: Bool
    private let maxResponseBytes: Int
    private let rejectsRedirects = AIModelCatalogRejectRedirectDelegate()
    private static let maxModels = 2_000

    public init(session: URLSession? = nil, maxResponseBytes: Int = 1_048_576) {
        if let session {
            self.session = session
            ownsSession = false
        } else {
            let settings = URLSessionConfiguration.ephemeral
            settings.httpShouldSetCookies = false
            settings.httpCookieStorage = nil
            settings.urlCredentialStorage = nil
            settings.urlCache = nil
            self.session = URLSession(configuration: settings)
            ownsSession = true
        }
        self.maxResponseBytes = max(1, maxResponseBytes)
    }

    deinit {
        if ownsSession { session.invalidateAndCancel() }
    }

    public func models(configuration: AIProviderConfiguration, apiKey: String?) async throws -> [String] {
        do {
            try Task.checkCancellation()
            // Naming and model selection do not change a catalog request's endpoint.
            var validation = configuration
            validation.name = "model-catalog"
            validation.model = "model-catalog"
            let baseURL = try validation.validated()
            let suppliedKey = apiKey ?? ""
            guard suppliedKey.utf8.count <= 8_192,
                  suppliedKey.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw AIAnalysisError.invalidConfiguration("API Key 过长或包含换行、控制字符")
            }
            let credential = suppliedKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !configuration.requiresAPIKey || !credential.isEmpty else {
                throw AIAnalysisError.missingCredential
            }

            let path = configuration.kind == .ollama ? ["api", "tags"] : ["models"]
            let url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: configuration.timeoutSeconds)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !credential.isEmpty { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
            let data = try await responseData(for: request)

            let identifiers: [String]
            switch configuration.kind {
            case .openAIResponses, .openAICompatible:
                identifiers = try JSONDecoder().decode(OpenAIModelsEnvelope.self, from: data).data.map(\.id)
            case .ollama:
                identifiers = try JSONDecoder().decode(OllamaModelsEnvelope.self, from: data).models.map(\.name)
            }
            guard identifiers.count <= Self.maxModels else {
                throw AIAnalysisError.invalidResponse("模型列表超过 2000 项，请手动填写模型 ID")
            }
            let normalized = try identifiers.map { identifier -> String in
                let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.count <= 128,
                      identifier.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                    throw AIAnalysisError.invalidResponse("模型列表包含无效或过长的模型 ID")
                }
                return value
            }
            try Task.checkCancellation()
            return Set(normalized).sorted()
        } catch is CancellationError {
            throw AIAnalysisError.cancelled
        } catch let error as AIAnalysisError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw AIAnalysisError.cancelled }
            if error.code == .timedOut {
                throw AIAnalysisError.transport("获取模型列表超时，请检查服务状态或增加超时时间")
            }
            // NSError descriptions may contain the requested address or credentials.
            throw AIAnalysisError.transport("无法获取模型列表，请检查地址和网络；也可以手动填写模型 ID")
        } catch {
            if Task.isCancelled { throw AIAnalysisError.cancelled }
            throw AIAnalysisError.invalidResponse("模型列表格式无法解析；也可以手动填写模型 ID")
        }
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        try await AIHTTPResponseReader.data(for: request, session: session, delegate: rejectsRedirects,
                                           maxBytes: maxResponseBytes, sizeError: "模型列表响应超过大小限制")
    }
}

private final class AIModelCatalogRejectRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct OpenAIModelsEnvelope: Decodable {
    let data: [Model]
    struct Model: Decodable { let id: String }
}

private struct OllamaModelsEnvelope: Decodable {
    let models: [Model]
    struct Model: Decodable { let name: String }
}
