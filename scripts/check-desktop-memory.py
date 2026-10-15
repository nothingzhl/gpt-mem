#!/usr/bin/env python3
"""Check the production sampling service with synthetic samples and slow local helpers.

Only temporary databases, an injected diagnostic, and a fake export component are
used. No native process inspection, real vmmap, credentials, or model calls occur.
"""
from pathlib import Path
import argparse
import importlib.util
import os
import platform
import re
import subprocess
import tempfile


CHECKS = r'''
private final class Fixture {
    private let lock = NSLock()
    private var count = 0
    private var paused = false
    private var diagnosticStarted = false
    private var diagnosticDone = false
    private var exportDone = false
    private var errors: [String] = []
    private var latestPublished: MemorySnapshot?
    private var publishedHistory: [MemorySnapshot] = []
    private var publishedAnalysis: MemoryAnalysis?
    private var mode = ""
    var state: (count: Int, paused: Bool, diagnosticStarted: Bool, diagnosticDone: Bool, exportDone: Bool, errors: [String], latestPublished: MemorySnapshot?, history: [MemorySnapshot], analysis: MemoryAnalysis?, mode: String) {
        lock.lock(); defer { lock.unlock() }
        return (count, paused, diagnosticStarted, diagnosticDone, exportDone, errors, latestPublished, publishedHistory, publishedAnalysis, mode)
    }
    func sample() -> MemorySnapshot {
        lock.lock(); count += 1; let index = count; lock.unlock()
        let path = "/Applications/" + String(repeating: "临时采样元数据/", count: 20) + "Fixture.app/Contents/MacOS/Fixture"
        let processes = (0..<40).map { offset in
            ProcessSample(bootID: "fixture", pid: 1000 + offset, parentPID: 1, startTimeTicks: 1,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000), executable: path,
                role: .renderer, roleHint: "合成页面渲染", rootKey: "fixture:root",
                footprintBytes: UInt64(index * 1024 + offset))
        }
        return MemorySnapshot(id: String(index), capturedAt: Date(), processes: processes,
                              warnings: ["合成样本；验证采样临时对象释放后的数据寿命。"])
    }
    func update(_ update: DesktopUpdate) {
        lock.lock(); defer { lock.unlock() }
        paused = update.mode == "已暂停"
        mode = update.mode
        publishedHistory = update.history; publishedAnalysis = update.analysis
        if let snapshot = update.snapshot { latestPublished = snapshot }
        if let error = update.historyError { errors.append(error) }
    }
    func capture(_ process: ProcessSample, _ output: URL) throws -> DiagnosticResult {
        lock.lock(); diagnosticStarted = true; lock.unlock()
        Thread.sleep(forTimeInterval: 0.8)
        throw MemoryError.message("fixture diagnostic failure")
    }
    func finishDiagnostic(_ result: Result<DiagnosticResult, Error>) {
        lock.lock(); diagnosticDone = true
        if case .success = result { errors.append("expected fixture failure") }
        lock.unlock()
    }
    func finishExport(_ result: Result<Void, Error>) {
        lock.lock(); exportDone = true
        if case .failure(let error) = result { errors.append(String(describing: error)) }
        lock.unlock()
    }
}

var assertions = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    assertions += 1
    if !condition() { throw MemoryError.message(message) }
}
func waitFor(_ condition: () -> Bool, timeout: Double = 2, _ message: String) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() {
        if ProcessInfo.processInfo.systemUptime >= deadline { throw MemoryError.message(message) }
        Thread.sleep(forTimeInterval: 0.01)
    }
}
do {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GPT_MEMORY_CHECK_DIR"]!)
    let fixture = Fixture()
    let service = DesktopSamplingService(databaseURL: root.appendingPathComponent("history.sqlite3"),
        sample: fixture.sample, diagnosticCapture: fixture.capture, handler: fixture.update)
    service.start(interval: 0.1, window: 60)
    try waitFor({ fixture.state.count >= 1 }, "initial synthetic sample")
    let process = ProcessSample(bootID: "fixture", pid: 888, parentPID: 1, startTimeTicks: 1,
        startedAt: Date(), executable: "fixture", role: .renderer, footprintBytes: 1)
    service.diagnose(process: process, output: root.appendingPathComponent("unused.txt"), completion: fixture.finishDiagnostic)
    try waitFor({ fixture.state.diagnosticStarted }, "diagnostic did not start")
    let initialCount = fixture.state.count
    try waitFor({ fixture.state.count >= initialCount + 2 }, timeout: 0.6, "diagnostic blocked sampling")
    try expect(!fixture.state.diagnosticDone, "samples must continue before diagnostic returns")
    service.stop()
    try waitFor({ fixture.state.paused }, timeout: 0.4, "pause queued behind diagnostic")
    try expect(!fixture.state.diagnosticDone, "pause completes while diagnostic still runs")
    try waitFor({ fixture.state.diagnosticDone }, "diagnostic completion missing")
    print("PASS slow diagnostic does not block sampling or pause")

    service.start(interval: 0.1, window: 60)
    try waitFor({ !fixture.state.paused }, "sampling did not resume")
    let beforeExport = fixture.state.count
    service.exportReport(to: root.appendingPathComponent("unused.html"), window: 60, completion: fixture.finishExport)
    try waitFor({ fixture.state.count >= beforeExport + 2 }, timeout: 0.6, "export blocked sampling")
    try expect(!fixture.state.exportDone, "samples continue before slow export exits")
    service.stop()
    try waitFor({ fixture.state.paused }, timeout: 0.4, "pause queued behind export")
    try expect(!fixture.state.exportDone, "pause completes before export exits")
    try waitFor({ fixture.state.exportDone }, "export completion missing")
    try expect(fixture.state.errors.isEmpty, "fixture operations produced unexpected errors")
    let reader = try MemoryStore(url: root.appendingPathComponent("history.sqlite3"), readOnly: true)
    let persisted = try reader.load(since: Date().addingTimeInterval(-60))
    try expect(persisted.count >= 5, "continued samples persisted")
    print("PASS slow export does not block sampling or pause")
    try expect(persisted.last == fixture.state.latestPublished, "published sample survives sampling autorelease pool")
    try expect(persisted.last?.processes.count == 40, "complete process samples persist")
    try expect(persisted.last?.processes.first?.executable.contains("临时采样元数据") == true,
               "long Unicode executable metadata survives decoder pools")
    try expect(persisted.last?.processes.last?.rootKey == "fixture:root", "process identity metadata remains valid")
    try expect(persisted.last?.warnings == ["合成样本；验证采样临时对象释放后的数据寿命。"],
               "snapshot warnings remain valid")
    print("PASS complete published and persisted samples survive temporary object pools")

    service.start(interval: 0.1, window: 60)
    try waitFor({ !fixture.state.paused && !fixture.state.history.isEmpty }, "resume history before hiding")
    service.setHistoryActive(false)
    try waitFor({ fixture.state.history.isEmpty && fixture.state.analysis == nil }, "hidden module retained its history")
    let beforeHidden = fixture.state.count
    try waitFor({ fixture.state.count >= beforeHidden + 2 }, "hidden module stopped collecting")
    try expect(fixture.state.history.isEmpty && fixture.state.analysis == nil, "hidden ticks must not rebuild history")
    service.setHistoryActive(true)
    try waitFor({ fixture.state.history.count >= beforeHidden + 2 }, "reactivation did not include hidden persisted samples")
    try expect(fixture.state.analysis?.sampleCount == fixture.state.history.count, "reactivation restores complete analysis")
    do {
        let external = try MemoryStore(url: root.appendingPathComponent("history.sqlite3"))
        var amended = fixture.state.history.first!
        amended.warnings = ["external update while desktop owns collection"]
        try external.save(amended)
        try waitFor({ fixture.state.history.first?.warnings == amended.warnings }, "owner did not reload external same-ID upsert")
    }
    service.stop()
    try waitFor({ fixture.state.paused }, "pause after hidden history check")
    print("PASS hidden memory pages release history while collection continues and reactivation reloads all samples")

    var externalLock: MonitorLock? = try MonitorLock(url: root.appendingPathComponent("monitor.lock"))
    try expect(externalLock != nil, "temporary external collector lock is acquired")
    let externalStore = try MemoryStore(url: root.appendingPathComponent("history.sqlite3"))
    let viewer = Fixture()
    let readonlyService = DesktopSamplingService(databaseURL: root.appendingPathComponent("history.sqlite3"),
        sample: viewer.sample, diagnosticCapture: viewer.capture, handler: viewer.update)
    readonlyService.start(interval: 0.1, window: 60)
    try waitFor({ viewer.state.mode == "外部采集 · 只读" && !viewer.state.history.isEmpty }, "shared lock reader did not load history")
    try expect(viewer.state.count == 0, "read-only viewer must not collect native samples")
    var amended = viewer.state.history.first!
    amended.warnings = ["external fixture upsert with unchanged identity and timestamp"]
    try externalStore.save(amended)
    try waitFor({ viewer.state.history.first?.warnings == amended.warnings }, "external same-ID upsert did not invalidate history")
    readonlyService.setHistoryActive(false)
    try waitFor({ viewer.state.history.isEmpty }, "hide external reader history")
    externalLock = nil
    try waitFor({ viewer.state.count >= 1 && viewer.state.mode == "正在采集" }, "desktop did not acquire released collector lock")
    try expect(viewer.state.history.isEmpty, "lock recovery while hidden must not reload history")
    readonlyService.setHistoryActive(true)
    try waitFor({ !viewer.state.history.isEmpty }, "recovered collector history did not reactivate")
    readonlyService.stop()
    try waitFor({ viewer.state.paused }, "pause recovered collector")
    try expect(viewer.state.errors.isEmpty, "shared lock workflows produced unexpected errors")
    print("PASS read-only shared lock, same-ID external upsert, hidden lock recovery and history reactivation")

    let baselineURL = root.appendingPathComponent("moved-baseline/history.sqlite3")
    let baselineStore = try MemoryStore(url: baselineURL)
    let baselineOrigin = Date()
    for (id, seconds) in [("older", -120.0), ("predecessor", -90.0), ("baseline", -70.0), ("recent", -10.0)] {
        try baselineStore.save(MemorySnapshot(id: id, capturedAt: baselineOrigin.addingTimeInterval(seconds), processes: []))
    }
    let boundaryFixture = Fixture()
    var boundarySamples = 0
    let boundaryService = DesktopSamplingService(databaseURL: baselineURL, sample: {
        boundarySamples += 1
        return MemorySnapshot(id: boundarySamples == 1 ? "first-owner-sample" : "baseline", capturedAt: Date(), processes: [])
    }, diagnosticCapture: boundaryFixture.capture, handler: boundaryFixture.update)
    boundaryService.start(interval: 60, window: 60)
    try waitFor({ boundaryFixture.state.history.first?.id == "baseline" }, "initial persisted comparison baseline")
    boundaryService.refresh(window: 60)
    try waitFor({ boundaryFixture.state.history.first?.id == "predecessor" }, "same-ID baseline move did not recover discarded predecessor immediately")
    try expect(boundaryFixture.state.errors.isEmpty, "successful authoritative baseline recovery must not publish transient errors")
    boundaryService.stop()
    try waitFor({ boundaryFixture.state.paused }, "pause after baseline recovery")
    print("PASS moved owner baseline immediately reloads the authoritative predecessor")
    print("DESKTOP MEMORY CHECKS PASSED: 6 workflows, \(assertions) assertions; synthetic samples only")
} catch {
    fputs("DESKTOP MEMORY CHECK FAILED: \(error)\n", stderr); exit(1)
}
'''

