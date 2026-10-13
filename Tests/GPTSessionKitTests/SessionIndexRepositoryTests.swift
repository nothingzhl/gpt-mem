import Foundation
import XCTest
@testable import GPTSessionKit

final class SessionIndexRepositoryTests: XCTestCase {
    func testRestartReusesSummariesWithoutReadingRolloutsOrSavingToolBodies() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.write("a", "Alpha", extra: [record("event_msg", ["type":"agent_message", "message":"PRIVATE_ASSISTANT_BODY"]),
            record("response_item", ["type":"function_call_output", "call_id":"c", "output":"PRIVATE_TOOL_BODY"])])
        _ = try f.write("b", "Beta")
        let cold = f.repository(); let catalog = try cold.loadCatalog()
        XCTAssertEqual(cold.lastReadMetrics.parsedRolloutFiles, 2)
        let warm = f.repository()
        XCTAssertEqual(try warm.loadCatalog(), catalog)
        XCTAssertEqual(warm.lastReadMetrics.rolloutBytesRead, 0)
        XCTAssertEqual(warm.lastReadMetrics.persistedRolloutFiles, 2)
        XCTAssertEqual(warm.lastReadMetrics.cachedRolloutFiles, 2)
        let stored = try String(contentsOf: f.store().fileURL, encoding: .utf8)
        XCTAssertTrue(stored.contains("Alpha"))
        XCTAssertFalse(stored.contains("PRIVATE_ASSISTANT_BODY"))
        XCTAssertFalse(stored.contains("PRIVATE_TOOL_BODY"))
        XCTAssertTrue(try warm.loadTranscript(for: catalog.sessions.first { $0.sessionID == "a" }!).messages.contains { $0.text == "PRIVATE_TOOL_BODY" })
    }

    func testSameSizeRestoredMtimeEditsAndAtomicReplacementInvalidateDiskIndex() throws {
        let f = try Fixture(); defer { f.remove() }
        let file = try f.write("a", "Alpha")
        _ = try f.repository().loadCatalog()
        let original = try Data(contentsOf: file)
        let date = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        for (text, atomic) in [("Bravo", false), ("Gamma", true)] {
            let changed = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "Alpha", with: text).utf8)
            XCTAssertEqual(changed.count, original.count)
            if atomic { try changed.write(to: file, options: .atomic) }
            else { let handle = try FileHandle(forWritingTo: file); try handle.write(contentsOf: changed); try handle.close() }
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            let repo = f.repository()
            XCTAssertEqual(try repo.loadCatalog().sessions.first?.title, text)
            XCTAssertEqual(repo.lastReadMetrics.parsedRolloutFiles, 1)
            XCTAssertEqual(repo.lastReadMetrics.persistedRolloutFiles, 0)
            let restarted = f.repository()
            XCTAssertEqual(try restarted.loadCatalog().sessions.first?.title, text)
            XCTAssertEqual(restarted.lastReadMetrics.rolloutBytesRead, 0)
        }
    }

    func testAppendDeleteArchiveMoveAndNewFilesAreReconciledAcrossRestart() throws {
        let f = try Fixture(); defer { f.remove() }
        let a = try f.write("a", "Alpha"), b = try f.write("b", "Beta")
        _ = try f.repository().loadCatalog()
        let handle = try FileHandle(forWritingTo: a); try handle.seekToEnd()
        try handle.write(contentsOf: Data((record("event_msg", ["type":"user_message", "message":"Appended question"]) + "\n").utf8)); try handle.close()
        let archive = f.root.appendingPathComponent("archived_sessions/b.jsonl")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: b, to: archive)
        _ = try f.write("c", "New session")
        let repo = f.repository(); let catalog = try repo.loadCatalog()
        XCTAssertEqual(catalog.sessions.count, 3)
        XCTAssertEqual(catalog.sessions.first { $0.sessionID == "a" }?.messageCount, 2)
        XCTAssertTrue(catalog.sessions.first { $0.sessionID == "b" }!.isArchived)
        XCTAssertTrue(catalog.sessions.first { $0.sessionID == "a" }!.matches(query: "Appended"))
        XCTAssertEqual(repo.lastReadMetrics.parsedRolloutFiles, 3)
        try FileManager.default.removeItem(at: a)
        let afterDelete = f.repository(); let remaining = try afterDelete.loadCatalog()
        XCTAssertEqual(Set(remaining.sessions.map(\.sessionID)), Set(["b", "c"]))
        XCTAssertEqual(afterDelete.lastReadMetrics.rolloutBytesRead, 0)
        XCTAssertEqual(try f.store().load().entries.count, 2)
    }

    func testTitleChangesAndRemovalUseRawCachedSummaryWithoutReparsing() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.write("a", "Original prompt")
        let titles = f.root.appendingPathComponent("session_index.jsonl")
        try Data((json(["id":"a", "thread_name":"First rename"]) + "\n").utf8).write(to: titles)
        XCTAssertEqual(try f.repository().loadCatalog().sessions.first?.title, "First rename")
        XCTAssertEqual(try f.store().load().entries.first?.summary.title, "Original prompt")
        try Data((json(["id":"a", "thread_name":"Second rename"]) + "\n").utf8).write(to: titles)
        let renamed = f.repository()
        XCTAssertEqual(try renamed.loadCatalog().sessions.first?.title, "Second rename")
        XCTAssertEqual(renamed.lastReadMetrics.rolloutBytesRead, 0)
        try FileManager.default.removeItem(at: titles)
        let removed = f.repository()
        XCTAssertEqual(try removed.loadCatalog().sessions.first?.title, "Original prompt")
        XCTAssertEqual(removed.lastReadMetrics.rolloutBytesRead, 0)
    }

    func testCatalogBudgetContinuationIsNotPersistedAsComplete() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.write("a", "Question " + String(repeating: "长", count: 200), extra: [record("event_msg", ["type":"token_count", "info":["total_token_usage":["total_tokens":42]]])])
        let limits = SessionReadLimits(maximumCatalogReadBytes: 128)
        let cold = f.repository(limits); _ = try cold.loadCatalog()
        XCTAssertTrue(try f.store(limits).load().entries.isEmpty)
        let restarted = f.repository(limits); _ = try restarted.loadCatalog()
        XCTAssertEqual(restarted.lastReadMetrics.persistedRolloutFiles, 0)
        XCTAssertGreaterThan(restarted.lastReadMetrics.rolloutBytesRead, 0)
        var final = SessionCatalog()
        for _ in 0..<30 {
            final = try restarted.loadCatalog()
            if !final.warnings.contains(where: { $0.contains("本次索引读取达到大小上限") }) { break }
        }
        XCTAssertEqual(final.sessions.first?.tokens.total, 42)
        XCTAssertEqual(try f.store(limits).load().entries.count, 1)
        let warm = f.repository(limits)
        XCTAssertEqual(try warm.loadCatalog(), final)
        XCTAssertEqual(warm.lastReadMetrics.rolloutBytesRead, 0)
    }

    func testDifferentLimitsAndRootsNeverReuseIncompatibleSummaries() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.write("a", "A sufficiently long user prompt")
        _ = try f.repository().loadCatalog()
        let limits = SessionReadLimits(maximumSearchCharacters: 5)
        let limited = f.repository(limits); let catalog = try limited.loadCatalog()
        XCTAssertEqual(limited.lastReadMetrics.parsedRolloutFiles, 1)
        XCTAssertEqual(catalog.sessions.first?.searchText.count, 5)
        XCTAssertNotEqual(f.store().fileURL, f.store(limits).fileURL)
        let other = try Fixture(); defer { other.remove() }
        _ = try other.write("a", "Other root")
        let repo = CodexSessionRepository(rootURL: other.root, indexDirectoryURL: f.index)
        XCTAssertEqual(try repo.loadCatalog().sessions.first?.title, "Other root")
        XCTAssertEqual(repo.lastReadMetrics.persistedRolloutFiles, 0)
        XCTAssertEqual(repo.lastReadMetrics.parsedRolloutFiles, 1)
    }

    func testCorruptIndexRecoversWithoutChangingOriginalLog() throws {
        let f = try Fixture(); defer { f.remove() }
        let file = try f.write("a", "Unchanged source")
        let original = try Data(contentsOf: file)
        _ = try f.repository().loadCatalog()
        try Data("broken cache\n".utf8).write(to: f.store().fileURL)
        let repo = f.repository(); let catalog = try repo.loadCatalog()
        XCTAssertEqual(catalog.sessions.first?.title, "Unchanged source")
        XCTAssertTrue(catalog.warnings.contains { $0.contains("会话索引") })
        XCTAssertEqual(repo.lastReadMetrics.parsedRolloutFiles, 1)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let repaired = f.repository(); XCTAssertEqual(try repaired.loadCatalog().sessions.count, 1)
        XCTAssertEqual(repaired.lastReadMetrics.rolloutBytesRead, 0)
    }

    func testSymlinkedSourceDirectoryNeverRestoresPreviousCachedSessions() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.write("a", "Previously readable")
        _ = try f.repository().loadCatalog()
        let sessions = f.root.appendingPathComponent("sessions")
        let moved = f.base.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: sessions, to: moved)
        try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: moved)
        let result = try f.repository().loadCatalog()
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("符号链接") })
        XCTAssertTrue(try f.store().load().entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("a.jsonl").path))
    }

    func testIncrementalUnknownTotalAndOverflowSurviveRepositoryRestart() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.write("unknown", "Unknown", extra: [increment(["input_tokens":3], second:1), increment(["output_tokens":4], second:2)])
        _ = try f.write("overflow", "Overflow", extra: [increment(["input_tokens":Int.max, "output_tokens":0], second:1), increment(["input_tokens":1, "output_tokens":0], second:2)])
        let original = try f.repository().loadCatalog()
        let warm = f.repository(); let restored = try warm.loadCatalog()
        XCTAssertEqual(restored, original)
        XCTAssertEqual(warm.lastReadMetrics.rolloutBytesRead, 0)
        let unknown = try XCTUnwrap(restored.sessions.first { $0.sessionID == "unknown" })
        XCTAssertEqual(unknown.tokens.input, 3); XCTAssertEqual(unknown.tokens.output, 4)
        XCTAssertNil(unknown.tokens.effectiveTotal)
        let overflow = try XCTUnwrap(restored.sessions.first { $0.sessionID == "overflow" })
        XCTAssertTrue(overflow.tokens.hasOverflow(for: \.input))
        XCTAssertTrue(overflow.tokens.hasOverflow(for: \.effectiveTotal))
        XCTAssertNil(overflow.tokens.effectiveTotal)
    }

    func testCancelledRefreshLeavesPreviousDiskSnapshotAvailable() throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try f.write("a", "Keep cached")
        let first = try f.repository().loadCatalog()
        let bytes = try Data(contentsOf: f.store().fileURL)
        let repo = f.repository(), done = DispatchSemaphore(value: 0), outcome = Outcome()
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            do { _ = try repo.loadCatalog() }
            catch is CancellationError { outcome.cancelled = true }
            catch { outcome.unexpected = true }
            done.signal()
        }
        task.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(outcome.cancelled); XCTAssertFalse(outcome.unexpected)
        XCTAssertEqual(try Data(contentsOf: f.store().fileURL), bytes)
        XCTAssertEqual(try repo.loadCatalog(), first)
        XCTAssertEqual(repo.lastReadMetrics.rolloutBytesRead, 0)
    }

    private final class Outcome: @unchecked Sendable { var cancelled = false; var unexpected = false }
    private func json(_ value: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys), encoding: .utf8)!
    }
    private func record(_ type: String, _ payload: [String: Any]) -> String {
        json(["type":type, "timestamp":"2026-10-13T00:00:00Z", "payload":payload])
    }
    private func increment(_ usage: [String: Any], second: Int) -> String {
        json(["type":"event_msg", "timestamp":"2026-10-13T00:00:0\(second)Z", "payload":["type":"token_count", "info":["last_token_usage":usage]]])
    }
    private struct Fixture {
        let base: URL, root: URL, index: URL
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("gpt-index-repo-\(UUID().uuidString)")
            root = base.appendingPathComponent("codex"); index = base.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        }
        func repository(_ limits: SessionReadLimits = .init()) -> CodexSessionRepository {
            CodexSessionRepository(rootURL: root, limits: limits, indexDirectoryURL: index)
        }
        func store(_ limits: SessionReadLimits = .init()) -> SessionIndexStore { .init(directoryURL: index, rootURL: root, limits: limits) }
        func remove() { try? FileManager.default.removeItem(at: base) }
        func write(_ id: String, _ question: String, extra: [String] = []) throws -> URL {
            let meta: [String: Any] = ["type":"session_meta", "payload":["id":id, "cwd":"/synthetic/project", "model":"synthetic-model"]]
            let user: [String: Any] = ["type":"event_msg", "payload":["type":"user_message", "message":question]]
            let initial = try [meta, user].map { String(data: try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys), encoding: .utf8)! }
            let file = root.appendingPathComponent("sessions/\(id).jsonl")
            try Data((initial + extra).joined(separator:"\n").appending("\n").utf8).write(to: file)
            return file
        }
    }
}
