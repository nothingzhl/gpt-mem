import Foundation
import XCTest
import GPTAnalysisKit
@testable import GPTSessionKit

final class KnowledgeExtractionTests: XCTestCase {
    private func module(project: String? = "/repo") throws -> KnowledgeExtractionModule {
        let summary = CodexSessionSummary(id: "s", sessionID: "session", fileURL: URL(fileURLWithPath: "/fixture"), title: "偏好", projectPath: project)
        return try .init(transcript: .init(summary: summary, messages: [.init(id: "u", kind: .user, text: "请使用中文回答"), .init(id: "t", kind: .toolResult, text: "TOOL_SECRET"), .init(id: "r", kind: .reasoning, text: "REASONING_SECRET")]))
    }
    private func record(_ module: KnowledgeExtractionModule, observations: [AIObservation]) -> AIAnalysisRecord {
        .init(moduleID: module.input.moduleID, moduleTitle: module.input.moduleTitle, providerID: UUID(), providerName: "Mock", model: "fixture", inputFingerprint: String(repeating: "a", count: 64), windowStart: module.input.windowStart, windowEnd: module.input.windowEnd, result: .init(summary: "提取结果", observations: observations, hypotheses: [], nextSteps: [], limitations: ["有限摘录，需要审核"]))
    }
    func testBoundedInputExcludesToolsAndCandidatesAreNeverActivated() throws {
        let value = try module(), json = String(decoding: try value.input.validated(), as: UTF8.self)
        XCTAssertFalse(json.contains("TOOL_SECRET")); XCTAssertFalse(json.contains("REASONING_SECRET")); XCTAssertFalse(json.contains("/repo"))
        let result = record(value, observations: [.init(text: "使用中文回答", evidenceIDs: ["m1"])])
        let drafts = try KnowledgeExtractionModule.drafts(record: result, input: value.input, source: value.source, subjectLabels: value.subjectLabels)
        XCTAssertEqual(drafts.count, 1); XCTAssertEqual(drafts[0].state, .draft); XCTAssertEqual(drafts[0].scope, .project)
        XCTAssertEqual(drafts[0].sources[0].origin, .aiSession); XCTAssertTrue(drafts[0].sources[0].label.contains("原消息：u"))
        try drafts[0].validate()
    }
    func testNoReliableCandidatesCanProduceEmptyResult() throws {
        let value = try module()
        let result = record(value, observations: [])
        XCTAssertTrue(try KnowledgeExtractionModule.drafts(record: result, input: value.input, source: value.source, subjectLabels: value.subjectLabels).isEmpty)
        let memory = AIAnalysisInput(moduleID: "memory", moduleTitle: "内存", promptVersion: "1", guidance: "分析", windowStart: value.input.windowStart, windowEnd: value.input.windowEnd, facts: value.input.facts, subjects: value.input.subjects)
        XCTAssertThrowsError(try result.result.validate(against: memory))
    }
    func testSourceMismatchAndNonMessageEvidenceCannotEnterLibrary() throws {
        let value = try module(), other = try module(project: "/other")
        let result = record(value, observations: [.init(text: "使用中文", evidenceIDs: ["m1"])])
        XCTAssertThrowsError(try KnowledgeExtractionModule.drafts(record: result, input: value.input, source: other.source, subjectLabels: value.subjectLabels))
        let invalid = record(value, observations: [.init(text: "中文", evidenceIDs: ["coverage"])])
        XCTAssertThrowsError(try KnowledgeExtractionModule.drafts(record: invalid, input: value.input, source: value.source, subjectLabels: value.subjectLabels))
        let unknown = record(value, observations: [.init(text: "中文", evidenceIDs: ["missing"])])
        XCTAssertThrowsError(try KnowledgeExtractionModule.drafts(record: unknown, input: value.input, source: value.source, subjectLabels: value.subjectLabels))
    }
    func testMissingOrRelativeProjectUsesSessionScope() throws {
        for path in [nil, "relative"] as [String?] {
            let value = try module(project: path), result = record(value, observations: [.init(text: "中文", evidenceIDs: ["m1"])])
            let draft = try KnowledgeExtractionModule.drafts(record: result, input: value.input, source: value.source, subjectLabels: value.subjectLabels)[0]
            XCTAssertEqual(draft.scope, .session); XCTAssertEqual(draft.projectPath, ""); XCTAssertEqual(draft.sessionID, "session"); try draft.validate()
        }
    }
}
