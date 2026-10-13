import Foundation
import XCTest
@testable import GPTMemoryCore

final class ExplanationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let mib: UInt64 = 1_024 * 1_024
    private let privateExecutable = "/Users/private-account/secret-workspace/worker-executable"

    private func process(_ pid: Int, _ memoryMiB: UInt64, ticks: UInt64 = 1,
                         role: ProcessRole = .renderer) -> ProcessSample {
        ProcessSample(bootID: "boot-a", pid: pid, parentPID: 1, startTimeTicks: ticks,
                      startedAt: origin.addingTimeInterval(-100), executable: privateExecutable,
                      role: role, footprintBytes: memoryMiB * mib)
    }

    private func snapshot(_ seconds: TimeInterval, _ processes: [ProcessSample],
                          missing: [Int] = [], pressure: Int? = nil,
                          id: String = UUID().uuidString) -> MemorySnapshot {
        MemorySnapshot(id: id, capturedAt: origin.addingTimeInterval(seconds),
                       processes: processes, system: .init(pressureLevel: pressure),
                       unavailablePIDs: missing)
    }

    private func explanationText(_ explanation: AnalysisExplanation) -> String {
        ([explanation.headline, explanation.summary] + explanation.evidence
         + explanation.findings.flatMap { [$0.id, $0.title, $0.detail] }
         + explanation.nextSteps).joined(separator: "\n")
    }

    private func analyze(_ snapshots: [MemorySnapshot]) throws -> MemoryAnalysis {
        let result = MemoryAnalyzer.analyze(snapshots)
        let explanation = try XCTUnwrap(result.explanation)
        XCTAssertFalse(explanation.headline.isEmpty)
        XCTAssertFalse(explanation.summary.isEmpty)
        XCTAssertFalse(explanation.nextSteps.isEmpty)
        XCTAssertFalse(explanationText(explanation).contains(privateExecutable))
        XCTAssertFalse(explanationText(explanation).contains("secret-workspace"))
        XCTAssertEqual(result.totalChangeBytes, result.addedContributionBytes
                       + result.exitedContributionBytes + result.existingChangeBytes
                       + result.unresolvedContributionBytes)
        return result
    }

    func testEmptySingleAndSameTimestampNeedMoreObservations() throws {
        let inputs: [[MemorySnapshot]] = [
            [],
            [snapshot(0, [process(10, 100)])],
            [snapshot(0, [process(10, 100)], id: "a"),
             snapshot(0, [process(10, 220)], id: "b")]
        ]
        for input in inputs {
            let result = try analyze(input)
            XCTAssertEqual(result.explanation?.kind, .insufficientData)
            XCTAssertTrue(result.sustainedGrowthCandidates.isEmpty)
            XCTAssertFalse(result.isComplete)
        }
    }

    func testAddedProcessesExplainMostOfTheGrowth() throws {
        let result = try analyze([
            snapshot(0, [process(10, 100), process(20, 40)]),
            snapshot(60, [process(10, 110), process(20, 40), process(30, 180)])
        ])
        let explanation = try XCTUnwrap(result.explanation)
        XCTAssertEqual(explanation.kind, .growth)
        XCTAssertEqual(result.addedContributionBytes, Int64(180 * mib))
        XCTAssertEqual(result.existingChangeBytes, Int64(10 * mib))
        XCTAssertTrue(explanation.summary.contains("新增"))
        XCTAssertTrue(explanation.summary.contains("PID 30"))
        XCTAssertTrue(explanation.evidence.contains { $0.contains("PID 30") })
        XCTAssertTrue(explanation.nextSteps.contains { $0.contains("PID 30") })
    }

    func testExistingProcessesExplainMostOfTheGrowth() throws {
        let growing = process(10, 230)
        let result = try analyze([
            snapshot(0, [process(10, 100), process(20, 40)]),
            snapshot(60, [growing, process(20, 50), process(30, 20)])
        ])
        let explanation = try XCTUnwrap(result.explanation)
        XCTAssertEqual(explanation.kind, .growth)
        XCTAssertEqual(result.existingChangeBytes, Int64(140 * mib))
        XCTAssertEqual(result.addedContributionBytes, Int64(20 * mib))
        XCTAssertTrue(explanation.summary.contains("存量"))
        XCTAssertEqual(explanation.findings.first { $0.kind == .growthProcess }?.processKey, growing.key)
    }

    func testLargestNegativeChangeDoesNotHideAnActuallyGrowingProcess() throws {
        let growing = process(10, 150)
        let shrinking = process(20, 700)
        let result = try analyze([
            snapshot(0, [process(10, 100), process(20, 1_000)]),
            snapshot(60, [growing, shrinking])
        ])
        let explanation = try XCTUnwrap(result.explanation)
        XCTAssertEqual(explanation.kind, .reduction)
        XCTAssertEqual(result.topChanges.first?.key, shrinking.key)
        let growthFindings = explanation.findings.filter { $0.kind == .growthProcess }
        XCTAssertEqual(growthFindings.map(\.processKey), [growing.key])
        XCTAssertEqual(growthFindings.map(\.pid), [10])
    }

    func testGrowthFindingsChooseOnlyTheLargestThreePositiveExistingChanges() throws {
        let before = (1...5).map { process($0, 100) }
        let after = (1...5).map { process($0, UInt64(100 + $0 * 10)) }
        let result = try analyze([snapshot(0, before), snapshot(60, after)])
        let findings = result.explanation?.findings.filter { $0.kind == .growthProcess } ?? []
        XCTAssertEqual(findings.count, 3)
        XCTAssertEqual(findings.map(\.processKey), [after[4].key, after[3].key, after[2].key])
    }

    func testLargeExitListCannotHideGrowthBeyondTheTopChangesLimit() throws {
        let exiting = (20...50).map { process($0, 1_000) }
        let growing = process(10, 130)
        let result = try analyze([
            snapshot(0, [process(10, 100)] + exiting), snapshot(60, [growing])
        ])
        XCTAssertEqual(result.topChanges.count, 30)
        XCTAssertFalse(result.topChanges.contains { $0.key == growing.key })
        let finding = result.explanation?.findings.first { $0.kind == .growthProcess }
        XCTAssertEqual(finding?.processKey, growing.key)
    }

    func testProcessTurnoverIsExplainedEvenWhenItsContributionsCancel() throws {
        let result = try analyze([
            snapshot(0, [process(10, 300)]),
            snapshot(60, [process(20, 303)])
        ])
        let explanation = try XCTUnwrap(result.explanation)
        let text = explanationText(explanation)
        XCTAssertEqual(explanation.kind, .littleChange)
        XCTAssertEqual(result.totalChangeBytes, Int64(3 * mib))
        XCTAssertEqual(result.addedContributionBytes, Int64(303 * mib))
        XCTAssertEqual(result.exitedContributionBytes, -Int64(300 * mib))
        XCTAssertTrue(text.contains("新增"))
        XCTAssertTrue(text.contains("退出"))
        XCTAssertFalse(text.contains("没有进程变化"))
        XCTAssertFalse(text.contains("无活动"))
    }

    func testSmallChangeThresholdDoesNotHideExactlyTenMiB() throws {
        let small = try analyze([
            snapshot(0, [process(10, 100)]), snapshot(60, [process(10, 109)])
        ])
        let threshold = try analyze([
            snapshot(0, [process(10, 100)]), snapshot(60, [process(10, 110)])
        ])
        XCTAssertEqual(small.explanation?.kind, .littleChange)
        XCTAssertEqual(threshold.explanation?.kind, .growth)
    }

    func testObservedSpikeIsExplainedAfterMemoryReturnsToItsBaseline() throws {
        let result = try analyze([
            snapshot(0, [process(10, 100)]), snapshot(60, [process(10, 350)]),
            snapshot(120, [process(10, 100)])
        ])
        XCTAssertEqual(result.explanation?.kind, .littleChange)
        XCTAssertEqual(result.totalChangeBytes, 0)
        XCTAssertTrue(result.sustainedGrowthCandidates.isEmpty)
        XCTAssertEqual(result.explanation?.findings.filter { $0.kind == .recoveredSpike }.count, 1)
    }

    func testIncompleteObservationCannotClaimARecoveredSpike() throws {
        let result = try analyze([
            snapshot(0, [process(10, 100)]),
            snapshot(60, [process(10, 350)], missing: [20]),
            snapshot(120, [process(10, 100)])
        ])
        XCTAssertEqual(result.explanation?.kind, .partialData)
        XCTAssertFalse(result.explanation?.findings.contains { $0.kind == .recoveredSpike } ?? true)
    }

    func testElevenObservationsAcrossTenMinutesExplainSustainedGrowth() throws {
        let samples: [MemorySnapshot] = (0...10).map { index in
            let seconds: Double = Double(index * 60)
            let memory: UInt64 = UInt64(100 + index * 12)
            return snapshot(seconds, [process(10, memory, role: .toolWorker)])
        }
        let result = try analyze(samples)
        let candidate = try XCTUnwrap(result.sustainedGrowthCandidates.first)
        XCTAssertEqual(candidate.sampleCount, 11)
        XCTAssertEqual(candidate.netGrowthBytes, Int64(120 * mib))
        let finding = try XCTUnwrap(result.explanation?.findings.first { $0.kind == .sustainedGrowth })
        XCTAssertEqual(finding.processKey, candidate.key)
        XCTAssertEqual(finding.pid, candidate.pid)
        XCTAssertFalse(finding.detail.contains("已退出"))
        XCTAssertFalse(finding.detail.contains("确认泄漏"))
        XCTAssertTrue(result.explanation?.nextSteps.contains {
            $0.contains("PID \(candidate.pid)") && $0.contains("启动") && $0.contains("手动")
        } ?? false)
    }

    func testExitedCandidateKeepsItsOriginalIdentityWhenPIDIsReused() throws {
        var samples: [MemorySnapshot] = (0...10).map { index in
            let seconds: Double = Double(index * 60)
            let memory: UInt64 = UInt64(100 + index * 12)
            return snapshot(seconds, [process(10, memory, ticks: 1)])
        }
        let replacement = process(10, 80, ticks: 2)
        samples.append(snapshot(660, [replacement]))
        let result = try analyze(samples)
        let candidate = try XCTUnwrap(result.sustainedGrowthCandidates.first)
        let finding = try XCTUnwrap(result.explanation?.findings.first { $0.kind == .sustainedGrowth })
        XCTAssertEqual(candidate.key, process(10, 100, ticks: 1).key)
        XCTAssertEqual(finding.processKey, candidate.key)
        XCTAssertNotEqual(finding.processKey, replacement.key)
        XCTAssertTrue(finding.detail.contains("已退出"))
        XCTAssertFalse(result.explanation?.nextSteps.contains { $0.contains("手动采集诊断摘要") } ?? true)
    }

    func testAnyMeasurementGapTakesPrecedenceOverAnOrdinaryConclusion() throws {
        let inputs = [
            [snapshot(0, [], missing: [10]), snapshot(60, [process(10, 120)])],
            [snapshot(0, [process(10, 100)]), snapshot(60, [], missing: [10])],
            [snapshot(0, [process(10, 100)]), snapshot(60, [], missing: [10]),
             snapshot(120, [process(10, 105)])]
        ]
        for input in inputs {
            let result = try analyze(input)
            let explanation = try XCTUnwrap(result.explanation)
            XCTAssertEqual(explanation.kind, .partialData)
            XCTAssertFalse(result.isComplete)
            XCTAssertTrue(explanation.findings.contains { $0.kind == .measurementGap })
            XCTAssertFalse(explanationText(explanation).contains("正常"))
            XCTAssertFalse(explanationText(explanation).contains("观测完整"))
            XCTAssertFalse(explanationText(explanation).contains("数据完整"))
        }
    }

    func testCurrentSystemPressureHasItsOwnFinding() throws {
        for pressure in [2, 4] {
            let result = try analyze([
                snapshot(0, [process(10, 100)], pressure: 1),
                snapshot(60, [process(10, 100)], pressure: pressure)
            ])
            XCTAssertTrue(result.explanation?.findings.contains { $0.kind == .memoryPressure } ?? false)
            XCTAssertTrue(result.sustainedGrowthCandidates.isEmpty)
        }
        let recovered = try analyze([
            snapshot(0, [process(10, 100)], pressure: 4),
            snapshot(60, [process(10, 100)], pressure: 1)
        ])
        XCTAssertFalse(recovered.explanation?.findings.contains { $0.kind == .memoryPressure } ?? true)
    }

    func testExplanationSurvivesJSONAndOldAnalysisWithoutExplanationStillDecodes() throws {
        let result = try analyze([
            snapshot(0, [process(10, 100)]), snapshot(60, [process(10, 130)])
        ])
        let encoded = try MemoryJSON.encoder().encode(result)
        let decoded = try MemoryJSON.decoder().decode(MemoryAnalysis.self, from: encoded)
        XCTAssertEqual(decoded.explanation?.kind, result.explanation?.kind)
        XCTAssertEqual(decoded.explanation?.headline, result.explanation?.headline)
        XCTAssertEqual(decoded.explanation?.summary, result.explanation?.summary)
        XCTAssertEqual(decoded.explanation?.evidence, result.explanation?.evidence)
        XCTAssertEqual(decoded.explanation?.findings.map(\.kind), result.explanation?.findings.map(\.kind))
        XCTAssertEqual(decoded.explanation?.findings.map(\.processKey), result.explanation?.findings.map(\.processKey))
        XCTAssertEqual(decoded.explanation?.nextSteps, result.explanation?.nextSteps)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "explanation")
        let legacyJSON = try JSONSerialization.data(withJSONObject: legacy)
        let legacyResult = try MemoryJSON.decoder().decode(MemoryAnalysis.self, from: legacyJSON)
        XCTAssertNil(legacyResult.explanation)
        XCTAssertEqual(legacyResult.totalChangeBytes, result.totalChangeBytes)
        XCTAssertEqual(legacyResult.topChanges.first?.key, result.topChanges.first?.key)
    }
}
