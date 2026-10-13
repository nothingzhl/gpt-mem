import Foundation
import XCTest
import GPTAnalysisKit
@testable import GPTSessionKit

final class SessionHandoffAITests: XCTestCase {
    func testSelectsOriginalGoalAndRecentConversationWithoutPrivateMetadata() throws {
        let summary = CodexSessionSummary(id: "s", sessionID: "private-session-id",
            fileURL: URL(fileURLWithPath: "/private/source/session.jsonl"), title: "private-title",
            projectPath: "/private/project", startedAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 20))
        var messages = (0..<40).map { SessionMessage(id: "/private/message-\($0)", kind: $0 % 2 == 0 ? .user : .assistant, text: "line-\($0)") }
        messages += [.init(id: "tool", kind: .toolResult, text: "TOOL-ONLY-SECRET"),
                     .init(id: "thinking", kind: .reasoning, text: "THINKING-SECRET")]
        let module = try SessionHandoffAIModule(transcript: .init(summary: summary, messages: messages, warnings: ["private-warning-path"]))
        let json = String(decoding: try module.input.validated(), as: UTF8.self)
        XCTAssertEqual(module.input.moduleID, "session.handoff")
        XCTAssertEqual(module.input.facts.count, 22)
        XCTAssertTrue(json.contains("line-0"))
        XCTAssertTrue(json.contains("line-39"))
        XCTAssertFalse(json.contains("line-19"))
        XCTAssertFalse(json.contains("TOOL-ONLY-SECRET"))
        XCTAssertFalse(json.contains("THINKING-SECRET"))
        XCTAssertFalse(json.contains("private-session-id"))
        XCTAssertFalse(json.contains("private-warning-path"))
        XCTAssertFalse(json.contains("/private/"))
        XCTAssertTrue(module.subjectLabels["m1"]?.contains("/private/message-0") == true)
        XCTAssertTrue(module.subjectLabels["session"]?.contains("private-title") == true)
        XCTAssertTrue(module.subjectLabels["session"]?.contains("/private/project") == true)
    }

    func testMultibyteEscapedAndHugeMessagesStayInsideInputContract() throws {
        let summary = CodexSessionSummary(id: "s", sessionID: "s", fileURL: URL(fileURLWithPath: "/fixture"), title: "S",
            updatedAt: Date(timeIntervalSince1970: 10))
        let messages = (0..<30).map { SessionMessage(id: String($0), kind: .user,
            text: String(repeating: "👨‍👩‍👧‍👦中文\n\u{01}\\\"", count: 2_000)) }
        let module = try SessionHandoffAIModule(transcript: .init(summary: summary, messages: messages))
        let data = try module.input.validated()
        XCTAssertTrue(data.count < 131_072)
        XCTAssertTrue(module.input.windowEnd > module.input.windowStart)
        for fact in module.input.facts.dropFirst() {
            guard case .object(let values) = fact.data, case .string(let text) = values["text"] else { continue }
            XCTAssertFalse(text.contains("�"))
            XCTAssertTrue(try JSONEncoder().encode(text).count <= 3_000)
            XCTAssertEqual(values["isTruncated"], .bool(true))
        }
    }

    func testIdenticalExcerptsFromDifferentSessionsHaveDistinctCacheIdentity() throws {
        let first = CodexSessionSummary(id: "a", sessionID: "a", fileURL: URL(fileURLWithPath: "/fixture/a"), title: "A", updatedAt: Date(timeIntervalSince1970: 10))
        let second = CodexSessionSummary(id: "b", sessionID: "b", fileURL: URL(fileURLWithPath: "/fixture/b"), title: "B", updatedAt: first.updatedAt)
        let messages = [SessionMessage(id: "u", kind: .user, text: "same text")]
        let a = try SessionHandoffAIModule(transcript: .init(summary: first, messages: messages))
        let b = try SessionHandoffAIModule(transcript: .init(summary: second, messages: messages))
        XCTAssertNotEqual(a.input.facts.first?.data, b.input.facts.first?.data)
        XCTAssertNotEqual(try a.input.validated(), try b.input.validated())
        XCTAssertEqual(a.input, try SessionHandoffAIModule(transcript: .init(summary: first, messages: messages)).input)
    }

    func testEmptyInputAndOversizedContextAreRejected() throws {
        let summary = CodexSessionSummary(id: "s", sessionID: "s", fileURL: URL(fileURLWithPath: "/fixture"), title: "S")
        XCTAssertThrowsError(try SessionHandoffAIModule(transcript: .init(summary: summary)))
        let transcript = SessionTranscript(summary: summary, messages: [.init(id: "u", kind: .user, text: "目标")])
        XCTAssertThrowsError(try SessionHandoffAIModule(transcript: transcript, context: String(repeating: "x", count: 9_000)))
    }

    func testReportsRetainPresentationAndOldInputStillDecodes() throws {
        let summary = CodexSessionSummary(id: "s", sessionID: "s", fileURL: URL(fileURLWithPath: "/fixture"), title: "S")
        let module = try SessionHandoffAIModule(transcript: .init(summary: summary, messages: [.init(id: "u", kind: .user, text: "完成搜索")]))
        let input = module.input
        let result = AIAnalysisResult(summary: "继续完善搜索", observations: [.init(text: "用户要求完成搜索，尚未验证。", evidenceIDs: ["m1"])],
            hypotheses: [], nextSteps: [.init(subjectID: "session", action: "检查实现和测试", purpose: "核对当前状态")], limitations: ["只有历史摘录"])
        let record = AIAnalysisRecord(moduleID: input.moduleID, moduleTitle: input.moduleTitle, providerID: UUID(), providerName: "Mock", model: "fixture",
            inputFingerprint: String(repeating: "a", count: 64), windowStart: input.windowStart, windowEnd: input.windowEnd, result: result)
        let report = AISavedReport(record: record, input: input, subjectLabels: module.subjectLabels, windowSelectionSeconds: 1)
        let markdown = try AIReportExport.markdown(report)
        XCTAssertTrue(markdown.contains("目标、进展与约束"))
        XCTAssertTrue(markdown.contains("继续工作清单"))
        XCTAssertTrue(markdown.contains("真实用户提问"))
        let draft = SessionHandoffAIModule.markdown(record: record, input: input, subjectLabels: module.subjectLabels)
        XCTAssertTrue(draft.contains("核对当前状态"))
        XCTAssertTrue(draft.contains("原消息：u"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: AIAnalysisCodec.encoder().encode(input)) as? [String: Any])
        object.removeValue(forKey: "presentation")
        let old = try AIAnalysisCodec.decoder().decode(AIAnalysisInput.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.presentation)
        XCTAssertTrue(try old.validated().count > 0)
    }
}
