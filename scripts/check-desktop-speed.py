#!/usr/bin/env python3
"""Temporary desktop-log fixtures; optional live metadata-only observation, never model requests."""
from pathlib import Path
import argparse, importlib.util, os, platform, subprocess, tempfile
SWIFT = r'''
import Foundation
import AppKit
import SwiftUI
import GPTSessionKit
struct Failure: Error { let text: String }
var assertions = 0
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ text: String) throws { assertions += 1; if !condition() { throw Failure(text: text) } }
@MainActor func run() async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SPEED_FIXTURE"]!)
    let date = Date().addingTimeInterval(-30)
    let folderFormat = DateFormatter(); folderFormat.dateFormat = "yyyy/MM/dd"; folderFormat.timeZone = TimeZone(secondsFromGMT: 0)
    let folder = root.appendingPathComponent("sessions/" + folderFormat.string(from: Date()))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func record(_ seconds: Double, _ type: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["timestamp": iso.string(from: date.addingTimeInterval(seconds)), "type": type, "payload": payload]); data.append(10); return data
    }
    var data = try record(0, "session_meta", ["id": "fixture-session", "originator": "Codex Desktop"])
    data += try record(0, "turn_context", ["model": "fixture-model"])
    data += try record(0, "event_msg", ["type": "task_started", "turn_id": "fixture-turn"])
    data += try record(10, "event_msg", ["type": "token_count", "info": ["total_token_usage": ["output_tokens": 100, "reasoning_output_tokens": 20], "last_token_usage": ["output_tokens": 100, "reasoning_output_tokens": 20]]])
    let file = folder.appendingPathComponent("fixture.jsonl"); try data.write(to: file)
    let model = DesktopSpeedModel(root: root)
    await model.refresh()
    try expect(model.snapshot.samples.count == 1, "metadata parsed")
    try expect(model.snapshot.samples.first?.intervalRate == 10, "wall interval rate")
    try expect(!model.isMonitoring, "manual refresh doesn't enable polling")
    model.start(); try expect(model.isMonitoring, "start listener")
    try await Task.sleep(nanoseconds: 100_000_000)
    model.stop(); try expect(!model.isMonitoring, "stop listener")
    await model.refresh()
    try expect(model.snapshot.samples.count == 1, "refresh never duplicates records")
    let unchanged = try Data(contentsOf: file)
    try expect(unchanged == data, "source never written")
    if let output = ProcessInfo.processInfo.environment["SPEED_RENDER"] {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let host = NSHostingView(rootView: DesktopSpeedView(model: model).padding(20).background(MemoryStyle.background).foregroundStyle(MemoryStyle.text).preferredColorScheme(.light))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false); window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(text: "render") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(text: "png") }
        let url = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url); model.stop(); window.close()
    }
    print("PASS desktop speed: \(assertions) checks; temporary logs, zero model requests")
    if ProcessInfo.processInfo.environment["SPEED_BENCHMARK"] == "1" {
        let noise = try record(5, "event_msg", ["type": "agent_message", "message": String(repeating: "x", count: 65536)])
        var large = try record(0, "session_meta", ["id": "benchmark", "originator": "Codex Desktop"])
        large += try record(0, "turn_context", ["model": "fixture-model"])
        large += try record(0, "event_msg", ["type": "task_started"])
        for _ in 0..<192 { large += noise }
        large += try record(10, "event_msg", ["type": "token_count", "info": ["total_token_usage": ["output_tokens": 100], "last_token_usage": ["output_tokens": 100]]])
        try large.write(to: file)
        var durations: [Double] = []
        for _ in 0..<3 {
            let reader = DesktopSpeedReader(rootURL: root)
            let begin = ProcessInfo.processInfo.systemUptime
            var snapshot = try reader.read()
            while snapshot.pendingFiles > 0 { snapshot = try reader.read() }
            try expect(snapshot.samples.count == 1, "benchmark preserves usage after large message lines")
            durations.append(ProcessInfo.processInfo.systemUptime - begin)
        }
        let reader = DesktopSpeedReader(rootURL: root)
        while try reader.read().pendingFiles > 0 {}
        let begin = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 { _ = try reader.read() }
        print("BENCHMARK bytes=\(large.count) median-catchup-ms=\(durations.sorted()[1] * 1000) idle-refresh-ms=\((ProcessInfo.processInfo.systemUptime - begin) * 50)")
    }
    if ProcessInfo.processInfo.environment["SPEED_LIVE"] == "1" {
        let live = DesktopSpeedReader()
        var snapshot = DesktopSpeedSnapshot()
        for _ in 0..<16 { snapshot = try live.read(); if snapshot.pendingFiles == 0 { break } }
        print("LIVE metadata: files=\(snapshot.files) intervals=\(snapshot.samples.count) pending=\(snapshot.pendingFiles)")
        for name in Set(snapshot.samples.map(\.model)).sorted() {
            let values = snapshot.samples.filter { $0.model == name }.map(\.intervalRate).sorted()
            print("model=\(name) intervals=\(values.count) median-interval-output-rate=\(values[values.count / 2])")
        }
    }
}
Task { @MainActor in do { try await run(); exit(0) } catch { print("FAIL \(error)"); exit(1) } }
RunLoop.main.run()
'''
def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--render'); parser.add_argument('--live', action='store_true'); parser.add_argument('--benchmark', action='store_true'); args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('helper', project/'scripts/check-desktop-ai.py'); helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
    release, objects = helper.release_inputs(project)
    with tempfile.TemporaryDirectory(prefix='desktop-speed-check-') as temp:
        folder = Path(temp); source=folder/'main.swift'; source.write_text(SWIFT); binary=folder/'checks'
        command=['swiftc','-swift-version','5','-target',f'{platform.machine()}-apple-macosx14.0','-module-cache-path',str(folder/'cache'),'-I',str(release/'Modules'),'-I',str(release/'CNative.build'),'-o',str(binary)]
        command += [str(project/'Sources/GPTMemoryDesktop'/name) for name in ['DesktopSpeedModel.swift','DesktopSpeedViews.swift','Style.swift']] + [str(source)] + [str(obj) for obj in objects] + ['-lproc','-lsqlite3']
        subprocess.run(command, check=True, timeout=90)
        env=os.environ.copy(); env['SPEED_FIXTURE']=str(folder/'fixtures')
        if args.render: env['SPEED_RENDER']=str(Path(args.render).resolve())
        if args.live: env['SPEED_LIVE']='1'
        if args.benchmark: env['SPEED_BENCHMARK']='1'
        subprocess.run([str(binary)],env=env,check=True,timeout=60)
if __name__=='__main__': main()
