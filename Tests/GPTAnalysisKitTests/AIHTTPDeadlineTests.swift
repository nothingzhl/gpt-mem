import Foundation
import XCTest
@testable import GPTAnalysisKit

final class AIHTTPDeadlineTests: XCTestCase {
    func testAnalysisDeadlineStopsSlowBodyWithoutRetry() throws {
        let probe = DeadlineProbe()
        let session = DeadlineProtocol.session(probe: probe)
        defer { session.invalidateAndCancel() }
        let input = AIAnalysisInput(moduleID: "fixture", moduleTitle: "模拟模块", promptVersion: "1", guidance: "",
            windowStart: Date(timeIntervalSince1970: 1_000), windowEnd: Date(timeIntervalSince1970: 1_060),
            facts: [.init(id: "fact", title: "模拟事实", data: .number(1))], subjects: [])
        let config = AIProviderConfiguration(name: "模拟来源", kind: .openAICompatible,
            baseURL: "https://example.test/v1", model: "fixture", timeoutSeconds: 1)
        let started = Date()
        let error = try failure {
            _ = try await HTTPAIProviderClient(session: session).analyze(input: input, configuration: config, apiKey: "fixture-key")
        }
        guard case .transport(let message) = error else { return XCTAssertTrue(false) }
        XCTAssertTrue(message.contains("超时"))
        XCTAssertTrue(Date().timeIntervalSince(started) < 2)
        XCTAssertEqual(probe.snapshot().requests, 1)
        XCTAssertTrue(probe.snapshot().chunks >= 3)
        XCTAssertTrue(probe.waitUntilStopped())
    }

    func testModelCatalogDeadlineStopsSlowBodyWithoutRetry() throws {
        let probe = DeadlineProbe()
        let session = DeadlineProtocol.session(probe: probe)
        defer { session.invalidateAndCancel() }
        let config = AIProviderConfiguration(name: "模拟来源", kind: .openAIResponses,
            baseURL: "https://example.test/v1", model: "", timeoutSeconds: 1)
        let started = Date()
        let error = try failure {
            _ = try await HTTPAIModelCatalogClient(session: session).models(configuration: config, apiKey: "fixture-key")
        }
        guard case .transport(let message) = error else { return XCTAssertTrue(false) }
        XCTAssertTrue(message.contains("超时"))
        XCTAssertTrue(Date().timeIntervalSince(started) < 2)
        XCTAssertEqual(probe.snapshot().requests, 1)
        XCTAssertTrue(probe.snapshot().chunks >= 3)
        XCTAssertTrue(probe.waitUntilStopped())
    }

    func testCallerCancellationStopsBodyBeforeDeadline() throws {
        let probe = DeadlineProbe()
        let session = DeadlineProtocol.session(probe: probe)
        defer { session.invalidateAndCancel() }
        let config = AIProviderConfiguration(name: "模拟来源", kind: .openAIResponses,
            baseURL: "https://example.test/v1", model: "", timeoutSeconds: 10)
        let started = Date()
        let error = try failure {
            let task = Task { try await HTTPAIModelCatalogClient(session: session).models(configuration: config, apiKey: "fixture-key") }
            try await Task.sleep(nanoseconds: 250_000_000)
            task.cancel()
            _ = try await task.value
        }
        guard case .cancelled = error else { return XCTAssertTrue(false) }
        XCTAssertTrue(Date().timeIntervalSince(started) < 2)
        XCTAssertTrue(probe.snapshot().chunks >= 1)
        XCTAssertEqual(probe.snapshot().requests, 1)
        XCTAssertTrue(probe.waitUntilStopped())
    }

    private func failure(_ operation: @escaping () async throws -> Void) throws -> AIAnalysisError {
        let done = DispatchSemaphore(value: 0)
        let box = DeadlineErrorBox()
        let task = Task.detached {
            do { try await operation() }
            catch { box.store(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 4) == .success else {
            task.cancel()
            throw AIAnalysisError.transport("模拟请求未按时结束")
        }
        return try XCTUnwrap(box.load() as? AIAnalysisError)
    }
}

private final class DeadlineErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func store(_ error: Error) { lock.lock(); self.error = error; lock.unlock() }
    func load() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
}

private final class DeadlineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var chunks = 0
    private var stopped = false
    private let stopSignal = DispatchSemaphore(value: 0)
    func start() { lock.lock(); requests += 1; lock.unlock() }
    func chunk() { lock.lock(); chunks += 1; lock.unlock() }
    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        if !alreadyStopped { stopSignal.signal() }
    }
    func waitUntilStopped() -> Bool {
        // URLSessionTask.cancel() returns before URLProtocol's asynchronous
        // stopLoading callback. Verify that callback instead of racing it.
        if snapshot().stopped { return true }
        return stopSignal.wait(timeout: .now() + 1) == .success && snapshot().stopped
    }
    func snapshot() -> (requests: Int, chunks: Int, stopped: Bool) {
        lock.lock(); defer { lock.unlock() }; return (requests, chunks, stopped)
    }
}

/// Emits a byte every 100 ms indefinitely. Each byte keeps an inactivity timer
/// alive; the app must cancel the actual transfer at its overall deadline.
private final class DeadlineProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var probes: [String: DeadlineProbe] = [:]
    private var probe: DeadlineProbe?

    static func session(probe: DeadlineProbe) -> URLSession {
        let id = UUID().uuidString
        lock.lock(); probes[id] = probe; lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeadlineProtocol.self]
        config.httpAdditionalHeaders = ["X-Deadline-Fixture": id]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        probe = request.value(forHTTPHeaderField: "X-Deadline-Fixture").flatMap { Self.probes.removeValue(forKey: $0) }
        Self.lock.unlock()
        probe?.start()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        emitNext()
    }
    private func emitNext() {
        guard let probe, !probe.snapshot().stopped else { return }
        probe.chunk()
        client?.urlProtocol(self, didLoad: Data([32]))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.emitNext() }
    }
    override func stopLoading() { probe?.stop() }
}
