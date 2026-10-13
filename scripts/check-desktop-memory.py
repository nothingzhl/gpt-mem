#!/usr/bin/env python3
"""Check the production sampling service with synthetic samples and slow local helpers.

Only temporary databases, an injected diagnostic, and a fake export component are
used. No native process inspection, real vmmap, credentials, or model calls occur.
"""
from pathlib import Path
import importlib.util
import os
import platform
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
    var state: (count: Int, paused: Bool, diagnosticStarted: Bool, diagnosticDone: Bool, exportDone: Bool, errors: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (count, paused, diagnosticStarted, diagnosticDone, exportDone, errors)
    }
    func sample() -> MemorySnapshot {
        lock.lock(); count += 1; let index = count; lock.unlock()
        return MemorySnapshot(id: String(index), capturedAt: Date(), processes: [])
    }
    func update(_ update: DesktopUpdate) {
        lock.lock(); defer { lock.unlock() }
        paused = update.mode == "已暂停"
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
    print("DESKTOP MEMORY CHECKS PASSED: 2 workflows, \(assertions) assertions; synthetic samples only")
} catch {
    fputs("DESKTOP MEMORY CHECK FAILED: \(error)\n", stderr); exit(1)
}
'''


def main():
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
        main.write_text("import Foundation\nimport Darwin\nimport GPTMemoryCore\n" + update + service + CHECKS)
        executable = root / "memory-checks"
        # Production resolves its bundled CLI or a sibling executable. This
        # sibling deliberately delays without reading any database or report.
        mock_cli = root / "gpt-mem"
        mock_cli.write_text("#!/bin/sh\nexec /bin/sleep 0.8\n")
        mock_cli.chmod(0o700)
        command = ["swiftc", "-swift-version", "5", "-target", f"{platform.machine()}-apple-macosx14.0",
                   "-module-cache-path", str(root / "module-cache"), "-I", str(release / "Modules"),
                   "-I", str(release / "CNative.build"), "-o", str(executable), str(main)]
        command += [str(obj) for obj in objects] + ["-lproc", "-lsqlite3"]
        subprocess.run(command, check=True, timeout=60)
        environment = os.environ.copy()
        environment["GPT_MEMORY_CHECK_DIR"] = str(root / "fixtures")
        subprocess.run([str(executable)], env=environment, check=True, timeout=15)


if __name__ == "__main__":
    main()
