import Foundation
import XCTest
@testable import GPTAnalysisKit

final class AIModelCatalogTests: XCTestCase {
    private func configuration(_ kind: AIProviderKind = .openAICompatible,
                               baseURL: String = "https://example.test/v1") -> AIProviderConfiguration {
        AIProviderConfiguration(name: "模型来源", kind: kind, baseURL: baseURL, model: "", timeoutSeconds: 12)
    }

    private func run<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let completed = DispatchSemaphore(value: 0)
        let box = ModelCatalogTestBox<T>()
        let task = Task.detached {
            do { box.store(.success(try await operation())) }
            catch { box.store(.failure(error)) }
            completed.signal()
        }
        guard completed.wait(timeout: .now() + 6) == .success else {
            task.cancel()
            throw NSError(domain: "ModelCatalogTest", code: 1)
        }
        return try XCTUnwrap(box.read()).get()
    }

    private func failure(_ operation: @escaping () async throws -> [String]) throws -> AIAnalysisError {
        try run {
            do {
                _ = try await operation()
                throw NSError(domain: "ModelCatalogTest", code: 2)
            } catch let error as AIAnalysisError { return error }
        }
    }

    func testOpenAIProtocolsListModelsFromAnEmptyModelDraft() throws {
        for kind in [AIProviderKind.openAIResponses, .openAICompatible] {
            let config = configuration(kind)
            let captured = ModelCatalogTestBox<URLRequest>()
            let session = ModelCatalogMockProtocol.session { request in
                captured.store(.success(request))
                return .init(data: Data("{\"data\":[{\"id\":\"z-model\"},{\"id\":\"a-model\"},{\"id\":\"z-model\"}]}".utf8))
            }
            defer { session.invalidateAndCancel() }
            let models = try run { try await HTTPAIModelCatalogClient(session: session).models(configuration: config, apiKey: " key ") }
            XCTAssertEqual(models, ["a-model", "z-model"])
            let request = try XCTUnwrap(captured.read()).get()
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/models")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.timeoutInterval, 12)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        }
    }

    func testOllamaUsesTagsAndPreservesModelTagsWithoutCredentials() throws {
        let config = configuration(.ollama, baseURL: "http://127.0.0.1:11434")
        let captured = ModelCatalogTestBox<URLRequest>()
        let session = ModelCatalogMockProtocol.session { request in
            captured.store(.success(request))
            return .init(data: Data("{\"models\":[{\"name\":\"qwen3:8b\",\"model\":\"qwen3:8b\"},{\"name\":\"gemma3:4b\"}]}".utf8))
        }
        defer { session.invalidateAndCancel() }
        let models = try run { try await HTTPAIModelCatalogClient(session: session).models(configuration: config, apiKey: nil) }
        XCTAssertEqual(models, ["gemma3:4b", "qwen3:8b"])
        let request = try XCTUnwrap(captured.read()).get()
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/tags")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testLocalCompatibleEndpointAllowsNoCredentialAndEmptyCatalog() throws {
        var config = configuration(.openAICompatible, baseURL: "http://localhost:8080/nested/v1/")
        config.name = ""
        config.model = "  "
        let draft = config
        let captured = ModelCatalogTestBox<URLRequest>()
        let session = ModelCatalogMockProtocol.session { request in
            captured.store(.success(request))
            return .init(data: Data("{\"data\":[]}".utf8))
        }
        defer { session.invalidateAndCancel() }
        let models = try run { try await HTTPAIModelCatalogClient(session: session).models(configuration: draft, apiKey: nil) }
        XCTAssertEqual(models, [])
        XCTAssertEqual(draft.name, "")
        XCTAssertEqual(draft.model, "  ")
        let request = try XCTUnwrap(captured.read()).get()
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8080/nested/v1/models")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testMissingOrUnsafeCredentialIsRejectedBeforeSending() throws {
        let config = configuration()
        let requests = ModelCatalogTestCounter()
        let session = ModelCatalogMockProtocol.session { _ in
            requests.increment()
            return .init(data: Data("{\"data\":[]}".utf8))
        }
        defer { session.invalidateAndCancel() }
        for key in [nil, "", "   "] as [String?] {
            let error = try failure { try await HTTPAIModelCatalogClient(session: session).models(configuration: config, apiKey: key) }
            guard case .missingCredential = error else { return XCTAssertTrue(false) }
        }
        for key in ["key\r\n", "key\u{0}", "key\u{7F}", "key\u{85}", String(repeating: "x", count: 8_193)] {
            let error = try failure { try await HTTPAIModelCatalogClient(session: session).models(configuration: config, apiKey: key) }
            guard case .invalidConfiguration = error else { return XCTAssertTrue(false) }
            XCTAssertFalse(error.description.contains(key))
        }
        XCTAssertEqual(requests.value(), 0)
    }

    func testUnsafeAddressAndInvalidLimitsAreRejectedBeforeSending() throws {
        let requests = ModelCatalogTestCounter()
        let session = ModelCatalogMockProtocol.session { _ in
            requests.increment()
            return .init(data: Data("{\"data\":[]}".utf8))
        }
        defer { session.invalidateAndCancel() }
        for address in ["http://example.test/v1", "https://user:secret@example.test/v1", "https://example.test/v1?key=secret", "https://example.test/v1#secret", "file:///tmp/models"] {
            let config = configuration(baseURL: address)
            let error = try failure { try await HTTPAIModelCatalogClient(session: session).models(configuration: config, apiKey: "key") }
            guard case .invalidConfiguration = error else { return XCTAssertTrue(false) }
            XCTAssertFalse(error.description.contains("secret"))
        }
        var config = configuration()
        config.timeoutSeconds = .infinity
        let draft = config
        let error = try failure { try await HTTPAIModelCatalogClient(session: session).models(configuration: draft, apiKey: "key") }
        guard case .invalidConfiguration = error else { return XCTAssertTrue(false) }
        XCTAssertEqual(requests.value(), 0)
    }

    func testErrorResponsesAndRedirectsDoNotExposeBodiesOrRetry() throws {
        let config = configuration()
        for status in [302, 401, 429, 500] {
            let requests = ModelCatalogTestCounter()
            let session = ModelCatalogMockProtocol.session { _ in
                requests.increment()
                return .init(status: status, data: Data("secret-key private-service-diagnostic".utf8), headers: ["Location": "https://elsewhere.test/models"])
            }
            defer { session.invalidateAndCancel() }
            let error = try failure { try await HTTPAIModelCatalogClient(session: session).models(configuration: config, apiKey: "secret-key") }
            guard case .httpStatus(let value) = error else { return XCTAssertTrue(false) }
            XCTAssertEqual(value, status)
            XCTAssertFalse(error.description.contains("secret-key"))
            XCTAssertFalse(error.description.contains("private-service-diagnostic"))
            XCTAssertEqual(requests.value(), 1)
        }
    }

    func testTransportAndTimeoutErrorsUseSafeMessages() throws {
        let config = configuration()
        for code in [URLError.Code.timedOut, .cannotConnectToHost] {
            let session = ModelCatalogMockProtocol.session { _ in
                throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "secret-key private-service-url"])
            }
            defer { session.invalidateAndCancel() }
            let error = try failure { try await HTTPAIModelCatalogClient(session: session).models(configuration: config, apiKey: "secret-key") }
            guard case .transport = error else { return XCTAssertTrue(false) }
            XCTAssertFalse(error.description.contains("secret-key"))
            XCTAssertFalse(error.description.contains("private-service-url"))
            if code == .timedOut { XCTAssertTrue(error.description.contains("超时")) }
        }
    }

    func testMalformedCatalogAndInvalidIDsAreSafelyRejected() throws {
        let config = configuration()
        let objects: [[String: Any]] = [
            ["models": []], ["data": [["id": 123]]], ["data": [["id": ""]]],
            ["data": [["id": "secret-key\n"]]], ["data": [["id": String(repeating: "x", count: 129)]]]
        ]
        for object in objects {
            let data = try JSONSerialization.data(withJSONObject: object)
            let session = ModelCatalogMockProtocol.session { _ in .init(data: data) }
            defer { session.invalidateAndCancel() }
            let error = try failure { try await HTTPAIModelCatalogClient(session: session).models(configuration: config, apiKey: "key") }
            guard case .invalidResponse = error else { return XCTAssertTrue(false) }
            XCTAssertFalse(error.description.contains("secret-key"))
        }
    }

    func testCatalogHasModelCountAndResponseSizeLimits() throws {
        let config = configuration()
        let tooMany = try JSONSerialization.data(withJSONObject: ["data": (0...2_000).map { ["id": "model-\($0)"] }])
        let countSession = ModelCatalogMockProtocol.session { _ in .init(data: tooMany) }
        defer { countSession.invalidateAndCancel() }
        let countError = try failure { try await HTTPAIModelCatalogClient(session: countSession).models(configuration: config, apiKey: "key") }
        guard case .invalidResponse = countError else { return XCTAssertTrue(false) }
        XCTAssertTrue(countError.description.contains("2000"))
        for headers in [[:], ["Content-Length": "4096"]] as [[String: String]] {
            let session = ModelCatalogMockProtocol.session { _ in
                .init(data: Data(repeating: 32, count: 129), headers: headers)
            }
            defer { session.invalidateAndCancel() }
            let error = try failure { try await HTTPAIModelCatalogClient(session: session, maxResponseBytes: 128).models(configuration: config, apiKey: "key") }
            guard case .invalidResponse = error else { return XCTAssertTrue(false) }
            XCTAssertTrue(error.description.contains("大小限制"))
        }
    }

    func testCancellationStopsAnInFlightCatalogRequest() throws {
        let config = configuration()
        let session = ModelCatalogMockProtocol.session { _ in
            .init(data: Data("{\"data\":[]}".utf8), delay: 0.5)
        }
        defer { session.invalidateAndCancel() }
        let error = try run {
            let task = Task { try await HTTPAIModelCatalogClient(session: session).models(configuration: config, apiKey: "key") }
            try await Task.sleep(nanoseconds: 20_000_000)
            task.cancel()
            do {
                _ = try await task.value
                throw NSError(domain: "ModelCatalogTest", code: 3)
            } catch let error as AIAnalysisError { return error }
        }
        guard case .cancelled = error else { return XCTAssertTrue(false) }
    }
}