BENCHMARK = r'''
func runFootprintProbe(_ variant: String) throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GPT_MEMORY_CHECK_DIR"]!)
    func footprint() throws -> UInt64 {
        var info = gpt_process_info()
        guard gpt_read_process(getpid(), &info) == 0, info.metrics_valid != 0 else {
            throw MemoryError.message("cannot inspect fixture process footprint")
        }
        return info.footprint_bytes
    }
    let before = try footprint()
    let url = root.appendingPathComponent("metadata.sqlite3")
    let origin = Date(timeIntervalSince1970: 1_800_000_000)
    let history: [MemorySnapshot]
    if variant == "baseline" { history = try BaselineMemoryStore(url: url, readOnly: true).load(since: origin) }
    else { history = try MemoryStore(url: url, readOnly: true).load(since: origin) }
    let after = try withExtendedLifetime(history) { try footprint() }
    precondition(history.count == 720 && history.last?.processes.count == 100)
    print("MEMORY metadata.\(variant).720x100 retained_footprint_delta_mib=\(String(format: "%.3f", Double(after - before) / 1048576))")
}
func benchmark(_ name: String, _ operation: () throws -> Void) throws {
    var times: [Double] = []
    var cpuTimes: [Double] = []
    func cpuTime() -> Double {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }
    for _ in 0..<5 {
        let cpuStart = cpuTime()
        let start = ProcessInfo.processInfo.systemUptime
        try autoreleasepool { try operation() }
        times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        cpuTimes.append((cpuTime() - cpuStart) * 1000)
    }
    print("PERF \(name) median_ms=\(String(format: "%.3f", times.sorted()[2])) cpu_median_ms=\(String(format: "%.3f", cpuTimes.sorted()[2]))")
}
func runBenchmarks() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GPT_MEMORY_CHECK_DIR"]!)
    let origin = Date(timeIntervalSince1970: 1_800_000_000)
    let samples = (0..<720).map { index in
        MemorySnapshot(id: "s\(index)", capturedAt: origin.addingTimeInterval(Double(index * 5)),
            processes: (0..<100).map { offset in
                ProcessSample(bootID: "fixture", pid: 1000 + offset, parentPID: 1, startTimeTicks: 1,
                    startedAt: origin, executable: "fixture", role: .renderer,
                    footprintBytes: UInt64(100_000_000 + index * 100 + offset))
            })
    }
    // Compile the previous checked-in implementation beside production, then
    // execute both on identical synthetic values in the same release process.
    let baseline = try BaselineMemoryStore(url: root.appendingPathComponent("benchmark.sqlite3"), decodedCacheByteLimit: 32 * 1024 * 1024)
    let store = try MemoryStore(url: root.appendingPathComponent("benchmark.sqlite3"))
    for snapshot in samples { try store.save(snapshot) }
    let old = BaselineMemoryAnalyzer.analyze(samples)
    let current = MemoryAnalyzer.analyze(samples)
    let oldJSON = try MemoryJSON.encoder().encode(old)
    let currentJSON = try MemoryJSON.encoder().encode(current)
    precondition(oldJSON == currentJSON)
    try benchmark("memory.analysis.baseline.720x100") { _ = BaselineMemoryAnalyzer.analyze(samples) }
    try benchmark("memory.analysis.current.720x100") { _ = MemoryAnalyzer.analyze(samples) }
    _ = try baseline.load(since: origin)
    var rolling = MemoryHistoryState()
    rolling.refresh { samples }
    var count = 720
    try benchmark("memory.tick.baseline.720x100") {
        var next = samples.last!; next.id = "old\(count)"; next.capturedAt = origin.addingTimeInterval(Double(count * 5)); count += 1
        try baseline.save(next)
        let loaded = try baseline.load(since: next.capturedAt.addingTimeInterval(-3600))
        _ = BaselineMemoryAnalyzer.analyze(loaded)
    }
    let rollingStore = try MemoryStore(url: root.appendingPathComponent("rolling.sqlite3"))
    for snapshot in samples { try rollingStore.save(snapshot) }
    count = 720
    try benchmark("memory.tick.current.720x100") {
        var next = samples.last!; next.id = "new\(count)"; next.capturedAt = origin.addingTimeInterval(Double(count * 5)); count += 1
        try rollingStore.save(next)
        precondition(rolling.advance(saved: next, since: next.capturedAt.addingTimeInterval(-3600)))
    }
    // Exercise mutations, missing measurements, exits and timestamp collisions.
    for seed in 0..<24 {
        let history = (0..<35).map { index -> MemorySnapshot in
            var point = samples[index]
            point.capturedAt = origin.addingTimeInterval(Double(index * (seed % 3 == 0 ? 0 : 60)))
            point.processes = Array(point.processes.prefix(8))
            for process in point.processes.indices { point.processes[process].footprintBytes += UInt64(index * 12) * 1_048_576 }
            if index == seed { point.processes.removeLast(); point.unavailablePIDs = [1007] }
            if index > seed + 10 { point.processes[0].startTimeTicks = 2 }
            if index == seed + 3 { point.warnings = ["fixture warning"] }
            if seed % 4 == 0 && index > 20 { point.processes[1].bootID = "replacement-boot" }
            if seed % 5 == 0 { point.processes.append(point.processes[2]) }
            if seed % 7 == 0 && index == 16 { point.unavailablePIDs.append(1006) }
            return point
        }
        let oldJSON = try MemoryJSON.encoder().encode(BaselineMemoryAnalyzer.analyze(history))
        let currentJSON = try MemoryJSON.encoder().encode(MemoryAnalyzer.analyze(history))
        precondition(oldJSON == currentJSON)
    }
    let metadataStore = try MemoryStore(url: root.appendingPathComponent("metadata.sqlite3"))
    let longPath = "/Applications/" + String(repeating: "性能元数据目录/", count: 24) + "Fixture.app/Contents/MacOS/Fixture"
    for var snapshot in samples {
        for index in snapshot.processes.indices { snapshot.processes[index].executable = longPath }
        try metadataStore.save(snapshot)
    }
    print("PASS release benchmark and 25 complete analysis equivalence fixtures")
}
do { try runBenchmarks() } catch { fputs("MEMORY BENCHMARK FAILED: \(error)\n", stderr); exit(1) }
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--benchmark", action="store_true", help="Compare checked-in baseline with production using temporary synthetic histories")
    parser.add_argument("--baseline-ref", default="b4d93ef", help="Git reference for the pre-optimization implementations")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("ai_checks", project / "scripts/check-desktop-ai.py")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    release, objects = helper.release_inputs(project)
    source = (project / "Sources/GPTMemoryDesktop/DesktopModel.swift").read_text()
    update = source[source.index("private struct DesktopUpdate"):source.index("@MainActor")]
    service = source[source.index("private final class DesktopSamplingService"):]
    with tempfile.TemporaryDirectory(prefix="gpt-desktop-memory-checks-") as temporary:
        root = Path(temporary)
        main = root / "main.swift"
        baseline = ""
        if args.benchmark:
            def checked_in(name):
                return subprocess.run(["git", "show", f"{args.baseline_ref}:Sources/GPTMemoryCore/{name}"],
                    cwd=project, check=True, capture_output=True, text=True).stdout
            old_store = checked_in("MemoryStore.swift").replace("public ", "")
            old_store = old_store.replace("MemoryStoreReadMetrics", "BaselineMemoryStoreReadMetrics").replace("class MemoryStore", "class BaselineMemoryStore")
            old_analysis = checked_in("Analysis.swift")
            old_interpreter = checked_in("AnalysisExplanation.swift")
            # Imported public Codable structs expose no memberwise initializer.
            # Keep the checked-in result types beside its analyzer, renaming only
            # symbols so both implementations compile independently and their
            # complete serialized results can be compared byte for byte.
            names = re.findall(r"(?:public )?(?:enum|struct) (\w+)", old_analysis + old_interpreter)
            rename = re.compile(r"\b(" + "|".join(re.escape(name) for name in names) + r")\b")
            old_analysis = rename.sub(lambda match: "Baseline" + match.group(), old_analysis)
            old_interpreter = rename.sub(lambda match: "Baseline" + match.group(), old_interpreter)
            baseline = "\n" + old_store + "\n" + old_analysis + "\n" + old_interpreter + BENCHMARK
        footprint_entry = ""
        if args.benchmark:
            footprint_entry = '''
