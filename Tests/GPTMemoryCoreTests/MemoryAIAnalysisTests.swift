import Foundation
import XCTest
@testable import GPTMemoryCore
import GPTAnalysisKit

final class MemoryAIAnalysisTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let mib: UInt64 = 1_048_576
    private let privatePath = "/Users/private-owner/secret-project/private-worker --raw-command-token"
    private let privateBoot = "private-boot-identity-token"

    private func process(_ pid: Int, _ memoryMiB: UInt64, ticks: UInt64 = 774_411_995,
                         role: ProcessRole = .renderer, cpu: Double? = nil,
                         lifecyclePeak: UInt64 = 0) -> ProcessSample {
        ProcessSample(bootID: privateBoot, pid: pid, parentPID: 71_889_993,
                      startTimeTicks: ticks, startedAt: origin.addingTimeInterval(-1_000 + Double(ticks % 100)),
                      executable: privatePath, role: role, roleHint: "private-role-hint-token",
                      rootKey: "private-root-key-token", footprintBytes: memoryMiB * mib,
                      peakFootprintBytes: lifecyclePeak, cpuPercent: cpu)
    }

    private func snapshot(_ seconds: Double, _ processes: [ProcessSample], missing: [Int] = [],
                          system: SystemMemorySample = .init(), id: String = UUID().uuidString) -> MemorySnapshot {
        MemorySnapshot(id: id, capturedAt: origin.addingTimeInterval(seconds), processes: processes,
                       system: system, unavailablePIDs: missing, warnings: ["private-warning-path-token \(privatePath)"])
    }

    private func module(_ snapshots: [MemorySnapshot], context: String = "") -> MemoryAIAnalysisModule {
        MemoryAIAnalysisModule(snapshots: snapshots, analysis: MemoryAnalyzer.analyze(snapshots), context: context)
    }

    private func object(_ value: AIJSONValue) throws -> [String: AIJSONValue] {
        guard case .object(let result) = value else {
            throw MemoryError.message("测试期望 JSON 对象。")
        }
        return result
    }

    private func array(_ value: AIJSONValue) throws -> [AIJSONValue] {
        guard case .array(let result) = value else {
            throw MemoryError.message("测试期望 JSON 数组。")
        }
        return result
    }

    private func fact(_ id: String, input: AIAnalysisInput) throws -> [String: AIJSONValue] {
        try object(try XCTUnwrap(input.facts.first { $0.id == id }).data)
    }

    private func subjectID(pid: Int, ticks: UInt64, module: MemoryAIAnalysisModule) throws -> String {
        let started = ISO8601DateFormatter().string(from: process(pid, 1, ticks: ticks).startedAt)
        return try XCTUnwrap(module.subjectLabels.first {
            $0.value.contains("PID \(pid) ·") && $0.value.hasSuffix(started)
        }?.key)
    }

    private func growingInstanceSnapshots() -> [MemorySnapshot] {
        var result: [MemorySnapshot] = []
        for index in 0...10 {
            let seconds: Double = Double(index * 60)
            let memory: UInt64 = UInt64(100 + index * 12)
            result.append(snapshot(seconds, [process(42, memory, ticks: 1)]))
        }
        return result
    }

    func testAIInputRejectsInsufficientAndMismatchedWindows() throws {
        let single = [snapshot(0, [process(77_119_931, 100)])]
        let sameTime = [snapshot(0, [process(77_119_931, 100)], id: "a"),
                        snapshot(0, [process(77_119_931, 120)], id: "b")]
        for input in [[], single, sameTime] {
            XCTAssertThrowsError(try module(input).makeInput())
        }
        let full = [snapshot(0, [process(77_119_931, 100)]), snapshot(60, [process(77_119_931, 120)])]
        let mismatched = MemoryAIAnalysisModule(snapshots: full, analysis: MemoryAnalyzer.analyze(single))
        XCTAssertThrowsError(try mismatched.makeInput())
    }

    func testAIInputAnonymizesNativeIdentitiesAndKeepsLocalLabels() throws {
        let original = process(77_119_931, 100)
        let snapshots = [snapshot(0, [original]), snapshot(60, [process(77_119_931, 130)])]
        let adapter = module(snapshots, context: "窗口内打开了一个页面。")
        let input = try adapter.makeInput()
        let data = try input.validated()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in [privatePath, privateBoot, original.key, "77119931", "71889993", "774411995",
                          "private-root-key-token", "private-role-hint-token", "private-warning-path-token",
                          ISO8601DateFormatter().string(from: original.startedAt)] {
            XCTAssertFalse(text.contains(forbidden))
        }
        XCTAssertEqual(input.context, "窗口内打开了一个页面。")
        XCTAssertEqual(input.moduleID, "memory")
        XCTAssertEqual(input.subjects.count, 1)
        XCTAssertEqual(input.subjects.first?.id, "p1")
        XCTAssertEqual(input.subjects.first?.label, "页面渲染 p1")
        XCTAssertTrue(try XCTUnwrap(adapter.subjectLabels["p1"]).contains("PID 77119931"))
        XCTAssertTrue(try XCTUnwrap(adapter.subjectLabels["p1"]).contains("启动"))
        XCTAssertEqual(adapter.subjectLabels, adapter.subjectLabels)
        XCTAssertEqual(input, try adapter.makeInput())
        XCTAssertEqual(Set(input.facts.map(\.id)).count, input.facts.count)
        XCTAssertTrue(input.guidance.contains("不能证明对象泄漏"))
        XCTAssertTrue(input.guidance.contains("无法根据这些指标关联具体聊天内容"))
    }

    func testAITenThousandSamplesStayBoundedAndRetainWindowExtrema() throws {
        var snapshots: [MemorySnapshot] = []
        let lifecyclePeak: UInt64 = 999_999_999_999
        for index in 0..<10_000 {
            let memory: UInt64 = index == 4_444 ? 99_999 : (index == 5_555 ? 1 : UInt64(100 + index))
            let sample = process(77_119_931, memory, cpu: index.isMultiple(of: 2) ? 12.5 : nil,
                                 lifecyclePeak: lifecyclePeak)
            let system = SystemMemorySample(physicalBytes: 16 * 1_024 * mib,
                                            compressedPhysicalBytes: index == 6_666 ? 7 * mib : mib,
                                            swapUsedBytes: index == 7_777 ? 9 * mib : 0,
                                            pressureLevel: index == 8_888 ? 4 : 1)
            snapshots.append(snapshot(Double(index), [sample], system: system, id: "sample-\(index)"))
        }
        let input = try module(snapshots).makeInput()
        let trend = try fact("memory.trend", input: input)
        let points = try array(try XCTUnwrap(trend["points"]))
        XCTAssertLessThanOrEqual(points.count, 120)
        XCTAssertGreaterThan(points.count, 100)
        let offsets = try points.map { try object($0)["offsetSeconds"] }
        for offset in [0, 9_999, 4_444, 5_555, 6_666, 7_777, 8_888] {
            XCTAssertTrue(offsets.contains(.number(Double(offset))))
        }
        let totals = try fact("memory.totals", input: input)
        XCTAssertEqual(totals["windowPeakBytes"], .number(Double(99_999 * mib)))
        let subject = try fact("memory.subject.p1", input: input)
        XCTAssertEqual(subject["windowPeakBytes"], .number(Double(99_999 * mib)))
        XCTAssertNotEqual(subject["windowPeakBytes"], .number(Double(lifecyclePeak)))
        let cpu = try object(try XCTUnwrap(subject["cpuPercent"]))
        XCTAssertEqual(cpu["meanObserved"], .number(12.5))
        XCTAssertEqual(cpu["unknownSampleCount"], .number(5_000))
        XCTAssertTrue(try input.validated().count < 128 * 1_024)
        let system = try fact("memory.system", input: input)
        XCTAssertEqual(system["compressedWindowPeakBytes"], .number(Double(7 * mib)))
        XCTAssertEqual(system["swapWindowPeakBytes"], .number(Double(9 * mib)))
    }

    func testAINumericalFactsPreserveOriginalReconciliationAndMissingMetrics() throws {
        let snapshots = [snapshot(0, [process(10, 100), process(20, 200), process(30, 50)]),
                         snapshot(60, [process(10, 150), process(40, 80)], missing: [30])]
        let analysis = MemoryAnalyzer.analyze(snapshots)
        let adapter = MemoryAIAnalysisModule(snapshots: snapshots, analysis: analysis)
        let input = try adapter.makeInput()
        let reconciliation = try fact("memory.reconciliation", input: input)
        XCTAssertEqual(reconciliation["addedContributionBytes"], .number(Double(analysis.addedContributionBytes)))
        XCTAssertEqual(reconciliation["exitedContributionBytes"], .number(Double(analysis.exitedContributionBytes)))
        XCTAssertEqual(reconciliation["existingChangeBytes"], .number(Double(analysis.existingChangeBytes)))
        XCTAssertEqual(reconciliation["unresolvedContributionBytes"], .number(Double(analysis.unresolvedContributionBytes)))
        XCTAssertEqual(reconciliation["totalChangeBytes"], .number(Double(analysis.totalChangeBytes)))
        let id = try subjectID(pid: 30, ticks: 774_411_995, module: adapter)
        let unavailable = try fact("memory.subject.\(id)", input: input)
        XCTAssertEqual(unavailable["stateAtWindowEnd"], .string("unknown"))
        XCTAssertEqual(unavailable["boundaryChangeKind"], .string("unavailableEnd"))
        XCTAssertEqual(unavailable["endBytes"], .null)
        XCTAssertEqual(unavailable["boundaryDeltaBytes"], .null)
        XCTAssertEqual(input.subjects.first { $0.id == id }?.canInspect, false)
        let cpu = try object(try XCTUnwrap(unavailable["cpuPercent"]))
        XCTAssertEqual(cpu["meanObserved"], .null)
        XCTAssertEqual(cpu["maxObserved"], .null)
        let system = try fact("memory.system", input: input)
        XCTAssertEqual(system["compressedBytesChange"], .null)
        XCTAssertEqual(system["pressureAtEnd"], .null)
        let quality = try fact("memory.quality", input: input)
        XCTAssertEqual(quality["isComplete"], .bool(false))
        XCTAssertEqual(quality["unavailableSnapshotCount"], .number(1))
        let exitedID = try subjectID(pid: 20, ticks: 774_411_995, module: adapter)
        XCTAssertEqual(try fact("memory.subject.\(exitedID)", input: input)["stateAtWindowEnd"], .string("exited"))
        XCTAssertEqual(input.subjects.first { $0.id == exitedID }?.canInspect, false)
    }

    func testAIPIDReuseKeepsExitedCandidateSeparateFromReplacement() throws {
        var snapshots = growingInstanceSnapshots()
        snapshots.append(snapshot(660, [process(42, 50, ticks: 2)]))
        let adapter = module(snapshots)
        let input = try adapter.makeInput()
        let oldID = try subjectID(pid: 42, ticks: 1, module: adapter)
        let newID = try subjectID(pid: 42, ticks: 2, module: adapter)
        XCTAssertNotEqual(oldID, newID)
        let old = try fact("memory.subject.\(oldID)", input: input)
        let new = try fact("memory.subject.\(newID)", input: input)
        XCTAssertEqual(old["stateAtWindowEnd"], .string("exited"))
        XCTAssertEqual(old["endBytes"], .null)
        XCTAssertEqual(new["stateAtWindowEnd"], .string("active"))
        XCTAssertEqual(new["startBytes"], .null)
        XCTAssertEqual(input.subjects.first { $0.id == oldID }?.canInspect, false)
        XCTAssertEqual(input.subjects.first { $0.id == newID }?.canInspect, true)
        XCTAssertNotEqual(old["sustainedGrowthCandidate"], .null)
        XCTAssertEqual(new["sustainedGrowthCandidate"], .null)
    }

    func testAIUnavailableCandidateCannotBeInspected() throws {
        var snapshots = growingInstanceSnapshots()
        snapshots.append(snapshot(660, [], missing: [42]))
        let adapter = module(snapshots)
        let input = try adapter.makeInput()
        let id = try subjectID(pid: 42, ticks: 1, module: adapter)
        let subject = try fact("memory.subject.\(id)", input: input)
        XCTAssertEqual(subject["stateAtWindowEnd"], .string("unknown"))
        XCTAssertEqual(subject["endBytes"], .null)
        XCTAssertEqual(input.subjects.first { $0.id == id }?.canInspect, false)
        XCTAssertNotEqual(subject["sustainedGrowthCandidate"], .null)
    }

    func testAIReplacementThenMissingStillProvesOldIdentityExited() throws {
        let snapshots = [snapshot(0, [process(42, 100, ticks: 1)]),
                         snapshot(60, [process(42, 50, ticks: 2)]), snapshot(120, [], missing: [42])]
        let adapter = module(snapshots)
        let input = try adapter.makeInput()
        let oldID = try subjectID(pid: 42, ticks: 1, module: adapter)
        let newID = try subjectID(pid: 42, ticks: 2, module: adapter)
        XCTAssertEqual(try fact("memory.subject.\(oldID)", input: input)["stateAtWindowEnd"], .string("exited"))
        XCTAssertEqual(try fact("memory.subject.\(newID)", input: input)["stateAtWindowEnd"], .string("unknown"))
        XCTAssertFalse(input.subjects.contains { $0.canInspect })
    }

    func testAIUnavailableBaselineIsNotInventedAsZeroOrAdded() throws {
        let snapshots = [snapshot(0, [], missing: [42]), snapshot(60, [process(42, 100, ticks: 1)])]
        let input = try module(snapshots).makeInput()
        let process = try fact("memory.subject.p1", input: input)
        XCTAssertEqual(process["boundaryChangeKind"], .string("unavailableBaseline"))
        XCTAssertEqual(process["startBytes"], .null)
        XCTAssertEqual(process["boundaryDeltaBytes"], .null)
        XCTAssertEqual(process["stateAtWindowEnd"], .string("active"))
        XCTAssertEqual(input.subjects.first?.canInspect, true)
        let reconciliation = try fact("memory.reconciliation", input: input)
        XCTAssertEqual(reconciliation["addedContributionBytes"], .number(0))
        XCTAssertEqual(reconciliation["unresolvedContributionBytes"], .number(Double(100 * mib)))
    }

    func testAIImportantPositiveInstancesSurviveCappedChangeList() throws {
        let exits = (100...135).map { process($0, 1_000) }
        let snapshots = [snapshot(0, [process(10, 2_000), process(11, 50)] + exits),
                         snapshot(60, [process(10, 2_100), process(11, 90), process(99, 60)])]
        let analysis = MemoryAnalyzer.analyze(snapshots)
        XCTAssertFalse(analysis.topChanges.contains { $0.pid == 99 })
        let adapter = MemoryAIAnalysisModule(snapshots: snapshots, analysis: analysis)
        let input = try adapter.makeInput()
        let addedID = try subjectID(pid: 99, ticks: 774_411_995, module: adapter)
        let existingID = try subjectID(pid: 11, ticks: 774_411_995, module: adapter)
        XCTAssertEqual(try fact("memory.subject.\(addedID)", input: input)["endBytes"], .number(Double(60 * mib)))
        XCTAssertEqual(try fact("memory.subject.\(existingID)", input: input)["sameInstanceAtBothBoundaries"], .bool(true))
        XCTAssertLessThanOrEqual(input.subjects.count, 12)
        let window = try fact("memory.window", input: input)
        XCTAssertEqual(window["observedInstanceCount"], .number(39))
        XCTAssertEqual(window["omittedInstanceCount"], .number(Double(39 - input.subjects.count)))
    }

    func testAIQualityReportsLongAndDuplicateSamplingIntervals() throws {
        let snapshots = [snapshot(0, [process(10, 100)], id: "a"), snapshot(0, [process(10, 100)], id: "b"),
                         snapshot(300, [process(10, 110)], id: "c")]
        let input = try module(snapshots).makeInput()
        let quality = try fact("memory.quality", input: input)
        XCTAssertEqual(quality["maxIntervalSeconds"], .number(300))
        XCTAssertEqual(quality["intervalOver120SecondsCount"], .number(1))
        XCTAssertEqual(quality["duplicateTimestampCount"], .number(1))
        XCTAssertTrue(input.guidance.contains("缺测当成零或进程退出"))
    }
}
