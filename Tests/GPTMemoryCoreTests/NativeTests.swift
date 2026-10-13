import XCTest
import Foundation
import Darwin
import CNative
@testable import GPTMemoryCore

final class NativeTests: XCTestCase {
    func testNativeBirthIdentitySurvivesBootUUIDPermissionDifferences() {
        var normal = ProcessSample(bootID: "known-boot", pid: 123, parentPID: 1, startTimeTicks: 4,
            startedAt: Date(), executable: "node", role: .repl, footprintBytes: 1024,
            absoluteStartTimeMicroseconds: 1_791_602_700_000_004)
        var restricted = normal
        restricted.bootID = "boot-unavailable-start-epoch"
        XCTAssertEqual(normal.key, restricted.key)
        restricted.footprintBytes += 128
        let a = MemorySnapshot(capturedAt: Date(timeIntervalSince1970: 100), processes: [normal])
        let b = MemorySnapshot(capturedAt: Date(timeIntervalSince1970: 105), processes: [restricted])
        let analysis = MemoryAnalyzer.analyze([a, b])
        XCTAssertEqual(analysis.addedContributionBytes, 0)
        XCTAssertEqual(analysis.exitedContributionBytes, 0)
        XCTAssertEqual(analysis.existingChangeBytes, 128)
        XCTAssertFalse(analysis.events.contains { $0.kind == .bootChanged })
        normal.absoluteStartTimeMicroseconds! += 1
        XCTAssertNotEqual(normal.key, restricted.key)
    }

    func testDiagnosticFileIsPrivateReadableAndNeverClobbered() throws {
        var info = gpt_process_info()
        XCTAssertEqual(gpt_read_process(getpid(), &info), 0)
        let process = ProcessSample(bootID: "test", pid: Int(getpid()), parentPID: Int(getppid()),
            startTimeTicks: info.start_ticks, startedAt: Date(timeIntervalSince1970: info.started_at),
            executable: "MemoryChecks", role: .other, rootKey: "test-root", footprintBytes: info.footprint_bytes)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("summary.txt")
        let result = try DiagnosticCapture.capture(process: process, output: url)
        XCTAssertEqual(result.pid, Int(getpid()))
        let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let content = try Data(contentsOf: url)
        XCTAssertGreaterThan(content.count, 0)
        XCTAssertLessThanOrEqual(content.count, 512 * 1024)
        XCTAssertEqual(Darwin.kill(getpid(), 0), 0)
        XCTAssertThrowsError(try DiagnosticCapture.capture(process: process, output: url))
        XCTAssertEqual(try Data(contentsOf: url), content)
        var reused = process
        reused.startTimeTicks += 1
        let refused = dir.appendingPathComponent("reused.txt")
        XCTAssertThrowsError(try DiagnosticCapture.capture(process: reused, output: refused))
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.path))
    }

    func testBootIdentityIsStableAcrossIndependentCollectors() throws {
        let first = try XCTUnwrap(NativeCollector().sample().observer)
        let second = try XCTUnwrap(NativeCollector().sample().observer)
        // Exercises the stable fallback too, when kern.* and launchd are sandboxed.
        XCTAssertEqual(first.bootID, second.bootID)
        XCTAssertEqual(first.key, second.key)
        XCTAssertFalse(first.bootID.isEmpty)
    }

    func testNativeOwnProcessFootprintAndBirthIdentity() throws {
        var first = gpt_process_info()
        XCTAssertEqual(gpt_read_process(getpid(), &first), 0)
        XCTAssertEqual(first.pid, getpid())
        XCTAssertNotEqual(first.start_ticks, 0)
        XCTAssertEqual(first.metrics_valid, 1)
        XCTAssertGreaterThan(first.footprint_bytes, 0)
        XCTAssertGreaterThanOrEqual(first.peak_footprint_bytes, first.footprint_bytes)
        var second = gpt_process_info()
        XCTAssertEqual(gpt_read_process(getpid(), &second), 0)
        XCTAssertEqual(first.start_ticks, second.start_ticks)
        XCTAssertLessThanOrEqual(second.started_at, Date().timeIntervalSince1970)
    }

    func testWorkerDoesNotBecomeMCPAndUnknownNodeIsExplicit() {
        XCTAssertEqual(ProcessClassifier.classify(executable: "/runtime/node", safeHint: "tool_worker"), .toolWorker)
        XCTAssertEqual(ProcessClassifier.classify(executable: "/runtime/node", safeHint: ""), .unknownNode)
        XCTAssertEqual(ProcessClassifier.classify(executable: "/runtime/node_repl", safeHint: ""), .repl)
        XCTAssertEqual(ProcessClassifier.classify(executable: "/runtime/Codex (Service)", safeHint: "gpu"), .gpu)
        XCTAssertEqual(ProcessClassifier.classify(executable: "/runtime/node", safeHint: "mcp_mysql"), .mcpMySQL)
        XCTAssertEqual(ProcessClassifier.classify(executable: "/runtime/node", safeHint: "arbitrary-sensitive-argument"), .unknownNode)
    }

    func testRootRequiresApplicationBundleAndKnownExecutable() {
        XCTAssertTrue(ProcessClassifier.isAppRoot(executable: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        XCTAssertTrue(ProcessClassifier.isAppRoot(executable: "/Applications/Codex.app/Contents/MacOS/Codex"))
        XCTAssertFalse(ProcessClassifier.isAppRoot(executable: "/bin/codex"))
        XCTAssertFalse(ProcessClassifier.isAppRoot(executable: "/tmp/ChatGPT"))
    }

    func testWriterLockExclusionAndRelease() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("monitor.lock")
        var first: MonitorLock? = try MonitorLock(url: url)
        XCTAssertThrowsError(try MonitorLock(url: url))
        first = nil
        let second = try MonitorLock(url: url)
        withExtendedLifetime(second) {}
        XCTAssertNil(first)
    }

    func testJSONFootprintIncludesNoRawCommandLine() throws {
        let p = ProcessSample(bootID: "boot", pid: 123, parentPID: 1, startTimeTicks: 4,
            startedAt: Date(), executable: "/runtime/node", role: .mcpMySQL, roleHint: "mcp_mysql", footprintBytes: 1024)
        let data = try MemoryJSON.encoder().encode(MemorySnapshot(processes: [p]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("argv"))
        XCTAssertFalse(text.contains("environment"))
        let decoded = try MemoryJSON.decoder().decode(MemorySnapshot.self, from: data)
        XCTAssertEqual(decoded.totalFootprintBytes, 1024)
        XCTAssertEqual(decoded.processes.first?.key, "boot:123:4")
    }
}
