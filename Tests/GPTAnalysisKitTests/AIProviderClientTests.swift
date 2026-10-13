import Foundation
import XCTest
@testable import GPTAnalysisKit

final class AIProviderClientTests: XCTestCase {
    private let resultJSON = """
    {"summary":"存在增长，原因仍需验证","observations":[{"text":"占用增长 100 MiB","evidenceIDs":["total"]}],"hypotheses":[{"title":"缓存积累","explanation":"增长可能来自缓存","evidenceIDs":["total"],"missingEvidence":["缺少分配摘要"]}],"nextSteps":[{"subjectID":"process-1","action":"采集诊断摘要","purpose":"验证分配来源"}],"limitations":["曲线无法确认泄漏"]}
    """

    private func input() throws -> AIAnalysisInput {
        try AIAnalysisCodec.decoder().decode(AIAnalysisInput.self, from: Data("""
        {"moduleID":"memory","moduleTitle":"内存","promptVersion":"1","guidance":"根据内存趋势提出可验证假设","windowStart":"2026-10-12T00:00:00Z","windowEnd":"2026-10-12T00:10:00Z","facts":[{"id":"total","title":"总占用","data":{"changeMiB":100}}],"subjects":[{"id":"process-1","label":"PID 1","canInspect":true}],"context":"仅包含脱敏摘要"}
        """.utf8))
    }

