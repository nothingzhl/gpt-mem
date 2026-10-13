import Foundation
import XCTest
@testable import GPTSessionKit

final class SessionReuseTests: XCTestCase {
    func testSearchFindsAssistantAndToolMessagesAcrossSessions() throws {
        let a = CodexSessionSummary(id: "a", sessionID: "a", fileURL: URL(fileURLWithPath: "/missing/a"), title: "A")
        let b = CodexSessionSummary(id: "b", sessionID: "b", fileURL: URL(fileURLWithPath: "/missing/b"), title: "B")
        let result = try SessionFullTextSearch.search(sessions: [a,b], query: "failed timeout", scope: .all) { summary in
            .init(summary: summary, messages: [.init(id: "1", kind: summary.id == "a" ? .assistant : .toolResult,
                text: String(repeating: "x", count: 800) + " FAILED timeout " + String(repeating: "y", count: 800))])
        }
        XCTAssertEqual(result.hits.count, 2)
        XCTAssertNotEqual(result.hits[0].id, result.hits[1].id)
        XCTAssertTrue(result.hits[0].excerpt.contains("FAILED"))
        XCTAssertTrue(result.hits[0].excerpt.count < 400)
        XCTAssertEqual(result.scannedSessions, 2)
    }

    func testScopesLimitsAndUnreadableFilesAreExplicit() throws {
        let a = CodexSessionSummary(id: "a", sessionID: "a", fileURL: URL(fileURLWithPath: "/missing/a"), title: "A")
        let b = CodexSessionSummary(id: "b", sessionID: "b", fileURL: URL(fileURLWithPath: "/missing/b"), title: "B")
        let result = try SessionFullTextSearch.search(sessions: [b,a], query: "error", scope: .tools, maximumHits: 1) { summary in
            if summary.id == "b" { throw NSError(domain: "fixture", code: 1) }
            return .init(summary: summary, messages: [
                .init(id: "u", kind: .user, text: "error"),
                .init(id: "t1", kind: .toolResult, text: "error"),
                .init(id: "t2", kind: .toolResult, text: "error")], warnings: ["partial"])
        }
        XCTAssertEqual(result.hits.map(\.messageID), ["t1"])
        XCTAssertEqual(result.skippedSessions, 1)
        XCTAssertEqual(result.incompleteSessions, 1)
        XCTAssertTrue(result.stoppedAtLimit)
        XCTAssertTrue(SessionSearchScope.errors.includes(.init(id: "e", kind: .assistant, text: "发生错误")))
        XCTAssertFalse(SessionSearchScope.code.includes(.init(id: "n", kind: .assistant, text: "plain text")))
    }

    func testBudgetStopsBeforeReadingAndEmptyQueryDoesNotRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 65, count: 40).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let summary = CodexSessionSummary(id: "s", sessionID: "s", fileURL: url, title: "S")
        var reads = 0
        let result = try SessionFullTextSearch.search(sessions: [summary], query: "a", scope: .all, maximumBytes: 10) {
            reads += 1; return .init(summary: $0)
        }
        XCTAssertTrue(result.stoppedAtLimit)
        XCTAssertEqual(reads, 0)
        let empty = try SessionFullTextSearch.search(sessions: [summary], query: "  ", scope: .all) {
            reads += 1; return .init(summary: $0)
        }
        XCTAssertEqual(empty.hits.count, 0)
        XCTAssertEqual(reads, 0)
    }

    func testHandoffBoundsQuotesAndDoesNotInventCompletion() {
        let summary = CodexSessionSummary(id: "s", sessionID: "session", fileURL: URL(fileURLWithPath: "/fixture/session"), title: "Title", projectPath: "/project")
        var messages = (0..<8).map { SessionMessage(id: "u\($0)", kind: .user, text: "request-\($0)") }
        messages.append(.init(id: "a", kind: .assistant, text: String(repeating: "A", count: 4_000)))
        messages.append(.init(id: "progress", kind: .assistant, text: "已修复启动错误，测试通过。\n下一步：确认生产配置。"))
        messages.append(.init(id: "tool", kind: .toolResult, text: "TOOL-SECRET"))
        let draft = SessionHandoff.draft(transcript: .init(summary: summary, messages: messages, warnings: ["partial"]), note: "note")
        XCTAssertFalse(draft.contains("request-0"))
        XCTAssertTrue(draft.contains("最近用户要求（请确认是否为当前目标）"))
        XCTAssertTrue(draft.contains("request-7"))
        XCTAssertFalse(draft.contains("TOOL-SECRET"))
        XCTAssertTrue(draft.contains("[原文已截断]"))
        XCTAssertTrue(draft.contains("来源消息：progress"))
        XCTAssertTrue(draft.contains("下一步：确认生产配置"))
        XCTAssertTrue(draft.contains("不等于已验证事实"))
        XCTAssertTrue(draft.contains("可能不完整"))
        XCTAssertTrue(draft.count < 5_000)
    }
}
