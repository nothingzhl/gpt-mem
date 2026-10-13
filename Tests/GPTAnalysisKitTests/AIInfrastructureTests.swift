import Foundation
import XCTest
@testable import GPTAnalysisKit

final class AIInfrastructureTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(moduleID: String = "future-disk-module", context: String = "", canInspect: Bool = true) -> AIAnalysisInput {
        AIAnalysisInput(moduleID: moduleID, moduleTitle: "磁盘分析", promptVersion: "1", guidance: "根据证据判断磁盘变化。",
                        windowStart: start, windowEnd: start.addingTimeInterval(60),
                        facts: [.init(id: "disk.change", title: "磁盘变化", data: .object(["bytes": .number(100)]))],
                        subjects: [.init(id: "s1", label: "匿名对象", canInspect: canInspect)], context: context)
    }
    private func configuration() -> AIProviderConfiguration {
        .init(name: "fixture-provider", kind: .openAIResponses, baseURL: "https://example.test/v1", model: "fixture-model")
    }
    private func result(reference: String = "disk.change", subject: String? = "s1") -> AIAnalysisResult {
        .init(summary: "应进一步检查磁盘变化。", observations: [.init(text: "磁盘出现变化。", evidenceIDs: [reference])],
              hypotheses: [.init(title: "可能是新文件", explanation: "需要结合活动验证。", evidenceIDs: [reference], missingEvidence: ["文件活动"])],
              nextSteps: [.init(subjectID: subject, action: "查看变化明细", purpose: "确认变化来源")], limitations: ["不能据此确认具体文件。"])
    }

    func testProviderValidationAndLocalHTTPBoundary() throws {
        for kind in AIProviderKind.allCases {
            let config = AIProviderConfiguration(name: "fixture", kind: kind, baseURL: kind.suggestedBaseURL, model: "fixture-model")
            XCTAssertFalse(try config.validated().absoluteString.isEmpty)
        }
        for url in ["http://localhost:11434", "http://127.0.0.1:8080/v1", "http://[::1]:11434"] {
            let config = AIProviderConfiguration(name: "local", kind: .openAICompatible, baseURL: url, model: "fixture")
            _ = try config.validated()
            XCTAssertFalse(config.requiresAPIKey)
        }
        for url in ["http://remote.example/v1", "https://user:secret@example.test/v1", "https://example.test/v1?key=secret", "https://example.test/v1#secret", "file:///tmp/key"] {
            var config = configuration(); config.baseURL = url
            XCTAssertThrowsError(try config.validated())
        }
        var invalid = configuration(); invalid.timeoutSeconds = .infinity
        XCTAssertThrowsError(try invalid.validated())
        invalid = configuration(); invalid.maxOutputTokens = 0
        XCTAssertThrowsError(try invalid.validated())
    }

    func testPrivateSettingsRoundTripWithoutCredentialFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-config-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIConfigurationStore(url: directory.appendingPathComponent("ai-services.json"))
        XCTAssertTrue(try store.load().providers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let config = configuration()
        let settings = AISettings(providers: [config], selectedProviderID: config.id)
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        let json = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(json.contains("apiKey"))
        XCTAssertFalse(json.contains("fixture-secret"))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        var replacement = config; replacement.model = "another-model"
        try store.save(AISettings(providers: [replacement], selectedProviderID: config.id))
        XCTAssertEqual(try store.load().providers.first?.model, "another-model")
        var invalid = settings; invalid.selectedProviderID = UUID()
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.load().providers.first?.model, "another-model")
    }

    func testMalformedSettingsFailWithoutSilentlyResettingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-bad-config-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AIConfigurationStore(url: directory.appendingPathComponent("ai-services.json"))
        let corrupt = Data("{broken configuration".utf8)
        try corrupt.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
        var duplicate = AISettings(providers: [configuration()]); duplicate.providers.append(duplicate.providers[0])
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testInputAndResultRejectInventedEvidenceOrUnavailableSubjects() throws {
        let valid = input()
        XCTAssertFalse(try valid.validated().isEmpty)
        try result().validate(against: valid)
        XCTAssertThrowsError(try result(reference: "invented").validate(against: valid))
        XCTAssertThrowsError(try result(subject: "unknown").validate(against: valid))
        XCTAssertThrowsError(try result().validate(against: input(canInspect: false)))
        try result(subject: nil).validate(against: input(canInspect: false))
        let duplicate = AIAnalysisInput(moduleID: valid.moduleID, moduleTitle: valid.moduleTitle, promptVersion: "1", guidance: "",
                                        windowStart: valid.windowStart, windowEnd: valid.windowEnd,
                                        facts: valid.facts + valid.facts, subjects: valid.subjects)
        XCTAssertThrowsError(try duplicate.validated())
        XCTAssertThrowsError(try input(context: String(repeating: "x", count: 8_193)).validated())
    }

    func testCoordinatorReusesOtherModulesAndCachesByInputAndProvider() throws {
        let client = InfrastructureMockClient(result: result())
        let credentials = InfrastructureCredentials()
        let coordinator = AIAnalysisCoordinator(client: client, credentials: credentials)
        var config = configuration()
        try credentials.setKey("fixture-secret", for: config.id)
        let module = InfrastructureModule(input: input())
        let first = try awaitValue { try await coordinator.analyze(module: module, configuration: config) }
        XCTAssertEqual(first.moduleID, "future-disk-module")
        XCTAssertEqual(first.providerID, config.id)
        XCTAssertEqual(first.inputFingerprint.count, 64)
        XCTAssertFalse(first.wasCached)
        let cached = try awaitValue { try await coordinator.analyze(module: module, configuration: config) }
        XCTAssertTrue(cached.wasCached)
        XCTAssertEqual(cached.result, first.result)
        XCTAssertEqual(client.callCount, 1)
        config.model = "another-model"
        let changedProvider = try awaitValue { try await coordinator.analyze(module: module, configuration: config) }
        XCTAssertFalse(changedProvider.wasCached)
        XCTAssertNotEqual(first.inputFingerprint, changedProvider.inputFingerprint)
        let changedModule = InfrastructureModule(input: input(moduleID: "future-network-module"))
        let changed = try awaitValue { try await coordinator.analyze(module: changedModule, configuration: config) }
        XCTAssertNotEqual(changed.inputFingerprint, changedProvider.inputFingerprint)
        let contextModule = InfrastructureModule(input: input(moduleID: "future-network-module", context: "刚运行同步"))
        _ = try awaitValue { try await coordinator.analyze(module: contextModule, configuration: config) }
        XCTAssertEqual(client.callCount, 4)
        try awaitValue { await coordinator.clearCache() }
        _ = try awaitValue { try await coordinator.analyze(module: contextModule, configuration: config) }
        XCTAssertEqual(client.callCount, 5)
    }

    func testMissingCredentialAndInvalidResultsNeverCacheOrRetry() throws {
        let client = InfrastructureMockClient(result: result(reference: "invented"))
        let credentials = InfrastructureCredentials()
        let coordinator = AIAnalysisCoordinator(client: client, credentials: credentials)
        let config = configuration(), module = InfrastructureModule(input: input())
        XCTAssertThrowsError(try awaitValue { try await coordinator.analyze(module: module, configuration: config) })
        XCTAssertEqual(client.callCount, 0)
        try credentials.setKey("fixture-secret", for: config.id)
        for _ in 0..<2 {
            XCTAssertThrowsError(try awaitValue { try await coordinator.analyze(module: module, configuration: config) })
        }
        XCTAssertEqual(client.callCount, 2)
    }

    func testCacheRevisionChangesWhenCredentialsAreEdited() throws {
        let client = InfrastructureMockClient(result: result()), credentials = InfrastructureCredentials()
        let coordinator = AIAnalysisCoordinator(client: client, credentials: credentials)
        var config = configuration()
        try credentials.setKey("fixture-secret", for: config.id)
        let module = InfrastructureModule(input: input())
        let previous = try awaitValue { try await coordinator.analyze(module: module, configuration: config) }
        config.revision += 1
        let revised = try awaitValue { try await coordinator.analyze(module: module, configuration: config) }
        XCTAssertNotEqual(previous.inputFingerprint, revised.inputFingerprint)
        XCTAssertEqual(client.callCount, 2)
    }

    func testActualCredentialChangesInvalidateCacheWithoutRevisionChange() throws {
        let client = InfrastructureMockClient(result: result()), credentials = InfrastructureCredentials()
        let coordinator = AIAnalysisCoordinator(client: client, credentials: credentials)
        let config = configuration(), module = InfrastructureModule(input: input())
        try credentials.setKey("fixture-secret-one", for: config.id)
        let first = try awaitValue { try await coordinator.analyze(module: module, configuration: config) }
        try credentials.setKey("fixture-secret-two", for: config.id)
        let changed = try awaitValue { try await coordinator.analyze(module: module, configuration: config) }
        XCTAssertNotEqual(first.inputFingerprint, changed.inputFingerprint)
        XCTAssertFalse(changed.wasCached)
        XCTAssertEqual(client.callCount, 2)
        try credentials.deleteKey(for: config.id)
        XCTAssertThrowsError(try awaitValue { try await coordinator.analyze(module: module, configuration: config) })
        XCTAssertEqual(client.callCount, 2)
    }

    func testSubsecondWindowsDoNotShareCachedRecords() throws {
        let client = InfrastructureMockClient(result: result()), credentials = InfrastructureCredentials()
        let coordinator = AIAnalysisCoordinator(client: client, credentials: credentials)
        let config = configuration(), original = input()
        try credentials.setKey("fixture-secret", for: config.id)
        let shifted = AIAnalysisInput(moduleID: original.moduleID, moduleTitle: original.moduleTitle,
                                      promptVersion: original.promptVersion, guidance: original.guidance,
                                      windowStart: original.windowStart.addingTimeInterval(0.1), windowEnd: original.windowEnd.addingTimeInterval(0.1),
                                      facts: original.facts, subjects: original.subjects)
        let first = try awaitValue { try await coordinator.analyze(module: InfrastructureModule(input: original), configuration: config) }
        let later = try awaitValue { try await coordinator.analyze(module: InfrastructureModule(input: shifted), configuration: config) }
        XCTAssertNotEqual(first.inputFingerprint, later.inputFingerprint)
        XCTAssertEqual(later.windowStart, shifted.windowStart)
        XCTAssertEqual(later.windowEnd, shifted.windowEnd)
        XCTAssertEqual(client.callCount, 2)
    }

    func testExplicitCredentialSnapshotIsBoundToItsApprovedRequest() throws {
        let client = InfrastructureMockClient(result: result()), credentials = InfrastructureCredentials()
        let coordinator = AIAnalysisCoordinator(client: client, credentials: credentials)
        let config = configuration(), module = InfrastructureModule(input: input())
        try credentials.setKey("newly-edited-key", for: config.id)
        _ = try awaitValue { try await coordinator.analyze(module: module, configuration: config, apiKey: "approved-key") }
        XCTAssertEqual(client.lastKey, "approved-key")
        _ = try awaitValue { try await coordinator.analyze(module: module, configuration: config) }
        XCTAssertEqual(client.lastKey, "newly-edited-key")
        XCTAssertEqual(client.callCount, 2)
    }

    private func awaitValue<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let box = InfrastructureAsyncBox<T>(), semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do { box.store(.success(try await operation())) } catch { box.store(.failure(error)) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else { task.cancel(); throw AIAnalysisError.transport("测试等待超时") }
        return try XCTUnwrap(box.load()).get()
    }
}

private struct InfrastructureModule: AIAnalysisModule {
    let input: AIAnalysisInput
    func makeInput() throws -> AIAnalysisInput { input }
}
private final class InfrastructureCredentials: AICredentialStore {
    private var values: [UUID: String] = [:]
    func key(for providerID: UUID) throws -> String? { values[providerID] }
    func setKey(_ key: String, for providerID: UUID) throws { values[providerID] = key }
    func deleteKey(for providerID: UUID) throws { values.removeValue(forKey: providerID) }
}
private final class InfrastructureMockClient: AIProviderClient {
    private let lock = NSLock()
    private var calls = 0
    private var key: String?
    private let output: AIAnalysisResult
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var lastKey: String? { lock.lock(); defer { lock.unlock() }; return key }
    init(result: AIAnalysisResult) { output = result }
    private func recordCall(key: String?) { lock.lock(); calls += 1; self.key = key; lock.unlock() }
    func analyze(input: AIAnalysisInput, configuration: AIProviderConfiguration, apiKey: String?) async throws -> AIAnalysisResult {
        recordCall(key: apiKey); return output
    }
}
private final class InfrastructureAsyncBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func store(_ value: Result<T, Error>) { lock.lock(); result = value; lock.unlock() }
    func load() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}
