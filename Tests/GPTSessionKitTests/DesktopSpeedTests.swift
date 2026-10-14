import Foundation
import XCTest
@testable import GPTSessionKit

final class DesktopSpeedTests: XCTestCase {
    private func event(_ second: Int, _ type: String, _ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["timestamp": String(format: "2026-10-14T00:00:%02d.000Z", second), "type": type, "payload": payload])
    }
    private func usage(_ second: Int, total: Int, last: Int, reasoning: Int = 0) throws -> Data {
        try event(second, "event_msg", ["type": "token_count", "info": ["total_token_usage": ["output_tokens": total, "reasoning_output_tokens": reasoning], "last_token_usage": ["output_tokens": last, "reasoning_output_tokens": reasoning]]])
    }
    private func parser(origin: String = "Codex Desktop") throws -> DesktopSpeedParser {
        var p = DesktopSpeedParser()
        p.consume(try event(0, "session_meta", ["id": "fixture", "originator": origin]), identity: "meta")
        p.consume(try event(0, "turn_context", ["model": "model-A"]), identity: "context")
        p.consume(try event(0, "event_msg", ["type": "task_started", "turn_id": "turn"]), identity: "start")
        return p
    }
    func testCumulativeDeltasDuplicatesAndFirstIntervalUseWallTime() throws {
        var p = try parser()
        p.consume(try usage(10, total: 100, last: 100, reasoning: 20), identity: "a")
        p.consume(try usage(15, total: 100, last: 100, reasoning: 20), identity: "duplicate")
        p.consume(try usage(20, total: 300, last: 200, reasoning: 50), identity: "b")
        XCTAssertEqual(p.rows.count, 2)
        XCTAssertEqual(p.rows[0].intervalRate, 10)
        XCTAssertEqual(p.rows[1].intervalRate, 20)
        XCTAssertEqual(p.rows[1].seconds, 10)
        XCTAssertEqual(p.rows[1].reasoning, 30)
        XCTAssertTrue(p.rows[0].firstInTurn); XCTAssertFalse(p.rows[1].firstInTurn)
    }
    func testCLIOrMissingStartDoesNotInventDesktopSpeed() throws {
        var cli = try parser(origin: "codex_cli_rs")
        cli.consume(try usage(10, total: 100, last: 100), identity: "a")
        XCTAssertTrue(cli.rows.isEmpty)
        var p = try parser()
        p.consume(try event(5, "event_msg", ["type": "task_complete", "turn_id": "turn"]), identity: "end")
        p.consume(try usage(10, total: 100, last: 100), identity: "a")
        p.consume(try usage(20, total: 20, last: 20), identity: "reset")
        p.consume(try usage(30, total: 40, last: 20), identity: "b")
        XCTAssertTrue(p.rows.isEmpty)
    }
    func testDuplicateStartModelSwitchAndCounterResetAreConservative() throws {
        var p = try parser()
        p.consume(try event(5, "event_msg", ["type": "task_started", "turn_id": "turn"]), identity: "repeat")
        p.consume(try usage(10, total: 100, last: 100), identity: "a")
        XCTAssertEqual(p.rows[0].seconds, 10)
        p.consume(try event(11, "turn_context", ["model": "model-B"]), identity: "switch")
        p.consume(try usage(20, total: 200, last: 100), identity: "mixed")
        p.consume(try usage(30, total: 300, last: 100), identity: "b")
        XCTAssertEqual(p.rows.count, 2); XCTAssertEqual(p.rows[1].model, "model-B")
        p.consume(try usage(40, total: 10, last: 10), identity: "reset")
        XCTAssertEqual(p.rows.count, 2); XCTAssertFalse(p.warnings.isEmpty)
    }
    func testInheritedTotalsWithoutBaselineDoNotProduceFirstRate() throws {
        var p = try parser()
        p.consume(try usage(10, total: 500, last: 100), identity: "inherited")
        XCTAssertTrue(p.rows.isEmpty)
        p.consume(try usage(20, total: 600, last: 100), identity: "next")
        XCTAssertEqual(p.rows.count, 1); XCTAssertEqual(p.rows[0].output, 100)
        XCTAssertFalse(p.rows[0].firstInTurn)
        XCTAssertFalse(p.warnings.isEmpty)
    }
    func testChunkBoundariesAndOversizedLinesKeepFollowingUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speed-chunks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions/2026/10/14")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("fixture.jsonl")
        var data = Data()
        for line in [try event(0, "session_meta", ["originator": "Codex Desktop"]), try event(0, "turn_context", ["model": "A"]), try event(0, "event_msg", ["type": "task_started"])] { data.append(line); data.append(10) }
        // A valid large line spans a read boundary; the following oversized line is skipped.
        let large = try event(5, "event_msg", ["type": "agent_message", "message": String(repeating: "x", count: 1_048_000)])
        for _ in 0..<2 { data.append(large); data.append(10) }
        data.append(try event(5, "event_msg", ["type": "agent_message", "message": String(repeating: "x", count: 2_100_000)])); data.append(10)
        data.append(try usage(10, total: 100, last: 100)); data.append(10)
        try data.write(to: file)
        let reader = DesktopSpeedReader(rootURL: root), now = Date(timeIntervalSince1970: 1791936010)
        var snapshot = try reader.read(now: now)
        XCTAssertEqual(snapshot.pendingFiles, 1)
        var warnings = snapshot.warnings
        for _ in 0..<4 where snapshot.pendingFiles > 0 { snapshot = try reader.read(now: now); warnings += snapshot.warnings }
        XCTAssertEqual(snapshot.pendingFiles, 0)
        XCTAssertEqual(snapshot.samples.count, 1)
        XCTAssertEqual(snapshot.samples.first?.intervalRate, 10)
        XCTAssertTrue(warnings.contains { $0.contains("1 MiB") })
        XCTAssertEqual(try reader.read(now: now).samples, snapshot.samples)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testIncrementalReaderWaitsForNewlineAndTracksTruncationWithoutSourceWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speed-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions/2026/10/14")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("fixture.jsonl")
        let lines = [try event(0, "session_meta", ["originator": "Codex Desktop", "id": "fixture"]), try event(0, "turn_context", ["model": "A"]), try event(0, "event_msg", ["type": "task_started"])]
        var data = Data(); for line in lines { data.append(line); data.append(10) }
        let partial = try usage(10, total: 100, last: 100); data.append(partial)
        try data.write(to: file)
        let reader = DesktopSpeedReader(rootURL: root), now = Date(timeIntervalSince1970: 1791936010)
        XCTAssertTrue(try reader.read(now: now).samples.isEmpty)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data([10])); try handle.close()
        data.append(10)
        let first = try reader.read(now: now)
        XCTAssertEqual(first.samples.count, 1)
        XCTAssertEqual(try reader.read(now: now).samples, first.samples)
        XCTAssertEqual(try Data(contentsOf: file), data)
        try Data("{}\n".utf8).write(to: file)
        XCTAssertTrue(try reader.read(now: now).samples.isEmpty)
    }
}
