import Foundation
import XCTest
@testable import GPTSessionKit

final class SessionAnalyticsTests: XCTestCase {
    func testSameProjectNamesStaySeparateAndUnknownProjectDoesNotCollide() throws {
        let analysis = SessionAnalytics(sessions: [
            session("a", path: "/work/one/shared", model: "model-a", messages: 2, tools: 3, updated: date("2026-10-10T00:00:00Z")),
            session("b", path: "/work/two/shared", model: "model-b", updated: date("2026-10-11T00:00:00Z")),
            session("c", path: nil, model: nil, updated: date("2026-10-09T00:00:00Z")),
            session("d", path: "/unknown-project", updated: date("2026-10-08T00:00:00Z"))
        ])
        XCTAssertEqual(analysis.projects.count, 4)
        XCTAssertEqual(analysis.projects.map(\.id), ["/work/two/shared", "/work/one/shared", SessionProjectSummary.unknownID, "/unknown-project"])
        XCTAssertEqual(analysis.projects.filter { $0.displayName == "shared" }.count, 2)
        let first = try XCTUnwrap(analysis.projects.first { $0.id == "/work/one/shared" })
        XCTAssertEqual(first.sessionCount, 1)
        XCTAssertEqual(first.messageCount, 2)
        XCTAssertEqual(first.toolCallCount, 3)
        XCTAssertEqual(first.lastActivity, date("2026-10-10T00:00:00Z"))
        let unknown = try XCTUnwrap(analysis.projects.first { $0.id == SessionProjectSummary.unknownID })
        XCTAssertNil(unknown.projectPath)
        XCTAssertEqual(unknown.displayName, "未知项目")
        XCTAssertEqual(unknown.modelCount, 0)
    }

    func testKnownUsageRemainsLowerBoundAndSubsetsAreNotAddedTwice() throws {
        let analysis = SessionAnalytics(sessions: [
            session("known", usage: .init(input: 100, cachedInput: 80, output: 30, reasoningOutput: 20)),
            session("unknown"),
            session("partial", usage: .init(input: 9)),
            session("zero", usage: .init(input: 0, output: 0, total: 0))
        ])
        XCTAssertEqual(analysis.tokens.input, 109)
        XCTAssertEqual(analysis.tokens.cachedInput, 80)
        XCTAssertEqual(analysis.tokens.output, 30)
        XCTAssertEqual(analysis.tokens.reasoningOutput, 20)
        XCTAssertEqual(analysis.tokens.total, 130)
        XCTAssertEqual(analysis.tokens.effectiveTotal, 130)
        XCTAssertEqual(analysis.sessionsWithUsage, 2)
        XCTAssertEqual(analysis.totalSessionCount, 4)
        XCTAssertFalse(analysis.hasTokenOverflow)
        XCTAssertEqual(try XCTUnwrap(analysis.projects.first).missingUsageSessionCount, 2)
        XCTAssertEqual(try XCTUnwrap(analysis.models.first).missingUsageSessionCount, 2)
    }

    func testMissingComponentsAcrossDifferentSessionsCannotInventTotal() {
        let partials: [CodexTokenUsage] = [.init(input: 10), .init(output: 20)]
        let sum = CodexTokenUsage.aggregate(partials)
        XCTAssertEqual(sum.input, 10)
        XCTAssertEqual(sum.output, 20)
        XCTAssertNil(sum.total)
        XCTAssertNil(sum.effectiveTotal)
        let analysis = SessionAnalytics(sessions: partials.enumerated().map { session("p\($0.offset)", usage: $0.element) })
        XCTAssertEqual(analysis.tokens.input, 10)
        XCTAssertEqual(analysis.tokens.output, 20)
        XCTAssertNil(analysis.tokens.effectiveTotal)
        XCTAssertEqual(analysis.sessionsWithUsage, 0)
        XCTAssertEqual(analysis.projects.first?.missingUsageSessionCount, 2)
    }

