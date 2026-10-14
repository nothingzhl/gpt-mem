import XCTest
import Foundation
import Darwin
import CNative
@testable import GPTMemoryCore

final class ProcessControlTests: XCTestCase {
    private final class Fixture {
        let root = ProcessSample(bootID: "test", pid: 12344, parentPID: 1, startTimeTicks: 1,
            startedAt: Date(timeIntervalSince1970: 0), executable: "/Applications/Codex.app/Contents/MacOS/Codex",
            role: .appMain, rootKey: "test:12344:1", footprintBytes: 0)
        var process = ProcessSample(bootID: "test", pid: 12345, parentPID: 12344, startTimeTicks: 100,
            startedAt: Date(timeIntervalSince1970: 1), executable: "/runtime/node", role: .toolWorker,
            rootKey: "test:12344:1", footprintBytes: 100, absoluteStartTimeMicroseconds: 100)
        var snapshot: MemorySnapshot!
        var read: ProcessLiveRead = .found(.init(birth: 100, executable: "/runtime/node"))
        var sent: [ProcessExitKind] = []
        var clock = Date(timeIntervalSince1970: 100)
        var failSend = false
        init() { snapshot = .init(processes: [root, process]) }
        func control() -> ProcessControl {
            ProcessControl(sample: { self.snapshot }, read: { _ in self.read }, send: { _, kind in
                if self.failSend { throw MemoryError.message("fixture refused") }
                self.sent.append(kind)
            }, protectedPIDs: [1, 11], now: { self.clock })
        }
    }

