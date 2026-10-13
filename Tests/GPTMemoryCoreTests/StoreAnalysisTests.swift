import Foundation
import XCTest
@testable import GPTMemoryCore

final class StoreAnalysisTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let mib: UInt64 = 1_024 * 1_024

    private func process(_ pid: Int, _ memoryMiB: UInt64, ticks: UInt64 = 1,
                         boot: String = "boot-a", role: ProcessRole = .renderer) -> ProcessSample {
        ProcessSample(bootID: boot, pid: pid, parentPID: 1, startTimeTicks: ticks,
                      startedAt: origin.addingTimeInterval(-100), executable: "test-process",
                      role: role, footprintBytes: memoryMiB * mib)
    }

    private func snapshot(_ seconds: TimeInterval, _ processes: [ProcessSample],
                          missing: [Int] = [], id: String = UUID().uuidString) -> MemorySnapshot {
        MemorySnapshot(id: id, capturedAt: origin.addingTimeInterval(seconds),
                       processes: processes, unavailablePIDs: missing)
    }

    func testGrowthAccountReconcilesAddExitAndExisting() {
        let a = snapshot(0, [process(10, 100), process(20, 50), process(30, 80)])
        let b = snapshot(60, [process(10, 160), process(30, 60), process(40, 70)])
        let result = MemoryAnalyzer.analyze([b, a])
        XCTAssertEqual(result.startTotalBytes, 230 * mib)
        XCTAssertEqual(result.endTotalBytes, 290 * mib)
        XCTAssertEqual(result.addedContributionBytes, Int64(70 * mib))
        XCTAssertEqual(result.exitedContributionBytes, -Int64(50 * mib))
        XCTAssertEqual(result.existingChangeBytes, Int64(40 * mib))
        XCTAssertEqual(result.totalChangeBytes, Int64(60 * mib))
        XCTAssertEqual(result.unresolvedContributionBytes, 0)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.events.filter { $0.kind == .processAdded }.map(\.pid), [40])
        XCTAssertEqual(result.events.filter { $0.kind == .processExited }.map(\.pid), [20])
    }

    func testPIDReuseIsExitAndNewInstance() {
        let result = MemoryAnalyzer.analyze([
            snapshot(0, [process(10, 100, ticks: 1)]),
            snapshot(60, [process(10, 150, ticks: 2)])
        ])
        XCTAssertEqual(result.addedContributionBytes, Int64(150 * mib))
        XCTAssertEqual(result.exitedContributionBytes, -Int64(100 * mib))
        XCTAssertEqual(result.existingChangeBytes, 0)
        XCTAssertEqual(Set(result.topChanges.map(\.kind)), [.added, .exited])
        XCTAssertEqual(Set(result.topChanges.map(\.key)).count, 2)
    }

    func testMissingEndMeasurementIsNotAnExitOrZero() {
        let result = MemoryAnalyzer.analyze([
            snapshot(0, [process(10, 100), process(20, 50)]),
            snapshot(60, [process(20, 60)], missing: [10])
        ])
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.exitedContributionBytes, 0)
        XCTAssertEqual(result.existingChangeBytes, Int64(10 * mib))
        XCTAssertEqual(result.unresolvedContributionBytes, -Int64(100 * mib))
        let unknown = result.topChanges.first { $0.pid == 10 }
        XCTAssertEqual(unknown?.kind, .unavailableEnd)
        XCTAssertNil(unknown?.endBytes)
        XCTAssertNil(unknown?.deltaBytes)
        XCTAssertFalse(result.events.contains { $0.kind == .processExited && $0.pid == 10 })
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testMissingBaselineIsNotNewProcessContribution() {
        let result = MemoryAnalyzer.analyze([
            snapshot(0, [], missing: [10]), snapshot(60, [process(10, 120)])
        ])
        XCTAssertEqual(result.addedContributionBytes, 0)
        XCTAssertEqual(result.unresolvedContributionBytes, Int64(120 * mib))
        XCTAssertEqual(result.topChanges.first?.kind, .unavailableBaseline)
        XCTAssertNil(result.topChanges.first?.startBytes)
        XCTAssertFalse(result.events.contains { $0.kind == .processAdded })
    }

    func testIntermediateMissingSampleDoesNotInventExitOrAddition() {
        let result = MemoryAnalyzer.analyze([
            snapshot(0, [process(10, 100)]), snapshot(60, [], missing: [10]),
            snapshot(120, [process(10, 120)])
        ])
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.existingChangeBytes, Int64(20 * mib))
        XCTAssertEqual(result.unresolvedContributionBytes, 0)
        XCTAssertFalse(result.events.contains { $0.kind == .processAdded || $0.kind == .processExited })
        XCTAssertEqual(result.events.filter { $0.kind == .measurementUnavailable }.count, 1)
    }

    func testCrossBootReusedPIDDoesNotBecomeOneGrowingProcess() {
        let result = MemoryAnalyzer.analyze([
            snapshot(0, [process(10, 100, boot: "boot-a")]),
            snapshot(60, [process(10, 200, boot: "boot-b")])
        ])
        XCTAssertEqual(result.existingChangeBytes, 0)
        XCTAssertEqual(result.addedContributionBytes, Int64(200 * mib))
        XCTAssertEqual(result.exitedContributionBytes, -Int64(100 * mib))
        XCTAssertTrue(result.events.contains { $0.kind == .bootChanged })
        XCTAssertTrue(result.sustainedGrowthCandidates.isEmpty)
    }

    func testSustainedGrowthNeedsEnoughTimeAndSamples() {
        let samples: [MemorySnapshot] = (0...10).map { index in
            let seconds = Double(index * 60)
            let memory = UInt64(100 + index * 12)
            return snapshot(seconds, [process(10, memory, role: .toolWorker)])
        }
        let result = MemoryAnalyzer.analyze(samples)
        XCTAssertEqual(result.sustainedGrowthCandidates.count, 1)
        XCTAssertEqual(result.sustainedGrowthCandidates.first?.netGrowthBytes, Int64(120 * mib))
        XCTAssertEqual(result.sustainedGrowthCandidates.first?.sampleCount, 11)
        XCTAssertEqual(result.sustainedGrowthCandidates.first?.positiveIncrementFraction, 1)
        XCTAssertTrue(MemoryAnalyzer.analyze(Array(samples.prefix(10))).sustainedGrowthCandidates.isEmpty)
    }

    func testRecentGrowthIsNotHiddenByAnEarlierFlatHour() {
        let samples: [MemorySnapshot] = (0...70).map { index in
            let memory = UInt64(100 + max(0, index - 60) * 12)
            return snapshot(Double(index * 60), [process(10, memory)])
        }
        let result = MemoryAnalyzer.analyze(samples)
        XCTAssertEqual(result.sustainedGrowthCandidates.count, 1)
        XCTAssertEqual(result.sustainedGrowthCandidates.first?.start, origin.addingTimeInterval(3_600))
        XCTAssertEqual(result.sustainedGrowthCandidates.first?.netGrowthBytes, Int64(120 * mib))
    }

    func testRollingWindowUsesBaselineBeforeCutoffWhenSamplingDrifts() {
        let samples: [MemorySnapshot] = (0...70).map { index in
            let seconds = Double(index * 60) + Double(index) * 0.3
            let memory = UInt64(100 + max(0, index - 60) * 12)
            return snapshot(seconds, [process(10, memory)])
        }
        let result = MemoryAnalyzer.analyze(samples)
        XCTAssertEqual(result.sustainedGrowthCandidates.count, 1)
        XCTAssertEqual(result.sustainedGrowthCandidates.first?.start, origin.addingTimeInterval(3_618))
    }

    func testFifteenMinuteWindowFindsSlowerSustainedGrowth() {
        let samples: [MemorySnapshot] = (0...15).map { index in
            let memory = UInt64(100 + index * 7)
            return snapshot(Double(index * 60), [process(10, memory)])
        }
        let result = MemoryAnalyzer.analyze(samples)
        XCTAssertEqual(result.sustainedGrowthCandidates.first?.netGrowthBytes, Int64(105 * mib))
        XCTAssertEqual(result.sustainedGrowthCandidates.first?.sampleCount, 16)
    }

    func testGPUSpikeAndRecoveredRendererAreNotSustainedGrowth() {
        let samples = (0...10).map { index in
            snapshot(Double(index * 60), [process(10, index == 5 ? 500 : 100, role: .gpu),
                                         process(20, index == 5 ? 600 : 120, role: .renderer)])
        }
        let result = MemoryAnalyzer.analyze(samples)
        XCTAssertTrue(result.sustainedGrowthCandidates.isEmpty)
        XCTAssertEqual(result.totalChangeBytes, 0)
    }

    func testLongMonotonicGPUAllocationIsExplicitlyOnlySuspicious() {
        let samples: [MemorySnapshot] = (0...10).map { index in
            let memory = UInt64(100 + index * 20)
            return snapshot(Double(index * 60), [process(10, memory, role: .gpu)])
        }
        let result = MemoryAnalyzer.analyze(samples)
        XCTAssertEqual(result.sustainedGrowthCandidates.first?.role, .gpu)
        XCTAssertTrue(result.warnings.contains { $0.contains("图形资源") })
    }

    func testInterruptedMeasurementsAndSparseHistoryAreNotSustainedGrowth() {
        var samples: [MemorySnapshot] = (0...11).map { index in
            let memory = UInt64(100 + index * 12)
            return snapshot(Double(index * 60), [process(10, memory)])
        }
        samples[5] = snapshot(300, [], missing: [10])
        XCTAssertTrue(MemoryAnalyzer.analyze(samples).sustainedGrowthCandidates.isEmpty)
        let sparse: [MemorySnapshot] = (0...10).map { index in
            let memory = UInt64(100 + index * 20)
            return snapshot(Double(index * 300), [process(10, memory)])
        }
        XCTAssertTrue(MemoryAnalyzer.analyze(sparse).sustainedGrowthCandidates.isEmpty)
    }

    func testAnalysisJSONPreservesSignedReconciliationAndUnknownValues() throws {
        let result = MemoryAnalyzer.analyze([
            snapshot(0, [process(10, 100)]), snapshot(60, [], missing: [10])
        ])
        let encoded = try MemoryJSON.encoder().encode(result)
        let decoded = try MemoryJSON.decoder().decode(MemoryAnalysis.self, from: encoded)
        XCTAssertEqual(decoded.totalChangeBytes, -Int64(100 * mib))
        XCTAssertEqual(decoded.unresolvedContributionBytes, decoded.totalChangeBytes)
        XCTAssertNil(decoded.topChanges.first?.deltaBytes)
    }

    func testStoreRoundTripReadOnlyAndParameterizedID() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = snapshot(0.125, [process(10, 100)], id: "quote'; DROP TABLE snapshots; --")
        do {
            let store = try MemoryStore(url: url)
            try store.save(original)
            XCTAssertEqual(try store.latest(), original)
            // Re-saving the same ID updates a record rather than duplicating history.
            var replacement = original
            replacement.processes = [process(10, 120)]
            try store.save(replacement)
            XCTAssertEqual(try store.load(since: origin.addingTimeInterval(-1)).count, 1)
            XCTAssertEqual(try store.latest(), replacement)
        }
        let reader = try MemoryStore(url: url, readOnly: true)
        XCTAssertEqual(try reader.latest()?.processes.first?.footprintBytes, 120 * mib)
        XCTAssertThrowsError(try reader.save(original))
        XCTAssertThrowsError(try reader.maintenance(now: origin))
    }

    func testReadOnlyMissingDatabaseNeverCreatesFileOrDirectory() {
        let url = temporaryDatabase()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        XCTAssertThrowsError(try MemoryStore(url: url, readOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func testWALReaderObservesCommittedWriterUpdates() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try MemoryStore(url: url)
        try writer.save(snapshot(0, [process(10, 100)], id: "one"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        let reader = try MemoryStore(url: url, readOnly: true)
        XCTAssertEqual(try reader.latest()?.totalFootprintBytes, 100 * mib)
        try writer.save(snapshot(60, [process(10, 120)], id: "two"))
        XCTAssertEqual(try reader.latest()?.totalFootprintBytes, 120 * mib)
        XCTAssertEqual(try reader.load(since: origin).count, 2)
    }

    func testLoadIncludesOnlyMostRecentBaselineAndAscendingRange() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url)
        for seconds in [0, 60, 120, 180] { try store.save(snapshot(Double(seconds), [process(10, UInt64(seconds + 100))])) }
        let loaded = try store.load(since: origin.addingTimeInterval(125))
        XCTAssertEqual(loaded.map(\.capturedAt), [origin.addingTimeInterval(120), origin.addingTimeInterval(180)])
        XCTAssertEqual(try store.load(since: origin.addingTimeInterval(120)).map(\.capturedAt),
                       [origin.addingTimeInterval(60), origin.addingTimeInterval(120), origin.addingTimeInterval(180)])
        XCTAssertEqual(try store.load(since: origin.addingTimeInterval(999)).count, 1)
        XCTAssertEqual(try store.load(since: origin.addingTimeInterval(-1)).count, 4)
    }

    func testLoadLimitIncludesBaselineAndNeverSilentlyTruncates() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url)
        for seconds in [0, 60, 120, 180] { try store.save(snapshot(Double(seconds), [process(10, 100)])) }
        XCTAssertThrowsError(try store.load(since: origin, maxSamples: 3))
        XCTAssertThrowsError(try store.load(since: origin.addingTimeInterval(120), maxSamples: 2))
        XCTAssertThrowsError(try store.load(since: origin, maxSamples: 0))
        XCTAssertEqual(try store.load(since: origin.addingTimeInterval(120), maxSamples: 3).count, 3)
        XCTAssertEqual(try store.load(since: origin.addingTimeInterval(125), maxSamples: 2).count, 2)
    }

    func testRetentionKeepsDayDetailMinuteHistoryAndWeekBoundary() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url)
        let times: [Double] = [-604_801, -604_800, -172_800, -172_790, -172_730, -86_400, -86_399, -60, -50, 0]
        for seconds in times { try store.save(snapshot(seconds, [process(10, 100)], id: String(seconds))) }
        try store.maintenance(now: origin)
        let remaining = try store.load(since: origin.addingTimeInterval(-1_000_000))
        XCTAssertEqual(remaining.map { $0.capturedAt.timeIntervalSince(origin) },
                       [-604_800, -172_790, -172_730, -86_400, -86_399, -60, -50, 0])
        // Maintenance is idempotent and retained historical samples still work as baselines.
        try store.maintenance(now: origin)
        XCTAssertEqual(try store.load(since: origin.addingTimeInterval(-1_000_000)), remaining)
        XCTAssertEqual(try store.load(since: origin.addingTimeInterval(-100_000)).first?.capturedAt,
                       origin.addingTimeInterval(-172_730))
    }

    func testEmptyStoreAndEmptyAnalysisAreExplicit() throws {
        let url = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try MemoryStore(url: url)
        XCTAssertNil(try store.latest())
        XCTAssertTrue(try store.load(since: origin).isEmpty)
        let result = MemoryAnalyzer.analyze([])
        XCTAssertFalse(result.isComplete)
        XCTAssertNil(result.start)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gpt-mem-tests-\(UUID().uuidString)")
            .appendingPathComponent("history.sqlite3")
    }
}
