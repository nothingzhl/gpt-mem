#!/usr/bin/env python3
"""Check the real process-action model using injected samplers/signals only."""
from pathlib import Path
import argparse
import importlib.util
import os
import platform
import subprocess
import tempfile

CHECKS = r'''
import Foundation
import AppKit
import Darwin
import GPTMemoryCore

struct CheckFailure: Error { let message: String }
var assertions = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    assertions += 1
    if !value() { throw CheckFailure(message: message) }
}
@MainActor func waitFor(_ predicate: () -> Bool, _ message: String) async throws {
    let end = Date().addingTimeInterval(3)
    while !predicate() {
        if Date() >= end { throw CheckFailure(message: message) }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
final class Fixture: @unchecked Sendable {
    let lock = NSLock()
    let root = ProcessSample(bootID: "fixture", pid: 123455, parentPID: 1, startTimeTicks: 1,
        startedAt: Date(timeIntervalSince1970: 1), executable: "/Applications/Codex.app/Contents/MacOS/Codex",
        role: .appMain, rootKey: "fixture:123455:1", footprintBytes: 100 * 1024 * 1024)
    let target = ProcessSample(bootID: "fixture", pid: 123456, parentPID: 123455, startTimeTicks: 2,
        startedAt: Date(timeIntervalSince1970: 2), executable: "/runtime/node", role: .toolWorker,
        rootKey: "fixture:123455:1", footprintBytes: 200 * 1024 * 1024)
    var hold = false, exited = false, refuse = false, unreadable = false
    var sends: [ProcessExitKind] = []
    var controllerReads = 0, failAfterRead = 0
    var clock = Date().addingTimeInterval(-10)
    var count: Int { lock.lock(); defer { lock.unlock() }; return sends.count }
    func snapshot() -> MemorySnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(processes: exited ? [root] : [root, target])
    }
    func control() -> ProcessControl {
        ProcessControl(sample: {
            self.lock.lock(); self.controllerReads += 1
            let fails = self.failAfterRead > 0 && self.controllerReads > self.failAfterRead
            self.lock.unlock()
            if fails { throw MemoryError.message("fixture observation failure") }
            return self.snapshot()
        }, read: { _ in
            self.lock.lock(); defer { self.lock.unlock() }
            if self.unreadable { return .unavailable }
            if self.refuse { return .found(.init(birth: 3, executable: self.target.executable)) }
            return self.exited ? .missing : .found(.init(birth: 2, executable: self.target.executable))
        }, send: { _, kind in
            self.lock.lock(); defer { self.lock.unlock() }
            self.sends.append(kind)
            if !self.hold || kind == .force { self.exited = true }
        }, protectedPIDs: [1], now: {
            self.lock.lock(); defer { self.lock.unlock() }; return self.clock
        })
    }
    func advance() { lock.lock(); clock = clock.addingTimeInterval(20); lock.unlock() }
}
@MainActor func model(_ fixture: Fixture, _ path: URL) -> MemoryProcessActionsModel {
    .init(directoryURL: path, control: fixture.control(), observationDelays: [0.01, 0.02, 0.03])
}
@MainActor func idle(_ model: MemoryProcessActionsModel) async throws {
    try await waitFor({ !model.hasPendingWork }, "action/observation/persistence did not complete")
}
@MainActor func runChecks() async throws {
    let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GPT_ACTION_CHECK_DIR"]!)
    let fixture = Fixture(), state = model(fixture, base.appendingPathComponent("successful"))
    var reused = fixture.target; reused.startTimeTicks += 1
    let trend = [MemorySnapshot(processes: [reused]), MemorySnapshot(processes: [], unavailablePIDs: [fixture.target.pid]), fixture.snapshot()]
    state.prepare(fixture.target, kind: .request, snapshot: fixture.snapshot(), history: trend)
    try expect(state.pending?.process.key == fixture.target.key && fixture.count == 0, "preparing confirmation never sends a signal")
    try expect(state.pending?.trend.count == 3 && state.pending?.trend[0].footprintBytes == nil
        && state.pending?.trend[1].footprintBytes == nil && state.pending?.trend[2].footprintBytes == fixture.target.footprintBytes,
        "frozen trend preserves gaps and excludes a reused PID")
    state.pending = nil
    state.confirm()
    try expect(fixture.count == 0, "cancelled confirmation never acts")
    state.prepare(fixture.target, kind: .request, snapshot: fixture.snapshot(), history: trend)
    state.confirm(); state.confirm()
    try await idle(state)
    try expect(fixture.count == 1 && state.records.count == 1, "duplicate confirmation cannot submit twice")
    try expect(state.records.first?.observation?.state == .exited, "an accepted request is subsequently verified as exited")
    try expect(state.records.first?.observation?.knownTotalChange == -200 * 1024 * 1024, "measured before/after counters are preserved")
    let files = try FileManager.default.contentsOfDirectory(at: state.directoryURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    try expect(files.count == 1, "progress updates replace one owned operation record: files=\(files.count), error=\(state.recordError ?? "none")")
    let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
    try expect(permissions?.intValue == 0o600, "records are private 0600 files")
    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: state.directoryURL.path)[.posixPermissions] as? NSNumber
    try expect(directoryPermissions?.intValue == 0o700, "record directory is private 0700")
    let reopened = model(Fixture(), state.directoryURL)
    try await waitFor({ reopened.records.count == 1 }, "stored action did not reopen")
    try expect(reopened.records.first?.observation?.state == .exited, "effect records persist across model reopening")
    try expect(reopened.records.first?.trend?.count == 3, "frozen target trend persists with the action")
    print("PASS confirmation/cancel, duplicate submission, verified effects and private persistence/reopening")

    let refusing = Fixture(); refusing.refuse = true
    let refused = model(refusing, base.appendingPathComponent("refused"))
    refused.prepare(refusing.target, kind: .request, snapshot: refusing.snapshot()); refused.confirm()
    try await idle(refused)
    try expect(refusing.count == 0 && refused.records.isEmpty && refused.message != nil, "PID identity failure never signals or records success")
    print("PASS stale identity refusal and truthful failed-operation state")

    let held = Fixture(); held.hold = true
    let force = model(held, base.appendingPathComponent("force"))
    force.prepare(held.target, kind: .force, snapshot: held.snapshot())
    try expect(force.pending == nil && held.count == 0, "force is unavailable before a normal request")
    force.prepare(held.target, kind: .request, snapshot: held.snapshot()); force.confirm()
    try expect(!force.canForce(held.target), "force is unavailable while checking the first request")
    try await idle(force); held.advance()
    try expect(force.canForce(held.target), "verified surviving instance permits separate force confirmation")
    let diagnostic = DiagnosticResult(pid: held.target.pid, outputPath: base.appendingPathComponent("fixture-summary.txt").path,
        exitCode: 0, timedOut: false, partial: false)
    force.recordDiagnostic(process: held.target, snapshot: held.snapshot(), history: [held.snapshot()], result: diagnostic)
    try await idle(force)
    try expect(force.canForce(held.target), "a diagnostic record does not hide the prior exit receipt")
    force.prepare(held.target, kind: .force, snapshot: held.snapshot()); force.confirm()
    try await idle(force)
    try expect(held.count == 2 && force.records.first?.receipt?.kind == .force,
               "force uses the retained normal receipt and submits once")
    try expect(force.records.first?.observation?.state == .exited && !force.canForce(held.target), "force completion is measured and is not automatically repeated")
    try expect(force.records.contains { $0.diagnostic != nil && $0.diagnosticSnapshot != nil }, "diagnostics retain their snapshot context")
    try expect(force.records.first(where: { $0.diagnostic != nil })?.trend?.first?.footprintBytes == held.target.footprintBytes,
               "diagnostics preserve the selected instance's recent trend")
    print("PASS force gating, separate confirmation, diagnostic context and same-instance outcome")

    let brokenDirectory = base.appendingPathComponent("blocked")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: brokenDirectory)
    let logging = Fixture(), logFailure = model(logging, brokenDirectory)
    logFailure.prepare(logging.target, kind: .request, snapshot: logging.snapshot()); logFailure.confirm()
    try await idle(logFailure)
    try expect(logging.count == 1 && logFailure.records.first?.observation?.state == .exited,
               "logging failure cannot undo or repeat an already accepted request")
    try expect(logFailure.recordError != nil, "logging errors remain visible after later observations")
    print("PASS persistence failure preserves accepted operation state without retrying signals")

    let failedObservation = Fixture(); failedObservation.hold = true; failedObservation.failAfterRead = 2
    let uncertain = model(failedObservation, base.appendingPathComponent("uncertain"))
    uncertain.prepare(failedObservation.target, kind: .request, snapshot: failedObservation.snapshot()); uncertain.confirm()
    try await idle(uncertain)
    try expect(uncertain.records.first?.observation?.state == .running && uncertain.records.first?.observationFailed == true,
               "later failed checks mark the prior live observation as stale")
    try expect(!uncertain.canForce(failedObservation.target) && failedObservation.count == 1,
               "a failed final check cannot enable force or repeat the original request")
    print("PASS final observation failures invalidate earlier live status and keep force disabled")

    print("PROCESS ACTION CHECKS PASSED: 5 workflows, \(assertions) assertions; all signals mocked")
    #if RENDER_ACTIONS
    if let output = ProcessInfo.processInfo.environment["GPT_ACTION_RENDER_DIR"] {
        try await render(force, held, output: URL(fileURLWithPath: output))
    }
    #endif
}
#if RENDER_ACTIONS
@MainActor func render(_ state: MemoryProcessActionsModel, _ fixture: Fixture, output: URL) async throws {
    _ = NSApplication.shared; NSApplication.shared.setActivationPolicy(.prohibited)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let snapshot = MemorySnapshot(processes: [fixture.root, fixture.target])
    let request = MemoryProcessActionRequest(process: fixture.target, kind: .request, relatedProcessCount: 1)
    let force = MemoryProcessActionRequest(process: fixture.target, kind: .force, relatedProcessCount: 1)
    let content: [(String, AnyView, CGFloat, CGFloat)] = [
        ("process-actions-preview.png", AnyView(ProcessesContent(snapshot: snapshot, selectedRole: .constant(nil), isBusy: false,
            focusedKey: .constant(fixture.target.key), actions: state, initiallyExpandedActionHistory: true, onDiagnose: { _ in })), 888, 620),
        ("process-actions-narrow-preview.png", AnyView(ProcessesContent(snapshot: snapshot, selectedRole: .constant(nil), isBusy: false,
            focusedKey: .constant(fixture.target.key), actions: state, initiallyExpandedActionHistory: true, onDiagnose: { _ in })), 728, 520),
        ("process-exit-confirmation-preview.png", AnyView(MemoryProcessActionConfirmation(model: state, request: request)), 558, 470),
        ("process-force-confirmation-preview.png", AnyView(MemoryProcessActionConfirmation(model: state, request: force)), 558, 520)]
    for (name, view, width, height) in content {
        let hosting = NSHostingView(rootView: view.padding(12).frame(width: width, height: height)
            .background(MemoryStyle.background).foregroundStyle(MemoryStyle.text).tint(MemoryStyle.accent)
            .disclosureGroupStyle(WideDisclosureGroupStyle()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 100_000_000); hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CheckFailure(message: "render failed") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure(message: "PNG failed") }
        try png.write(to: output.appendingPathComponent(name)); window.close()
        print("RENDER \(name)")
    }
}
#endif
Task { @MainActor in
    do { try await runChecks(); exit(0) }
    catch { fputs("PROCESS ACTION CHECK FAILED: \(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--render', action='store_true')
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('desktop_helper', project / 'scripts/check-desktop-ai.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    release, objects = helper.release_inputs(project)
    desktop = project / 'Sources/GPTMemoryDesktop'
    with tempfile.TemporaryDirectory(prefix='gpt-process-action-checks-') as temporary:
        directory = Path(temporary)
        source = directory / 'main.swift'
        source.write_text(('import SwiftUI\n' if args.render else '') + CHECKS)
        executable = directory / 'checks'
        sources = [desktop / 'MemoryProcessActionsModel.swift']
        if args.render:
            sources += [desktop / name for name in ['MemoryProcessActionViews.swift', 'DesktopModel.swift', 'Views.swift', 'AIViews.swift',
                'AIReportViews.swift', 'AIProviderEditorModel.swift', 'DesktopAIModel.swift', 'AIReportLibraryModel.swift', 'Style.swift',
                'SessionDesktopModel.swift', 'SessionManagementModel.swift', 'SessionManagementViews.swift', 'SessionViews.swift', 'SessionProjectViews.swift']]
        command = ['swiftc', '-swift-version', '5', '-target', f'{platform.machine()}-apple-macosx14.0',
            '-module-cache-path', str(directory / 'module-cache'), '-I', str(release / 'Modules'), '-I', str(release / 'CNative.build'),
            '-o', str(executable)]
        if args.render:
            command += ['-D', 'RENDER_ACTIONS']
        command += list(map(str, sources)) + [str(source)] + list(map(str, objects)) + ['-lproc', '-lsqlite3']
        subprocess.run(command, check=True, cwd=project, timeout=90)
        environment = os.environ.copy()
        environment['GPT_ACTION_CHECK_DIR'] = str(directory / 'fixtures')
        if args.render:
            environment['GPT_ACTION_RENDER_DIR'] = str(project / 'reports')
        subprocess.run([str(executable)], check=True, cwd=project, env=environment, timeout=20)


if __name__ == '__main__':
    main()