    func testOverflowNeverFallsBackToSmallComponentsAndKeepsKnownFields() {
        let first = CodexTokenUsage(input: 1, output: 1, total: .max)
        let second = CodexTokenUsage(input: 1, output: 1, total: 1)
        let sum = CodexTokenUsage.aggregate([first, second])
        XCTAssertEqual(sum.input, 2)
        XCTAssertEqual(sum.output, 2)
        XCTAssertNil(sum.total)
        XCTAssertNil(sum.effectiveTotal)
        let analysis = SessionAnalytics(sessions: [session("max", usage: first), session("one", usage: second)])
        XCTAssertTrue(analysis.hasTokenOverflow)
        XCTAssertTrue(analysis.projects.first?.hasTokenOverflow == true)
        XCTAssertTrue(analysis.models.first?.hasTokenOverflow == true)
        XCTAssertNil(analysis.tokens.effectiveTotal)
        XCTAssertEqual(analysis.tokens.input, 2)
        let derivedOverflow = SessionAnalytics(sessions: [session("derived", usage: .init(input: .max, output: 1))])
        XCTAssertTrue(derivedOverflow.hasTokenOverflow)
        XCTAssertNil(derivedOverflow.tokens.effectiveTotal)
        XCTAssertEqual(derivedOverflow.sessionsWithUsage, 0)
        let nested = CodexTokenUsage.aggregate([sum, .init(input: 4, output: 6, total: 10)])
        XCTAssertNil(nested.effectiveTotal)
        XCTAssertEqual(nested.input, 6)
        let preaggregated = SessionAnalytics(sessions: [session("incremental-fallback", usage: nested)])
        XCTAssertTrue(preaggregated.hasTokenOverflow)
        XCTAssertNil(preaggregated.tokens.effectiveTotal)
        let componentOverflow = CodexTokenUsage.aggregate([.init(input: .max, total: 1), .init(input: 1, total: 1)])
        let componentNested = CodexTokenUsage.aggregate([componentOverflow, .init(input: 2, total: 1)])
        XCTAssertNil(componentNested.input)
        XCTAssertEqual(componentNested.effectiveTotal, 3)
    }

    func testModelGroupingCountsDistinctRecordedModelsAndRespectsProvidedArchiveFilter() throws {
        let values = [session("a", model: "model-one", usage: .init(total: 100)),
                      session("b", model: "model-two", usage: .init(total: 20)),
                      session("c", model: "model-one", archived: true),
                      session("d", model: nil)]
        let all = SessionAnalytics(sessions: values)
        XCTAssertEqual(all.projects.first?.modelCount, 2)
        XCTAssertEqual(all.models.first?.name, "model-one")
        XCTAssertEqual(all.models.first?.sessionCount, 2)
        XCTAssertEqual(all.models.first?.missingUsageSessionCount, 1)
        XCTAssertEqual(all.models.first?.tokens.effectiveTotal, 100)
        XCTAssertEqual(all.models.first { $0.id == SessionModelSummary.unknownID }?.name, "未知模型")
        let active = SessionAnalytics(sessions: values.filter { !$0.isArchived })
        XCTAssertEqual(active.totalSessionCount, 3)
        XCTAssertEqual(active.models.first { $0.name == "model-one" }?.sessionCount, 1)
        XCTAssertEqual(active.tokens.effectiveTotal, 120)
    }

    func testActivityBucketsStartDatesInShanghaiAndIgnoresLaterFileUpdates() {
        let analysis = SessionAnalytics(sessions: [
            session("before-midnight", started: date("2026-10-10T15:59:59Z"), updated: date("2026-11-01T00:00:00Z")),
            session("at-midnight", started: date("2026-10-10T16:00:00Z"), updated: date("2026-11-02T00:00:00Z")),
            session("after-gap", started: date("2026-10-12T16:00:00Z"), updated: date("2026-11-03T00:00:00Z")),
            session("missing", started: nil, updated: date("2026-11-04T00:00:00Z"))
        ])
        XCTAssertEqual(analysis.activity.map(\.id), ["2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13"])
        XCTAssertEqual(analysis.activity.map(\.sessionCount), [1, 1, 0, 1])
        XCTAssertEqual(analysis.activity.first?.date, date("2026-10-09T16:00:00Z"))
        XCTAssertEqual(analysis.missingStartDateCount, 1)
        XCTAssertEqual(analysis.activityWindowExcludedSessionCount, 0)
    }