    private func configuration(_ kind: AIProviderKind, jsonMode: Bool = true,
                               baseURL: String? = nil) throws -> AIProviderConfiguration {
        let address = baseURL ?? (kind == .ollama ? "http://127.0.0.1:11434" : "https://example.test/v1")
        // Use Codable fixtures so tests also cover the public persisted contract.
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "name": "Test Provider", "kind": kind.rawValue,
            "baseURL": address, "model": "test-model", "timeoutSeconds": 10.0,
            "maxOutputTokens": 2_048, "jsonMode": jsonMode, "revision": 1
        ])
        return try AIAnalysisCodec.decoder().decode(AIProviderConfiguration.self, from: data)
    }

    private func response(_ kind: AIProviderKind, text: String? = nil) throws -> Data {
        let value = text ?? resultJSON
        let object: [String: Any]
        switch kind {
        case .openAIResponses:
            object = ["status": "completed", "output": [
                ["type": "reasoning", "summary": [["type": "summary_text", "text": "Do not display reasoning"]]],
                ["type": "message", "role": "assistant", "status": "completed",
                 "content": [["type": "output_text", "text": value]]]
            ]]
        case .openAICompatible:
            object = ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": value]]]]
        case .ollama:
            object = ["done": true, "done_reason": "stop", "message": ["role": "assistant", "content": value]]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let direct = request.httpBody { data = direct }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var content = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                if count == 0 { break }
                content.append(buffer, count: count)
            }
            data = content
        } else { throw URLError(.zeroByteResource) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func run<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let completion = DispatchSemaphore(value: 0)
        let box = AIClientTestBox<T>()
        let task = Task.detached {
            do { box.store(.success(try await operation())) }
            catch { box.store(.failure(error)) }
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 6) == .success else {
            task.cancel()
            throw NSError(domain: "AIClientTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "异步测试超时"])
        }
        return try XCTUnwrap(box.read()).get()
    }

    private func capturedError(_ operation: @escaping () async throws -> AIAnalysisResult) throws -> AIAnalysisError {
        try run {
            do {
                _ = try await operation()
                throw NSError(domain: "AIClientTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "本应拒绝响应"])
            } catch let error as AIAnalysisError { return error }
        }
    }

    private let privateServiceText = "server-private-evidence-api-key-secret"

    private func errorFor(_ kind: AIProviderKind, object: [String: Any]) throws -> AIAnalysisError {
        try errorFor(kind, data: JSONSerialization.data(withJSONObject: object))
    }

    private func errorFor(_ kind: AIProviderKind, data: Data) throws -> AIAnalysisError {
        let analysisInput = try input()
        let config = try configuration(kind)
        let count = AIClientTestCounter()
        let session = AIClientMockProtocol.session { _ in
            count.increment()
            return .init(data: data)
        }
        defer { session.invalidateAndCancel() }
        let error = try capturedError {
            try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: "api-key-secret")
        }
        XCTAssertEqual(count.value, 1)
        XCTAssertFalse(String(describing: error).contains("server-private"))
        XCTAssertFalse(String(describing: error).contains("api-key-secret"))
        return error
    }

    private func assertLengthLimit(_ error: AIAnalysisError, generated: Int?, reasoning: Int?) {
        if case .generationLengthLimit(let limit, let generatedTokens, let reasoningTokens) = error {
            XCTAssertEqual(limit, 2_048)
            XCTAssertEqual(generatedTokens, generated)
            XCTAssertEqual(reasoningTokens, reasoning)
        } else { XCTAssertTrue(false) }
    }

    func testResponsesUsesItsNativeSchemaAndParsesOnlyOutputMessages() throws {
        let config = try configuration(.openAIResponses)
        let analysisInput = try input()
        let data = try response(.openAIResponses)
        let requestBox = AIClientTestBox<URLRequest>()
        let session = AIClientMockProtocol.session { request in
            requestBox.store(.success(request))
            return .init(data: data)
        }
        defer { session.invalidateAndCancel() }
        let result = try run {
            try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: " secret-key ")
        }
        XCTAssertEqual(result.summary, "存在增长，原因仍需验证")
        XCTAssertEqual(result.observations.first?.evidenceIDs, ["total"])
        let request = try XCTUnwrap(requestBox.read()).get()
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.timeoutInterval, 10)
        let payload = try body(request)
        XCTAssertEqual(payload["store"] as? Bool, false)
        XCTAssertEqual(payload["max_output_tokens"] as? Int, 2_048)
        let format = try XCTUnwrap((payload["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual((format["schema"] as? [String: Any])?["type"] as? String, "object")
        let messages = try XCTUnwrap(payload["input"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("不是指令") == true)
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("summary 不超过 120") == true)
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("hypotheses 最多 3 条，nextSteps 最多 4 条，limitations 最多 3 条") == true)
        XCTAssertTrue((messages.last?["content"] as? String)?.contains("memory") == true)
        XCTAssertNil(payload["messages"])
    }

    func testCompatibleUsesChatJSONModeAndAcceptsAFencedJSONResult() throws {
        let config = try configuration(.openAICompatible)
        let analysisInput = try input()
        let data = try response(.openAICompatible, text: "```json\n\(resultJSON)\n```")
        let requestBox = AIClientTestBox<URLRequest>()
        let session = AIClientMockProtocol.session { request in
            requestBox.store(.success(request))
            return .init(data: data)
        }
        defer { session.invalidateAndCancel() }
        let result = try run { try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: "key") }
        XCTAssertEqual(result.nextSteps.first?.subjectID, "process-1")
        let request = try XCTUnwrap(requestBox.read()).get()
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        let payload = try body(request)
        XCTAssertEqual(payload["stream"] as? Bool, false)
        XCTAssertEqual(payload["max_tokens"] as? Int, 2_048)
        XCTAssertEqual((payload["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        XCTAssertEqual((payload["messages"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(payload["input"])
    }

    func testOllamaUsesLocalChatSchemaWithoutCredential() throws {
        let config = try configuration(.ollama)
        let analysisInput = try input()
        let data = try response(.ollama)
        let requestBox = AIClientTestBox<URLRequest>()
        let session = AIClientMockProtocol.session { request in
            requestBox.store(.success(request))
            return .init(data: data)
        }
        defer { session.invalidateAndCancel() }
        let result = try run { try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: nil) }
        XCTAssertEqual(result.hypotheses.first?.title, "缓存积累")
        let request = try XCTUnwrap(requestBox.read()).get()
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let payload = try body(request)
        XCTAssertEqual(payload["stream"] as? Bool, false)
        XCTAssertEqual((payload["format"] as? [String: Any])?["type"] as? String, "object")
        XCTAssertEqual((payload["options"] as? [String: Any])?["num_predict"] as? Int, 2_048)
        XCTAssertNil(payload["response_format"])
    }

    func testPromptTemplateIsSentToAllThreeProvidersWithoutReplacingModuleRules() throws {
        let prompt = AIAnalysisPrompt(title: "人工设置", text: "优先列出验证缺口", isModified: true)
        let original = try input()
        let analysisInput = try original.applying(prompt: prompt)
        for kind in AIProviderKind.allCases {
            let config = try configuration(kind)
            let data = try response(kind)
            let requestBox = AIClientTestBox<URLRequest>()
            let session = AIClientMockProtocol.session { request in
                requestBox.store(.success(request))
                return .init(data: data)
            }
            defer { session.invalidateAndCancel() }
            _ = try run { try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: "fixture-key") }
            let request = try XCTUnwrap(requestBox.read()).get()
            let payload = try body(request)
            let messages = try XCTUnwrap(payload[kind == .openAIResponses ? "input" : "messages"] as? [[String: Any]])
            let system = try XCTUnwrap(messages.first?["content"] as? String)
            XCTAssertTrue(system.contains(original.guidance))
            XCTAssertTrue(system.contains(prompt.text))
            XCTAssertTrue(system.contains("JSON Schema"))
            let text = try XCTUnwrap(messages.last?["content"] as? String)
            let frozen = try AIAnalysisCodec.decoder().decode(AIAnalysisInput.self, from: Data(text.utf8))
            XCTAssertEqual(frozen.prompt, prompt)
            XCTAssertEqual(frozen.facts, original.facts)
        }
    }

    func testJSONModeCanBeExplicitlyDisabledForAllProviders() throws {
        let analysisInput = try input()
        for kind in [AIProviderKind.openAIResponses, .openAICompatible, .ollama] {
            let config = try configuration(kind, jsonMode: false)
            let data = try response(kind)
            let requestBox = AIClientTestBox<URLRequest>()
            let session = AIClientMockProtocol.session { request in
                requestBox.store(.success(request))
                return .init(data: data)
            }
            defer { session.invalidateAndCancel() }
            _ = try run { try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: "key") }
            let payload = try body(try XCTUnwrap(requestBox.read()).get())
            XCTAssertNil(payload["text"])
            XCTAssertNil(payload["response_format"])
            XCTAssertNil(payload["format"])
        }
    }

    func testInvalidConfigurationAndMissingKeysFailBeforeNetwork() throws {
        let analysisInput = try input()
        let session = AIClientMockProtocol.session { _ in
            throw NSError(domain: "AIClientTest", code: 3)
        }
        defer { session.invalidateAndCancel() }
        let client = HTTPAIProviderClient(session: session)
        let config = try configuration(.openAIResponses)
        let missing = try capturedError { try await client.analyze(input: analysisInput, configuration: config, apiKey: "   ") }
        if case .missingCredential = missing { XCTAssertTrue(true) } else { XCTAssertTrue(false) }
        let invalid = try configuration(.openAICompatible, baseURL: "http://remote.example.test/v1")
        let error = try capturedError { try await client.analyze(input: analysisInput, configuration: invalid, apiKey: "key") }
        if case .invalidConfiguration = error { XCTAssertTrue(true) } else { XCTAssertTrue(false) }
        let headerError = try capturedError { try await client.analyze(input: analysisInput, configuration: config, apiKey: "key\r\nInjected: value") }
        if case .invalidConfiguration = headerError { XCTAssertTrue(true) } else { XCTAssertTrue(false) }
    }

    func testLocalCompatibleEndpointAllowsNoKey() throws {
        let config = try configuration(.openAICompatible, baseURL: "http://localhost:1234/v1/")
        let analysisInput = try input()
        let data = try response(.openAICompatible)
        let session = AIClientMockProtocol.session { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:1234/v1/chat/completions")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return .init(data: data)
        }
        defer { session.invalidateAndCancel() }
        _ = try run { try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: nil) }
    }

    func testHTTPStatusDoesNotExposeServerSecretsAndDoesNotRetry() throws {
        let analysisInput = try input()
        let config = try configuration(.openAICompatible)
        let count = AIClientTestCounter()
        let session = AIClientMockProtocol.session { _ in
            count.increment()
            return .init(status: 401, data: Data("api-key-secret private-evidence".utf8))
        }
        defer { session.invalidateAndCancel() }
        let error = try capturedError { try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: "api-key-secret") }
        if case .httpStatus(let status) = error { XCTAssertEqual(status, 401) } else { XCTAssertTrue(false) }
        XCTAssertFalse(String(describing: error).contains("api-key-secret"))
        XCTAssertFalse(String(describing: error).contains("private-evidence"))
        XCTAssertEqual(count.value, 1)
    }

    func testResponsesRejectsIncompleteRefusalAndReasoningOnly() throws {
        let analysisInput = try input()
        let config = try configuration(.openAIResponses)
        let validOutput: [[String: Any]] = [["type": "message", "content": [["type": "output_text", "text": resultJSON]]]]
        let invalidObjects: [[String: Any]] = [
            ["status": "failed", "error": ["message": "private-secret"], "output": validOutput],
            ["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "secret-refusal"]]]]],
            ["status": "completed", "output": [["type": "reasoning", "content": [["type": "output_text", "text": resultJSON]]]]]
        ]
        for object in invalidObjects {
            let data = try JSONSerialization.data(withJSONObject: object)
            let session = AIClientMockProtocol.session { _ in .init(data: data) }
            defer { session.invalidateAndCancel() }
            let error = try capturedError { try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: "key") }
            if case .invalidResponse = error { XCTAssertTrue(true) } else { XCTAssertTrue(false) }
            XCTAssertFalse(String(describing: error).contains("secret"))
        }
    }

    func testCompatibleAndOllamaRejectTruncatedOrUnfinishedResults() throws {
        let analysisInput = try input()
        let objects: [(AIProviderKind, [String: Any])] = [
            (.openAICompatible, ["choices": [["finish_reason": "stop", "message": ["content": resultJSON, "refusal": "secret"]]]]),
            (.ollama, ["done": false, "message": ["content": resultJSON]])
        ]
        for (kind, object) in objects {
            let config = try configuration(kind)
            let data = try JSONSerialization.data(withJSONObject: object)
            let session = AIClientMockProtocol.session { _ in .init(data: data) }
            defer { session.invalidateAndCancel() }
            let error = try capturedError { try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: "key") }
            if case .invalidResponse = error { XCTAssertTrue(true) } else { XCTAssertTrue(false) }
        }
    }

    func testLengthLimitsAreRecognizedWithoutBodyAndNeverAcceptTruncatedJSON() throws {
        let contents: [String?] = [nil, "{\"summary\":\"server-private", resultJSON]
        for content in contents {
            var responses: [String: Any] = [
                "status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"],
                "usage": ["output_tokens": 2_000, "output_tokens_details": ["reasoning_tokens": 1_800]]
            ]
            var chatChoice: [String: Any] = ["finish_reason": "length"]
            var ollama: [String: Any] = ["done": true, "done_reason": "length", "eval_count": 2_000]
            if let content {
                responses["output"] = [["type": "message", "content": [["type": "output_text", "text": content]]]]
                chatChoice["message"] = ["content": content, "reasoning_content": privateServiceText]
                ollama["message"] = ["content": content, "thinking": privateServiceText]
            }
            let chat: [String: Any] = [
                "choices": [chatChoice],
                "usage": ["completion_tokens": 2_000, "completion_tokens_details": ["reasoning_tokens": 1_800]]
            ]
            assertLengthLimit(try errorFor(.openAIResponses, object: responses), generated: 2_000, reasoning: 1_800)
            assertLengthLimit(try errorFor(.openAICompatible, object: chat), generated: 2_000, reasoning: 1_800)
            assertLengthLimit(try errorFor(.ollama, object: ollama), generated: 2_000, reasoning: nil)
        }
    }

    func testFailureEnvelopesNeedNoBodyAndHideServiceMessages() throws {
        let failures: [(AIProviderKind, [String: Any], String)] = [
            (.openAIResponses, ["error": ["message": privateServiceText]], "服务生成失败"),
            (.openAIResponses, ["status": "failed"], "服务生成失败"),
            (.openAICompatible, ["error": ["message": privateServiceText, "code": privateServiceText]], "服务生成失败"),
            (.openAICompatible, ["choices": [["finish_reason": "error"]]], "服务生成失败"),
            (.openAICompatible, ["choices": [["finish_reason": "failed"]]], "服务生成失败"),
            (.openAICompatible, ["choices": [["finish_reason": "insufficient_system_resource", "message": ["content": resultJSON, "reasoning_content": privateServiceText]]]], "资源不足"),
            (.openAICompatible, ["choices": [["finish_reason": "aborted", "message": ["content": resultJSON, "reasoning_content": privateServiceText]]]], "生成中断"),
            (.ollama, ["error": privateServiceText], "服务生成失败"),
            (.ollama, ["error": ["message": privateServiceText]], "服务生成失败"),
            (.ollama, ["done": true, "done_reason": "error"], "服务生成失败")
        ]
        for (kind, object, expected) in failures {
            let error = try errorFor(kind, object: object)
            if case .invalidResponse(let message) = error { XCTAssertTrue(message.contains(expected)) }
            else { XCTAssertTrue(false) }
        }
    }

    func testContentRestrictionAndRefusalAreDistinctSafeFailures() throws {
        let cases: [(AIProviderKind, [String: Any], String)] = [
            (.openAIResponses, ["status": "incomplete", "incomplete_details": ["reason": "content_filter", "detail": privateServiceText]], "内容限制"),
            (.openAIResponses, ["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": privateServiceText]]]]], "拒绝"),
            (.openAICompatible, ["choices": [["finish_reason": "content_filter"]]], "内容限制"),
            (.openAICompatible, ["choices": [["finish_reason": "refusal"]]], "拒绝"),
            (.openAICompatible, ["choices": [["finish_reason": "stop", "message": ["content": resultJSON, "refusal": privateServiceText]]]], "拒绝"),
            (.openAICompatible, ["choices": [["finish_reason": "stop", "message": ["content": [["type": "refusal", "refusal": privateServiceText]]]]]], "拒绝"),
            (.ollama, ["done": true, "done_reason": "content_filter"], "内容限制"),
            (.ollama, ["done": true, "done_reason": "refusal"], "拒绝")
        ]
        for (kind, object, expected) in cases {
            let error = try errorFor(kind, object: object)
            if case .invalidResponse(let message) = error { XCTAssertTrue(message.contains(expected)) }
            else { XCTAssertTrue(false) }
        }
    }

    func testMissingAndUnknownProtocolCompletionInformationIsExplicit() throws {
        let cases: [(AIProviderKind, [String: Any], String)] = [
            (.openAIResponses, [:], "完成状态"),
            (.openAIResponses, ["status": privateServiceText], "响应状态"),
            (.openAIResponses, ["status": "incomplete"], "停止原因"),
            (.openAIResponses, ["status": "incomplete", "incomplete_details": ["reason": privateServiceText]], "停止原因"),
            (.openAIResponses, ["status": "completed"], "输出消息"),
            (.openAICompatible, [:], "候选答复"),
            (.openAICompatible, ["choices": []], "候选答复"),
            (.openAICompatible, ["choices": [["message": ["content": resultJSON]]]], "未提供答复的结束原因"),
            (.openAICompatible, ["choices": [["finish_reason": NSNull(), "message": ["content": resultJSON]]]], "未提供答复的结束原因"),
            (.openAICompatible, ["choices": [["finish_reason": privateServiceText, "message": ["content": resultJSON]]]], "不支持的结束原因"),
            (.openAICompatible, ["choices": [["finish_reason": "stop"]]], "缺少消息"),
            (.ollama, [:], "尚未完成"),
            (.ollama, ["done": false, "message": ["content": resultJSON]], "尚未完成"),
            (.ollama, ["done": true, "done_reason": privateServiceText, "message": ["content": resultJSON]], "不支持的结束原因")
        ]
        for (kind, object, expected) in cases {
            let error = try errorFor(kind, object: object)
            if case .invalidResponse(let message) = error { XCTAssertTrue(message.contains(expected)) }
            else { XCTAssertTrue(false) }
        }
    }

    func testLengthUsageIncludesOnlyFiniteNonnegativeIntegers() throws {
        let counters: [(Any, Int?)] = [
            (0, 0), (2_000.0, 2_000), (-1, nil), (2.5, nil),
            ("2000", nil), ("NaN", nil), ("Infinity", nil), (true, nil), (NSNull(), nil), (1e100, nil)
        ]
        for (counter, expected) in counters {
            let responses: [String: Any] = [
                "status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"],
                "usage": ["output_tokens": counter, "output_tokens_details": ["reasoning_tokens": counter]]
            ]
            let chat: [String: Any] = [
                "choices": [["finish_reason": "length"]],
                "usage": ["completion_tokens": counter, "completion_tokens_details": ["reasoning_tokens": counter]]
            ]
            let ollama: [String: Any] = ["done": true, "done_reason": "length", "eval_count": counter]
            assertLengthLimit(try errorFor(.openAIResponses, object: responses), generated: expected, reasoning: expected)
            assertLengthLimit(try errorFor(.openAICompatible, object: chat), generated: expected, reasoning: expected)
            assertLengthLimit(try errorFor(.ollama, object: ollama), generated: expected, reasoning: nil)
        }
    }

    func testMalformedUsageCannotHideKnownLengthLimit() throws {
        for usage in [privateServiceText as Any, ["unexpected"], ["completion_tokens": privateServiceText], ["completion_tokens_details": privateServiceText]] {
            let chat: [String: Any] = ["choices": [["finish_reason": "length"]], "usage": usage]
            assertLengthLimit(try errorFor(.openAICompatible, object: chat), generated: nil, reasoning: nil)
        }
        let overflowingNumber = Data("""
        {"choices":[{"finish_reason":"length"}],"usage":{"completion_tokens":1e999}}
        """.utf8)
        assertLengthLimit(try errorFor(.openAICompatible, data: overflowingNumber), generated: nil, reasoning: nil)
    }

    func testOllamaCompletedResponseStillAcceptsMissingOptionalDoneReason() throws {
        let config = try configuration(.ollama)
        let analysisInput = try input()
        let data = try JSONSerialization.data(withJSONObject: ["done": true, "message": ["content": resultJSON]])
        let session = AIClientMockProtocol.session { _ in .init(data: data) }
        defer { session.invalidateAndCancel() }
        let result = try run { try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: nil) }
        XCTAssertEqual(result.summary, "存在增长，原因仍需验证")
    }

    func testRejectsInvalidJSONAndResponseSizeBeforeParsing() throws {
        let analysisInput = try input()
        let config = try configuration(.openAICompatible)
        for text in ["解释文字\n\(resultJSON)", "{\"summary\":\"缺少字段\"}", "```json\n\(resultJSON)\n```\n其他内容"] {
            let data = try response(.openAICompatible, text: text)
            let session = AIClientMockProtocol.session { _ in .init(data: data) }
            defer { session.invalidateAndCancel() }
            let error = try capturedError { try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: "key") }
            if case .invalidResponse = error { XCTAssertTrue(true) } else { XCTAssertTrue(false) }
        }
        for headers in [[String: String](), ["Content-Length": "2048"]] {
            let session = AIClientMockProtocol.session { _ in .init(data: Data(repeating: 65, count: 2_048), headers: headers) }
            defer { session.invalidateAndCancel() }
            let error = try capturedError { try await HTTPAIProviderClient(session: session, maxResponseBytes: 1_024).analyze(input: analysisInput, configuration: config, apiKey: "key") }
            if case .invalidResponse(let message) = error { XCTAssertTrue(message.contains("大小限制")) } else { XCTAssertTrue(false) }
        }
    }

    func testTimeoutAndCancellationReturnSafeErrors() throws {
        let analysisInput = try input()
        let config = try configuration(.openAICompatible)
        let timeoutSession = AIClientMockProtocol.session { _ in
            .init(error: URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "secret-url-and-key"]))
        }
        defer { timeoutSession.invalidateAndCancel() }
        let timeoutError = try capturedError { try await HTTPAIProviderClient(session: timeoutSession).analyze(input: analysisInput, configuration: config, apiKey: "key") }
        if case .transport(let message) = timeoutError { XCTAssertTrue(message.contains("超时")) } else { XCTAssertTrue(false) }
        XCTAssertFalse(String(describing: timeoutError).contains("secret"))

        let started = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let errorBox = AIClientTestBox<AIAnalysisError>()
        let data = try response(.openAICompatible)
        let session = AIClientMockProtocol.session { _ in
            started.signal()
            return .init(data: data, delay: 2)
        }
        defer { session.invalidateAndCancel() }
        let task = Task.detached {
            do {
                _ = try await HTTPAIProviderClient(session: session).analyze(input: analysisInput, configuration: config, apiKey: "key")
                errorBox.store(.failure(URLError(.unknown)))
            } catch let error as AIAnalysisError { errorBox.store(.success(error)) }
            catch { errorBox.store(.failure(error)) }
            completed.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
        task.cancel()
        XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
        let cancelled = try XCTUnwrap(errorBox.read()).get()
        if case .cancelled = cancelled { XCTAssertTrue(true) } else { XCTAssertTrue(false) }
    }
}

private final class AIClientTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func store(_ value: Result<T, Error>) { lock.lock(); defer { lock.unlock() }; result = value }
    func read() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}

private final class AIClientTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class AIClientMockProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var data = Data()
        var headers = [String: String]()
        var error: Error?
        var delay: TimeInterval = 0
    }
    private static let handlersLock = NSLock()
    private static var handlers = [String: (URLRequest) throws -> Reply]()
    private let stateLock = NSLock()
    private var stopped = false

    static func session(handler: @escaping (URLRequest) throws -> Reply) -> URLSession {
        let identifier = UUID().uuidString
        handlersLock.lock()
        handlers[identifier] = handler
        handlersLock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AIClientMockProtocol.self]
        config.httpAdditionalHeaders = ["X-AI-Test-Session": identifier]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.handlersLock.lock()
        let handler = request.value(forHTTPHeaderField: "X-AI-Test-Session").flatMap { Self.handlers[$0] }
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
        stateLock.lock()
        let shouldDeliver = !stopped
        stateLock.unlock()
        guard shouldDeliver else { return }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.data.isEmpty { client?.urlProtocol(self, didLoad: reply.data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }
}