    func testOptimizationProtectsWholeFamilyAndOnlyRecommendsRoots() {
        let fixture = Fixture()
        var root = fixture.root; root.footprintBytes = 200 * 1024 * 1024
        var child = fixture.process; child.footprintBytes = 300 * 1024 * 1024
        let snapshot = MemorySnapshot(processes: [root, child])
        let candidates = MemoryOptimizationPlanner.candidates(snapshot: snapshot, protectedPIDs: [])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.process.key, root.key)
        XCTAssertEqual(candidates.first?.familyBytes, 500 * 1024 * 1024)
        XCTAssertEqual(candidates.first?.relatedProcessCount, 1)
        XCTAssertTrue(MemoryOptimizationPlanner.candidates(snapshot: snapshot, protectedPIDs: [child.pid]).isEmpty)
        root.ownership = "remembered_ancestry"
        XCTAssertTrue(MemoryOptimizationPlanner.candidates(snapshot: .init(processes: [root, child]), protectedPIDs: []).isEmpty)
        root.ownership = "process_tree"; root.rootKey = "unknown"
        XCTAssertTrue(MemoryOptimizationPlanner.candidates(snapshot: .init(processes: [root, child]), protectedPIDs: []).isEmpty)
    }

    func testOptimizationRejectsSmallFamiliesAndOverflow() {
        let fixture = Fixture()
        XCTAssertTrue(MemoryOptimizationPlanner.candidates(snapshot: fixture.snapshot, protectedPIDs: []).isEmpty)
        var root = fixture.root; root.footprintBytes = UInt64.max
        var child = fixture.process; child.footprintBytes = 1
        XCTAssertTrue(MemoryOptimizationPlanner.candidates(snapshot: .init(processes: [root, child]), protectedPIDs: []).isEmpty)
    }

    func testSignalAcceptanceIsNotAnExitAndEffectsAreMeasured() throws {
        let fixture = Fixture(), control = fixture.control()
        let receipt = try control.execute(process: fixture.process, kind: .request)
        XCTAssertEqual(fixture.sent, [.request])
        XCTAssertEqual(try control.observe(receipt).state, .running)
        fixture.read = .missing
        fixture.snapshot = .init(processes: [])
        let result = try control.observe(receipt)
        XCTAssertEqual(result.state, .exited)
        XCTAssertEqual(result.knownTotalChange, -100)
        XCTAssertEqual(receipt.before.processes.first(where: { $0.key == fixture.process.key })?.footprintBytes, 100)
    }

    func testStaleReusedUnownedAndProtectedTargetsNeverSignal() throws {
        let fixture = Fixture(), control = fixture.control()
        fixture.snapshot = .init(processes: [])
        XCTAssertThrowsError(try control.execute(process: fixture.process, kind: .request))
        var orphan = fixture.process; orphan.parentPID = 1
        fixture.snapshot = .init(processes: [fixture.root, orphan])
        XCTAssertThrowsError(try control.execute(process: fixture.process, kind: .request))
        fixture.snapshot = .init(processes: [fixture.root, fixture.process])
        fixture.read = .found(.init(birth: 101, executable: "/runtime/node"))
        XCTAssertThrowsError(try control.execute(process: fixture.process, kind: .request))
        fixture.read = .found(.init(birth: 100, executable: "/runtime/other"))
        XCTAssertThrowsError(try control.execute(process: fixture.process, kind: .request))
        var target = fixture.process; target.pid = 11
        XCTAssertThrowsError(try control.execute(process: target, kind: .request))
        target.pid = -1
        XCTAssertThrowsError(try control.execute(process: target, kind: .request))
        target = fixture.process; target.ownership = "remembered_ancestry"
        XCTAssertThrowsError(try control.execute(process: target, kind: .request))
        target.ownership = "process_tree"; target.rootKey = ""
        XCTAssertThrowsError(try control.execute(process: target, kind: .request))
        target.pid = Int.max
        XCTAssertThrowsError(try ProcessControl.sendNative(target, .force))
        target.pid = fixture.process.pid; target.role = .appMain
        XCTAssertThrowsError(try ProcessControl.sendNative(target, .request))
        XCTAssertTrue(fixture.sent.isEmpty)
    }

    func testForceRequiresPriorSameInstanceRequestAndDelay() throws {
        let fixture = Fixture(), control = fixture.control()
        XCTAssertThrowsError(try control.execute(process: fixture.process, kind: .force))
        let receipt = try control.execute(process: fixture.process, kind: .request)
        XCTAssertThrowsError(try control.execute(process: fixture.process, kind: .force, previous: receipt))
        fixture.clock = fixture.clock.addingTimeInterval(6)
        var other = fixture.process; other.executable = "/runtime/other"
        let wrong = ProcessExitReceipt(process: other, kind: .request, requestedAt: receipt.requestedAt, before: receipt.before)
        XCTAssertThrowsError(try control.execute(process: fixture.process, kind: .force, previous: wrong))
        let forced = try control.execute(process: fixture.process, kind: .force, previous: receipt)
        XCTAssertEqual(forced.kind, .force)
        XCTAssertEqual(fixture.sent, [.request, .force])
        XCTAssertThrowsError(try control.execute(process: fixture.process, kind: .force, previous: forced))
    }

    func testUnknownReplacementAndMissingCountersAreDistinct() throws {
        let fixture = Fixture(), control = fixture.control()
        let receipt = try control.execute(process: fixture.process, kind: .request)
        fixture.read = .unavailable
        fixture.snapshot = .init(processes: [], unavailablePIDs: [fixture.process.pid])
        let unknown = try control.observe(receipt)
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertNil(unknown.knownTotalChange)
        fixture.read = .found(.init(birth: 101, executable: "/runtime/node"))
        XCTAssertEqual(try control.observe(receipt).state, .replaced)
        var replacement = fixture.process
        replacement.pid += 1; replacement.startTimeTicks = 102; replacement.absoluteStartTimeMicroseconds = 102
        replacement.startedAt = receipt.requestedAt.addingTimeInterval(1)
        fixture.snapshot = .init(processes: [replacement])
        XCTAssertEqual(try control.observe(receipt).replacementPIDs, [replacement.pid])
        replacement.footprintBytes = UInt64.max
        fixture.snapshot = .init(processes: [replacement])
        XCTAssertNil(try control.observe(receipt).knownTotalChange)
        fixture.failSend = true
        fixture.read = .found(.init(birth: 100, executable: "/runtime/node"))
        fixture.snapshot = .init(processes: [fixture.root, fixture.process])
        XCTAssertThrowsError(try control.execute(process: fixture.process, kind: .request))
        XCTAssertEqual(fixture.sent, [.request])
    }

    func testMainApplicationRestartCanHaveADifferentRoot() throws {
        let fixture = Fixture(); fixture.process.role = .appMain
        fixture.process.executable = fixture.root.executable; fixture.process.rootKey = fixture.process.key
        fixture.read = .found(.init(birth: 100, executable: fixture.process.executable))
        fixture.snapshot = .init(processes: [fixture.process])
        let control = fixture.control()
        let receipt = try control.execute(process: fixture.process, kind: .request)
        var new = fixture.process; new.pid += 1; new.absoluteStartTimeMicroseconds = 200
        new.startedAt = receipt.requestedAt; new.rootKey = new.key
        fixture.snapshot = .init(processes: [new]); fixture.read = .missing
        XCTAssertEqual(try control.observe(receipt).replacementPIDs, [new.pid])
    }

    func testNativeGuardAndExitOnlyTouchOwnedTemporaryChildren() throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        var info = gpt_process_info()
        XCTAssertEqual(gpt_read_process(child.processIdentifier, &info), 0)
        let path = withUnsafePointer(to: &info.executable) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
        }
        XCTAssertNotEqual(gpt_signal_process(-1, info.start_ticks, path, SIGTERM), 0)
        XCTAssertNotEqual(gpt_signal_process(child.processIdentifier, info.start_ticks + 1, path, SIGTERM), 0)
        XCTAssertNotEqual(gpt_signal_process(child.processIdentifier, info.start_ticks, path, SIGHUP), 0)
        XCTAssertTrue(child.isRunning)
        let root = nativeFixtureRoot()
        let target = ProcessSample(bootID: "fixture", pid: Int(child.processIdentifier), parentPID: Int(getpid()),
            startTimeTicks: info.start_ticks, startedAt: Date(timeIntervalSince1970: info.started_at), executable: path,
            role: .toolWorker, rootKey: root.key, footprintBytes: info.footprint_bytes,
            absoluteStartTimeMicroseconds: info.start_ticks)
        let control = ProcessControl(sample: { .init(processes: [root, target]) })
        let receipt = try control.execute(process: target, kind: .request)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
        XCTAssertEqual(try control.observe(receipt).state, .exited)
    }

    func testNativeForceOnlyStopsAnOwnedChildThatIgnoredNormalExit() throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
        try child.run()
        defer { if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        var info = gpt_process_info(), path = ""
        for _ in 0..<100 {
            if gpt_read_process(child.processIdentifier, &info) == 0 {
                path = withUnsafePointer(to: &info.executable) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
                }
                if URL(fileURLWithPath: path).lastPathComponent == "sleep" { break }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "sleep")
        let root = nativeFixtureRoot()
        let target = ProcessSample(bootID: "fixture", pid: Int(child.processIdentifier), parentPID: Int(getpid()),
            startTimeTicks: info.start_ticks, startedAt: Date(timeIntervalSince1970: info.started_at), executable: path,
            role: .toolWorker, rootKey: root.key, footprintBytes: info.footprint_bytes,
            absoluteStartTimeMicroseconds: info.start_ticks)
        var clock = Date()
        let control = ProcessControl(sample: { .init(processes: [root, target]) }, now: { clock })
        let receipt = try control.execute(process: target, kind: .request)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(child.isRunning)
        XCTAssertEqual(try control.observe(receipt).state, .running)
        clock = clock.addingTimeInterval(6)
        _ = try control.execute(process: target, kind: .force, previous: receipt)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, SIGKILL)
    }

    // Only ancestry metadata is injected. Native tests signal our own freshly
    // spawned children, never a real ChatGPT/Codex application or subprocess.
    private func nativeFixtureRoot() -> ProcessSample {
        ProcessSample(bootID: "fixture", pid: Int(getpid()), parentPID: 1, startTimeTicks: 1,
            startedAt: Date(timeIntervalSince1970: 0), executable: "/Applications/Codex.app/Contents/MacOS/Codex",
            role: .appMain, rootKey: "fixture:\(getpid()):1", footprintBytes: 0)
    }
}
