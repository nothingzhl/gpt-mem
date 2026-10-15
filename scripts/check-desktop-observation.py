#!/usr/bin/env python3
"""Verify production root observation with isolated application data and no collector."""
from pathlib import Path
import importlib.util
import os
import platform
import subprocess
import tempfile

CHECKS = r'''
import Foundation
import Observation
import GPTMemoryCore

final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

@MainActor func run() async throws {
    let model = DesktopModel()
    let workspace = Changes(), sidebar = Changes(), memory = Changes()
    withObservationTracking {
        _ = model.knowledgeModel
        _ = model.isKnowledgeWorkspaceActive
    } onChange: { workspace.increment() }
    withObservationTracking {
        _ = model.modeLabel
        _ = model.isMonitoring
    } onChange: { sidebar.increment() }
    withObservationTracking { _ = model.snapshot } onChange: { memory.increment() }
    let begin = ProcessInfo.processInfo.systemUptime
    for index in 0..<100 {
        let snapshot = MemorySnapshot(id: "fixture-\(index)", processes: [])
        model.snapshot = snapshot
        model.history = [snapshot]
        model.analysis = nil
        model.modeLabel = "准备就绪"
        model.isMonitoring = false
        model.isBusy = false
    }
    let updatesMS = (ProcessInfo.processInfo.systemUptime - begin) * 1000
    precondition(workspace.count == 0, "background samples invalidated the knowledge workspace")
    precondition(sidebar.count == 0, "unchanged status invalidated the sidebar")
    precondition(memory.count == 1, "memory observers missed a changed sample")
    model.isKnowledgeWorkspaceActive = true
    precondition(workspace.count == 1, "navigation observers missed page activation")
    model.modeLabel = "正在采集"
    precondition(sidebar.count == 1, "sidebar observers missed status change")
    let start = Date(timeIntervalSince1970: 1_791_900_000)
    let end = start.addingTimeInterval(600)
    model.aiModel.updateWindow(start: start, end: end, selectionSeconds: 1800)
    model.setMemoryWorkspaceActive(false)
    try await Task.sleep(nanoseconds: 50_000_000)
    precondition(model.history.isEmpty && model.analysis == nil, "hidden page retained its history window")
    precondition(model.aiModel.currentWindowStart == start && model.aiModel.currentWindowEnd == end,
                 "releasing hidden history invalidated the frozen AI window")
    let store = try MemoryStore(url: model.databaseURL)
    try store.save(.init(id: "older", capturedAt: Date().addingTimeInterval(-5), processes: []))
    try store.save(.init(id: "newer", processes: []))
    model.setMemoryWorkspaceActive(true)
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while model.memorySampleCount != 2 {
        precondition(ProcessInfo.processInfo.systemUptime < deadline, "history did not reload on navigation")
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    model.setMemoryWorkspaceActive(false)
    while !model.history.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
    precondition(model.memorySampleCount == 2, "hidden page disabled the independently loaded report exporter")
    print("PASS root observation: 100 sample updates, zero unrelated workspace/status invalidations; genuine changes delivered")
    print("PASS hidden window releases history, retains frozen AI window/export eligibility, and reloads on navigation")
    print(String(format: "ROOT 100-updates-ms=%.3f", updatesMS))
}
Task { @MainActor in
    do { try await run(); exit(0) }
    catch { fputs("FAIL \(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
'''


def main():
    project = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("helper", project / "scripts/check-desktop-ai.py")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    release, objects = helper.release_inputs(project)
    with tempfile.TemporaryDirectory(prefix="desktop-observation-") as temporary:
        root = Path(temporary)
        main_file = root / "main.swift"
        main_file.write_text(CHECKS)
        sources = [project / "Sources/GPTMemoryDesktop" / name for name in [
            "DesktopModel.swift", "DesktopAIModel.swift", "PromptTemplateLibraryModel.swift",
            "AIReportLibraryModel.swift", "SessionDesktopModel.swift", "SessionManagementModel.swift",
            "DesktopSpeedModel.swift", "KnowledgeDesktopModel.swift", "MemoryProcessActionsModel.swift"]]
        executable = root / "checks"
        command = ["swiftc", "-O", "-swift-version", "5", "-target",
                   f"{platform.machine()}-apple-macosx14.0", "-module-cache-path", str(root / "cache"),
                   "-I", str(release / "Modules"), "-I", str(release / "CNative.build"),
                   "-o", str(executable)]
        subprocess.run(command + list(map(str, sources)) + [str(main_file)]
                       + list(map(str, objects)) + ["-lproc", "-lsqlite3"], check=True, timeout=180)
        environment = os.environ.copy()
        environment["GPT_MEM_HOME"] = str(root / "application-data")
        subprocess.run([str(executable)], env=environment, check=True, timeout=15)


if __name__ == "__main__":
    main()