if let variant = ProcessInfo.processInfo.environment["GPT_MEMORY_FOOTPRINT_VARIANT"] {
    do { try runFootprintProbe(variant); exit(0) }
    catch { fputs("MEMORY FOOTPRINT FAILED: \\(error)\\n", stderr); exit(1) }
}
'''
        main.write_text("import Foundation\nimport Darwin\nimport GPTMemoryCore\n" + update + service + footprint_entry + CHECKS + baseline)
        executable = root / "memory-checks"
        # Production resolves its bundled CLI or a sibling executable. This
        # sibling deliberately delays without reading any database or report.
        mock_cli = root / "gpt-mem"
        mock_cli.write_text("#!/bin/sh\nexec /bin/sleep 0.8\n")
        mock_cli.chmod(0o700)
        command = ["swiftc", "-O", "-swift-version", "5", "-target", f"{platform.machine()}-apple-macosx14.0",
                   "-module-cache-path", str(root / "module-cache"), "-I", str(release / "Modules"),
                   "-I", str(release / "CNative.build"), "-o", str(executable), str(main)]
        command += [str(obj) for obj in objects] + ["-lproc", "-lsqlite3"]
        subprocess.run(command, check=True, timeout=60)
        environment = os.environ.copy()
        environment["GPT_MEMORY_CHECK_DIR"] = str(root / "fixtures")
        subprocess.run([str(executable)], env=environment, check=True, timeout=30)
        if args.benchmark:
            for variant in ["baseline", "current"]:
                environment["GPT_MEMORY_FOOTPRINT_VARIANT"] = variant
                subprocess.run([str(executable)], env=environment, check=True, timeout=30)


if __name__ == "__main__":
    main()