private final class ModelCatalogTestBox<Value> {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    func store(_ result: Result<Value, Error>) { lock.lock(); self.result = result; lock.unlock() }
    func read() -> Result<Value, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}

private final class ModelCatalogTestCounter {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class ModelCatalogMockProtocol: URLProtocol {
    struct Reply {
        var status: Int = 200
        var data: Data
        var headers: [String: String] = [:]
        var delay: Double = 0
    }
    private static let handlersLock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> Reply] = [:]
    private let stateLock = NSLock()
    private var stopped = false

    static func session(handler: @escaping (URLRequest) throws -> Reply) -> URLSession {
        let id = UUID().uuidString
        handlersLock.lock(); handlers[id] = handler; handlersLock.unlock()
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [ModelCatalogMockProtocol.self]
        settings.httpAdditionalHeaders = ["X-Model-Catalog-Test": id]
        return URLSession(configuration: settings)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handlersLock.lock()
        let handler = request.value(forHTTPHeaderField: "X-Model-Catalog-Test").flatMap { Self.handlers[$0] }
        Self.handlersLock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let reply = try handler(request)
            if reply.delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { self.deliver(reply) }
            } else { deliver(reply) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private func deliver(_ reply: Reply) {
        stateLock.lock(); let shouldDeliver = !stopped; stateLock.unlock()
        guard shouldDeliver else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.data.isEmpty { client?.urlProtocol(self, didLoad: reply.data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}
