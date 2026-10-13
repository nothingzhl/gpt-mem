import Foundation
import XCTest
@testable import GPTMemoryCore

final class MemoryCacheTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private func sample(_ id: String, _ seconds: Double, _ bytes: UInt64 = 100) -> MemorySnapshot {
        .init(id: id, capturedAt: origin.addingTimeInterval(seconds), processes: [
            .init(bootID: "cache", pid: 10, parentPID: 1, startTimeTicks: 1,
                  startedAt: origin, executable: "fixture", role: .renderer, footprintBytes: bytes)
        ])
    }
    private func database() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("memory-cache-" + UUID().uuidString)
            .appendingPathComponent("history.sqlite3")
    }

    func testCachedRefreshDecodesOnlyNewSamplesAndRetainsWindowBaseline() throws {
        let url = database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url, decodedCacheByteLimit: 1_048_576)
        try store.save(sample("a", 0)); try store.save(sample("b", 1))
        XCTAssertEqual(try store.load(since: origin).map(\.id), ["a", "b"])
        XCTAssertEqual(store.lastReadMetrics.decodedSnapshots, 2)
        XCTAssertEqual(try store.load(since: origin).map(\.id), ["a", "b"])
        XCTAssertEqual(store.lastReadMetrics.decodedSnapshots, 0)
        XCTAssertEqual(store.lastReadMetrics.reusedSnapshots, 2)
        try store.save(sample("c", 2))
        XCTAssertEqual(try store.load(since: origin).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(store.lastReadMetrics.decodedSnapshots, 1)
        XCTAssertEqual(store.lastReadMetrics.reusedSnapshots, 2)
        XCTAssertEqual(try store.load(since: origin.addingTimeInterval(2)).map(\.id), ["b", "c"])
        try store.save(sample("b", 1, 999))
        XCTAssertEqual(try store.load(since: origin).first(where: { $0.id == "b" })?.totalFootprintBytes, 999)
        XCTAssertThrowsError(try store.load(since: origin, maxSamples: 2))
        XCTAssertEqual(try store.load(since: origin).count, 3)
    }

    func testOtherConnectionUpsertsInvalidateCachedPayloadEvenWithoutTimestampChange() throws {
        let url = database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try MemoryStore(url: url)
        let reader = try MemoryStore(url: url, readOnly: true, decodedCacheByteLimit: 1_048_576)
        try writer.save(sample("a", 0)); try writer.save(sample("b", 1))
        _ = try reader.load(since: origin)
        XCTAssertEqual(reader.lastReadMetrics.decodedSnapshots, 2)
        try writer.save(sample("a", 0, 777))
        let updated = try reader.load(since: origin)
        XCTAssertEqual(updated.first?.totalFootprintBytes, 777)
        XCTAssertEqual(reader.lastReadMetrics.decodedSnapshots, 2)
        _ = try reader.load(since: origin)
        XCTAssertEqual(reader.lastReadMetrics.decodedSnapshots, 0)
        try writer.save(sample("c", 2))
        XCTAssertEqual(try reader.load(since: origin).count, 3)
    }

    func testCacheBudgetAndMaintenanceDoNotChangeResults() throws {
        let url = database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url, decodedCacheByteLimit: 1)
        try store.save(sample("old", -8 * 86400)); try store.save(sample("new", 0))
        XCTAssertEqual(try store.load(since: origin.addingTimeInterval(-9 * 86400)).count, 2)
        XCTAssertEqual(store.lastReadMetrics.cachedPayloadBytes, 0)
        try store.maintenance(now: origin)
        XCTAssertEqual(try store.load(since: origin.addingTimeInterval(-9 * 86400)).map(\.id), ["new"])
        XCTAssertEqual(store.lastReadMetrics.reusedSnapshots, 0)
    }

    func testDecodedHistoryRetainsMetadataAfterTemporaryPoolsDrain() throws {
        let url = database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url, decodedCacheByteLimit: 1_048_576)
        let longPath = "/Applications/" + String(repeating: "测试应用/", count: 40) + "Codex"
        let samples = (0..<24).map { index -> MemorySnapshot in
            var value = sample(String(index), Double(index), UInt64(index + 100))
            value.processes[0].executable = longPath
            value.processes[0].roleHint = "页面渲染角色"
            value.processes[0].rootKey = "birth:777:1800000000000000"
            value.warnings = ["指标缺失的详细说明：" + String(repeating: "保留实际样本。", count: 30)]
            return value
        }
        for value in samples { try store.save(value) }
        let firstRead = try autoreleasepool { try store.load(since: origin) }
        XCTAssertEqual(firstRead, samples)
        XCTAssertEqual(store.lastReadMetrics.decodedSnapshots, samples.count)
        // Exercise retained cached strings and process arrays after the decoder's
        // pool and caller's pool have both drained, including the baseline row.
        let narrowed = try autoreleasepool { try store.load(since: origin.addingTimeInterval(12)) }
        XCTAssertEqual(narrowed, Array(samples[11...]))
        XCTAssertEqual(store.lastReadMetrics.decodedSnapshots, 0)
        XCTAssertEqual(store.lastReadMetrics.reusedSnapshots, 13)
        XCTAssertEqual(firstRead.first?.processes.first?.executable, longPath)
        XCTAssertEqual(firstRead.last?.warnings, samples.last?.warnings)
    }
}