    func testActivityWindowIsBoundedAndAnchoredToRecordedDateRatherThanNow() {
        let analysis = SessionAnalytics(sessions: [
            session("old", started: date("2020-01-01T00:00:00Z")),
            session("latest", started: date("2020-02-10T00:00:00Z")),
            session("latest-2", started: date("2020-02-10T01:00:00Z"))
        ])
        XCTAssertEqual(analysis.activity.count, 30)
        XCTAssertEqual(analysis.activity.first?.id, "2020-01-12")
        XCTAssertEqual(analysis.activity.last?.id, "2020-02-10")
        XCTAssertEqual(analysis.activity.last?.sessionCount, 2)
        XCTAssertEqual(analysis.activityWindowExcludedSessionCount, 1)
        let oneDay = SessionAnalytics(sessions: [session("fixture", started: date("2020-01-01T00:00:00Z"))], activityDayLimit: 0)
        XCTAssertEqual(oneDay.activity.count, 1)
    }

    func testEmptyAndMissingUsageRemainUnknownWhileRecordedZeroStaysZero() {
        let empty = SessionAnalytics(sessions: [])
        XCTAssertTrue(empty.projects.isEmpty)
        XCTAssertTrue(empty.models.isEmpty)
        XCTAssertTrue(empty.activity.isEmpty)
        XCTAssertNil(empty.tokens.effectiveTotal)
        XCTAssertEqual(empty.totalSessionCount, 0)
        XCTAssertEqual(empty.sessionsWithUsage, 0)
        XCTAssertFalse(empty.hasTokenOverflow)
        let unknown = SessionAnalytics(sessions: [session("unknown")])
        XCTAssertNil(unknown.tokens.input)
        XCTAssertNil(unknown.tokens.effectiveTotal)
        XCTAssertEqual(unknown.missingStartDateCount, 1)
        let zero = SessionAnalytics(sessions: [session("zero", usage: .init(total: 0))])
        XCTAssertEqual(zero.tokens.effectiveTotal, 0)
        XCTAssertEqual(zero.sessionsWithUsage, 1)
        XCTAssertEqual(zero.projects.first?.missingUsageSessionCount, 0)
        XCTAssertNil(CodexTokenUsage(input: -1, output: 2).effectiveTotal)
        XCTAssertNil(CodexTokenUsage(total: -1).effectiveTotal)
        let invalid = CodexTokenUsage.aggregate([.init(input: -1, total: -1), .init(total: 0)])
        XCTAssertNil(invalid.input)
        XCTAssertEqual(invalid.effectiveTotal, 0)
    }

    func testTokenOverflowCanBeReadByDownstreamPerFieldAggregators() {
        let aggregate = CodexTokenUsage.aggregate([.init(input:.max,output:1,total:2),.init(input:1,output:1,total:3)])
        XCTAssertTrue(aggregate.hasOverflow(for:\.input))
        XCTAssertFalse(aggregate.hasOverflow(for:\.output))
        XCTAssertFalse(aggregate.hasOverflow(for:\.effectiveTotal))
        let derived = CodexTokenUsage(input:.max,output:1)
        XCTAssertTrue(derived.hasOverflow(for:\.effectiveTotal))
        XCTAssertFalse(derived.hasOverflow(for:\.input))
        XCTAssertFalse(derived.hasOverflow(for:\.total))
        let total = CodexTokenUsage.aggregate([.init(input:1,output:1,total:.max),.init(total:1)])
        XCTAssertTrue(total.hasOverflow(for:\.total))
        XCTAssertTrue(total.hasOverflow(for:\.effectiveTotal))
    }

    private func session(_ id: String, path: String? = "/synthetic/project", model: String? = "test-model",
                         usage: CodexTokenUsage = .init(), messages: Int = 0, tools: Int = 0,
                         started: Date? = nil, updated: Date = Date(timeIntervalSince1970: 0),
                         archived: Bool = false) -> CodexSessionSummary {
        .init(id: id, sessionID: id, fileURL: URL(fileURLWithPath: "/synthetic/\(id).jsonl"), title: id,
              projectPath: path, startedAt: started, updatedAt: updated, model: model,
              messageCount: messages, toolCallCount: tools, tokens: usage, isArchived: archived)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
