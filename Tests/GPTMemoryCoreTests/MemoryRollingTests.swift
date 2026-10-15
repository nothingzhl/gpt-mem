import Foundation
import XCTest
@testable import GPTMemoryCore

final class MemoryRollingTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testOwnerAdvanceMatchesSQLiteBaselineAndFullAnalysisIncludingGaps() throws {
        let url = database()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url)
        for index in 0...20 { try store.save(snapshot(index)) }
        var state = MemoryHistoryState()
        XCTAssertTrue(state.refresh { try store.load(since: origin.addingTimeInterval(300)) })
        let encoder = MemoryJSON.encoder()
        for index in 21...50 {
            let saved = snapshot(index)
            try store.save(saved)
            let since = saved.capturedAt.addingTimeInterval(-600)
            XCTAssertTrue(state.advance(saved: saved, since: since))
            let expected = try store.load(since: since)
            XCTAssertEqual(state.snapshots, expected)
            XCTAssertEqual(try encoder.encode(XCTUnwrap(state.analysis)),
                           try encoder.encode(MemoryAnalyzer.analyze(expected)))
        }
        XCTAssertTrue(state.advance(saved: nil, since: origin.addingTimeInterval(4_000)))
        XCTAssertEqual(state.snapshots, try store.load(since: origin.addingTimeInterval(4_000)))
        XCTAssertEqual(state.snapshots.count, 1)
        XCTAssertNil(state.analysis)
    }

    func testAdvanceKeepsTimestampTieOrderAndRejectsOverflowWithoutTruncation() throws {
        var state = MemoryHistoryState()
        var first = snapshot(0); first.id = "z"
        XCTAssertTrue(state.refresh { [first] })
        var tied = snapshot(0); tied.id = "a"
        XCTAssertTrue(state.advance(saved: tied, since: origin, maxSamples: 2))
        XCTAssertEqual(state.snapshots.map(\.id), ["a", "z"])
        let original = state.snapshots
        let revision = state.revision
        XCTAssertFalse(state.advance(saved: snapshot(1), since: origin, maxSamples: 2))
        XCTAssertEqual(state.snapshots, original)
        XCTAssertEqual(state.revision, revision)
        XCTAssertTrue(state.loadError?.contains("没有截断") == true)
        XCTAssertTrue(state.advance(saved: snapshot(1), since: origin.addingTimeInterval(1), maxSamples: 2))
        XCTAssertEqual(state.snapshots.map(\.id), ["z", "1"])
        XCTAssertNil(state.loadError)
    }

    func testDataVersionDistinguishesOwnWritesAndOtherConnectionUpserts() throws {
        let url = database()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try MemoryStore(url: url)
        try writer.save(snapshot(0))
        let reader = try MemoryStore(url: url, readOnly: true)
        let ownVersion = try writer.dataVersion()
        let readerVersion = try reader.dataVersion()
        try writer.save(snapshot(1))
        XCTAssertEqual(try writer.dataVersion(), ownVersion)
        XCTAssertNotEqual(try reader.dataVersion(), readerVersion)
        let external = try MemoryStore(url: url)
        var changed = snapshot(0); changed.warnings = ["updated without changing timestamp"]
        try external.save(changed)
        XCTAssertNotEqual(try writer.dataVersion(), ownVersion)
        XCTAssertEqual(try writer.load(since: origin).first?.warnings, changed.warnings)
    }

    func testMovingSavedBaselineRequiresReloadAndRecoversItsDiscardedPredecessor() throws {
        let url = database()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url)
        for index in 0...10 { try store.save(snapshot(index)) }
        let since = origin.addingTimeInterval(300)
        var state = MemoryHistoryState()
        XCTAssertTrue(state.refresh { try store.load(since: since) })
        XCTAssertEqual(state.snapshots.first?.id, "4")
        let original = state.snapshots
        var moved = try XCTUnwrap(original.first)
        moved.capturedAt = origin.addingTimeInterval(700)
        try store.save(moved)
        XCTAssertFalse(state.advance(saved: moved, since: since))
        XCTAssertEqual(state.snapshots, original)
        XCTAssertTrue(state.loadError?.contains("基线") == true)
        XCTAssertTrue(state.refresh { try store.load(since: since) })
        XCTAssertEqual(state.snapshots.first?.id, "3")
        XCTAssertEqual(state.snapshots.last?.id, "4")
        XCTAssertNil(state.loadError)
    }

    func testOutOfOrderOwnerSamplesMatchSQLiteWhileCutoffMovesForward() throws {
        let url = database()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url)
        for index in 0...10 { try store.save(snapshot(index)) }
        let since = origin.addingTimeInterval(300)
        var state = MemoryHistoryState()
        XCTAssertTrue(state.refresh { try store.load(since: since) })
        for (index, seconds) in [250.0, 100.0, 550.0, 360.0].enumerated() {
            var saved = snapshot(index + 20)
            saved.capturedAt = origin.addingTimeInterval(seconds)
            try store.save(saved)
            let cutoff = since.addingTimeInterval(Double(index))
            XCTAssertTrue(state.advance(saved: saved, since: cutoff))
            XCTAssertEqual(state.snapshots, try store.load(since: cutoff))
        }
    }

    func testMaintenanceReportsCommittedDeletionAndNoOp() throws {
        let url = database()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url)
        var old = snapshot(0); old.capturedAt = origin.addingTimeInterval(-8 * 86_400)
        try store.save(old); try store.save(snapshot(1))
        XCTAssertEqual(try store.maintenance(now: origin), 1)
        XCTAssertEqual(try store.maintenance(now: origin), 0)
    }

    func testMetadataPoolingKeepsLiteralUnicodeBytesAndAllSerializedMetrics() throws {
        var composed = snapshot(0)
        composed.processes[0].executable = "/fixture/\u{e9}/process-metadata"
        var decomposed = snapshot(1)
        decomposed.processes[0].executable = "/fixture/e\u{301}/process-metadata"
        XCTAssertEqual(composed.processes[0].executable, decomposed.processes[0].executable)
        let originalBytes = Array(decomposed.processes[0].executable.utf8)
        var metadata = MemoryProcessMetadataPool()
        metadata.canonicalize(&composed)
        metadata.canonicalize(&decomposed)
        XCTAssertEqual(Array(decomposed.processes[0].executable.utf8), originalBytes)
        let url = database()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url)
        try store.save(composed); try store.save(decomposed)
        let loaded = try store.load(since: origin)
        XCTAssertEqual(Array(loaded[1].processes[0].executable.utf8), originalBytes)
        XCTAssertEqual(try MemoryJSON.encoder().encode(loaded), try MemoryJSON.encoder().encode([composed, decomposed]))
    }

    func testUniqueMetadataPoolHasIndependentEntryAndByteLimits() {
        var metadata = MemoryProcessMetadataPool()
        var value = snapshot(0)
        for index in 0..<2_100 {
            value.processes[0].executable = "/fixture/" + String(index) + String(repeating: "x", count: 32)
            let original = value.processes[0].executable
            metadata.canonicalize(&value)
            XCTAssertEqual(value.processes[0].executable, original)
        }
        XCTAssertEqual(metadata.cachedStringCount, 2_048)
        XCTAssertLessThanOrEqual(metadata.cachedStringBytes, 4 * 1_024 * 1_024)
        var large = MemoryProcessMetadataPool()
        for index in 0..<50 {
            value.processes[0].executable = String(index) + String(repeating: "x", count: 100_000)
            large.canonicalize(&value)
        }
        XCTAssertLessThanOrEqual(large.cachedStringBytes, 4 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(large.cachedStringCount, 2_048)
    }

    private func snapshot(_ index: Int) -> MemorySnapshot {
        let process = ProcessSample(bootID: "rolling", pid: 10, parentPID: 1, startTimeTicks: 1,
            startedAt: origin, executable: "fixture", role: .renderer,
            footprintBytes: UInt64(100 + index * 12) * 1_048_576)
        return .init(id: String(index), capturedAt: origin.addingTimeInterval(Double(index * 60)),
            processes: index == 28 ? [] : [process], unavailablePIDs: index == 28 ? [10] : [],
            warnings: index == 28 ? ["fixture gap"] : [])
    }

    private func database() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("memory-rolling-" + UUID().uuidString)
            .appendingPathComponent("history.sqlite3")
    }
}
