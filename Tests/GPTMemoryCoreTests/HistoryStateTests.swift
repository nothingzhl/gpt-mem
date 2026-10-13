import Foundation
import XCTest
@testable import GPTMemoryCore

final class HistoryStateTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let mib: UInt64 = 1_024 * 1_024

    func testOneSecondTwoHourHistoryPreservesSamplesAndSurvivesLoadFailure() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url)
        // Reuse one real SQLite fixture for the desktop window, guard boundary,
        // failed refresh, and recovery so each scenario observes the same history.
        for seconds in 0...10_000 {
            var processes = [process(10, 100 * mib + UInt64(seconds) * 1_024)]
            if seconds == 5_000 { processes.append(process(20, 30 * mib)) }
            if seconds == 6_000 { processes = [] }
            try store.save(MemorySnapshot(id: String(seconds), capturedAt: date(seconds),
                                          processes: processes,
                                          unavailablePIDs: seconds == 6_000 ? [10] : [],
                                          warnings: seconds == 6_000 ? ["fixture measurement unavailable"] : []))
        }

        var state = MemoryHistoryState()
        state.refresh { try store.load(since: date(2_800)) }
        XCTAssertNil(state.loadError)
        XCTAssertEqual(state.snapshots.count, 7_202)
        XCTAssertEqual(state.snapshots.map(\.id), (2_799...10_000).map { String($0) })
        XCTAssertEqual(state.snapshots.first?.capturedAt, date(2_799))
        XCTAssertEqual(state.snapshots.last?.capturedAt, date(10_000))
        let analysis = try XCTUnwrap(state.analysis)
        XCTAssertEqual(analysis.sampleCount, 7_202)
        XCTAssertEqual(analysis.start, date(2_799))
        XCTAssertEqual(analysis.end, date(10_000))
        XCTAssertEqual(analysis.totalChangeBytes, Int64(7_201 * 1_024))

        // The large window must retain individual additions/exits and an unknown
        // measurement; silent truncation or resampling could hide these events.
        let missing = try XCTUnwrap(state.snapshots.first { $0.id == "6000" })
        XCTAssertEqual(missing.unavailablePIDs, [10])
        XCTAssertTrue(missing.processes.isEmpty)
        XCTAssertEqual(missing.warnings, ["fixture measurement unavailable"])
        XCTAssertFalse(analysis.isComplete)
        XCTAssertTrue(analysis.events.contains {
            $0.kind == .processAdded && $0.pid == 20 && $0.capturedAt == date(5_000)
        })
        XCTAssertTrue(analysis.events.contains {
            $0.kind == .processExited && $0.pid == 20 && $0.capturedAt == date(5_001)
        })
        XCTAssertTrue(analysis.events.contains {
            $0.kind == .measurementUnavailable && $0.pid == 10 && $0.capturedAt == date(6_000)
        })
        XCTAssertFalse(analysis.events.contains {
            ($0.kind == .processAdded || $0.kind == .processExited) && $0.pid == 10
        })
        XCTAssertEqual(analysis.events.count, 3)
        XCTAssertTrue(analysis.warnings.contains("fixture measurement unavailable"))

        // The baseline participates in the limit: 9,999 range samples plus one
        // preceding sample are allowed, while one additional row is rejected.
        let atLimit = try store.load(since: date(2))
        XCTAssertEqual(atLimit.count, 10_000)
        XCTAssertEqual(atLimit.first?.id, "1")
        XCTAssertEqual(atLimit.last?.id, "10000")
        XCTAssertThrowsError(try store.load(since: date(1)))

        let cachedSnapshots = state.snapshots
        let cachedAnalysis = try MemoryJSON.encoder().encode(analysis)
        var originalError = ""
        do {
            _ = try store.load(since: date(1))
        } catch {
            originalError = String(describing: error)
        }
        XCTAssertFalse(originalError.isEmpty)
        state.refresh { try store.load(since: date(1)) }
        XCTAssertEqual(state.snapshots, cachedSnapshots)
        XCTAssertEqual(try MemoryJSON.encoder().encode(XCTUnwrap(state.analysis)), cachedAnalysis)
        let failedMessage = try XCTUnwrap(state.loadError)
        XCTAssertTrue(failedMessage.contains(originalError))
        XCTAssertTrue(failedMessage.contains("上次成功"))

        state.refresh { try store.load(since: date(9_998)) }
        XCTAssertNil(state.loadError)
        XCTAssertEqual(state.snapshots.map(\.id), ["9997", "9998", "9999", "10000"])
        XCTAssertEqual(state.analysis?.sampleCount, 4)
        XCTAssertEqual(state.analysis?.start, date(9_997))
        XCTAssertEqual(state.analysis?.end, date(10_000))
        XCTAssertTrue(state.analysis?.isComplete == true)
    }

    func testFirstFailedRefreshKeepsEmptyStateAndOriginalError() {
        var state = MemoryHistoryState()
        XCTAssertTrue(state.snapshots.isEmpty)
        XCTAssertNil(state.analysis)
        XCTAssertNil(state.loadError)

        state.refresh { throw MemoryError.message("fixture database unavailable") }
        XCTAssertTrue(state.snapshots.isEmpty)
        XCTAssertNil(state.analysis)
        XCTAssertTrue(state.loadError?.contains("fixture database unavailable") == true)
        XCTAssertFalse(state.loadError?.contains("上次成功") == true)
    }

    func testSuccessfulEmptyRefreshClearsCachedHistoryAnalysisAndError() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url)
        try store.save(MemorySnapshot(id: "one", capturedAt: date(0), processes: [process(10, 100 * mib)]))
        try store.save(MemorySnapshot(id: "two", capturedAt: date(1), processes: [process(10, 120 * mib)]))
        var state = MemoryHistoryState()
        state.refresh { try store.load(since: origin) }
        XCTAssertEqual(state.snapshots.count, 2)
        XCTAssertEqual(state.analysis?.totalChangeBytes, Int64(20 * mib))
        state.refresh { throw MemoryError.message("fixture database unavailable") }
        XCTAssertFalse(state.loadError == nil)

        let emptyStore = try MemoryStore(url: url.deletingLastPathComponent().appendingPathComponent("empty.sqlite3"))
        state.refresh { try emptyStore.load(since: origin) }
        XCTAssertTrue(state.snapshots.isEmpty)
        XCTAssertNil(state.analysis)
        XCTAssertNil(state.loadError)
    }

    private func process(_ pid: Int, _ bytes: UInt64) -> ProcessSample {
        ProcessSample(bootID: "boot-history", pid: pid, parentPID: 1, startTimeTicks: UInt64(pid),
                      startedAt: origin.addingTimeInterval(-100), executable: "test-process",
                      role: .renderer, footprintBytes: bytes)
    }

    private func date(_ seconds: Int) -> Date { origin.addingTimeInterval(Double(seconds)) }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gpt-mem-history-tests-\(UUID().uuidString)")
            .appendingPathComponent("history.sqlite3")
    }
}
