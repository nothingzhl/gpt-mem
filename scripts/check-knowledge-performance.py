#!/usr/bin/env python3
"""Benchmark real memory search and long-text rendering with private synthetic fixtures.

--baseline-ref compares the desktop search against that Git revision. All fixture
files live in a temporary directory; no user memories, network or shared clipboard.
"""
from pathlib import Path
import argparse
import importlib.util
import platform
import re
import subprocess
import tempfile

SWIFT = r'''
import Foundation
import AppKit
import SwiftUI
import CNative
import GPTAnalysisKit
import GPTSessionKit
struct Failure: Error { let message: String }
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func report(_ name: String, _ samples: [Double]) {
    print("KNOWLEDGE \(name) median-ms=\(String(format: "%.3f", samples.sorted()[samples.count/2])) max-ms=\(String(format: "%.3f", samples.max()!))")
}
func measure(_ name: String, _ operation: () throws -> Void) rethrows {
    var samples: [Double] = []
    for _ in 0..<7 { let begin = now(); try autoreleasepool { try operation() }; samples.append((now()-begin)*1000) }
    report(name, samples)
}
func footprint() -> UInt64 { var info = gpt_process_info(); return gpt_read_process(getpid(), &info) == 0 ? info.footprint_bytes : 0 }
@MainActor func settled(_ busy: () -> Bool) async throws {
    let deadline = now()+10
    while busy() { if now() > deadline { throw Failure(message: "search timeout") }; try await Task.sleep(nanoseconds: 1_000_000) }
}
@MainActor func queryProbe(_ prefix: String, set: (String) -> Void, busy: () -> Bool, counts: () -> (Int, Int)) async throws {
    for (name, query, expected) in [("no-hit", "不存在这个规则", 0), ("case-hit", "PeRfOrMaNcE", 200), ("unicode-hit", "中文", 200)] {
        var samples: [Double] = []
        for _ in 0..<5 {
            set(""); try await settled(busy)
            let begin = now(); set(query); try await settled(busy); samples.append((now()-begin)*1000)
            guard counts().0 == expected else { throw Failure(message: "wrong search result \(name)") }
        }
        report(prefix+".search."+name, samples)
    }
    let begin = now()
    for i in 0..<40 { set("cancelled-\(i)") }
    set("中文"); try await settled(busy)
    guard counts().0 == 200 && counts().1 == 16 else { throw Failure(message: "cancelled search published stale result") }
    report(prefix+".search.rapid-40", [(now()-begin)*1000])
    let clear = now(); set(""); try await settled(busy)
    report(prefix+".search.clear", [(now()-clear)*1000])
}
@MainActor func run() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1]), mode = CommandLine.arguments[2]
    let text = "# 长期规则\n" + (0..<420).map { "- 原始记忆 \($0) 中文 performance\n  " + String(repeating: "保留事实，检查性能与来源；", count: 7) + "\n\n" }.joined()
    if mode.hasPrefix("text-") {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let before = footprint()
        let start = now()
        let content = mode == "text-native" ? AnyView(KnowledgeTextView(text: text, monospaced: true).equatable()) : AnyView(ScrollView { Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) })
        let host = NSHostingView(rootView: content.padding(12).preferredColorScheme(.light))
        host.frame = .init(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let cold = (now()-start)*1000
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        var resize: [Double] = []
        for _ in 0..<7 { let begin=now(); host.frame.size.width += 1; host.needsLayout=true; host.layoutSubtreeIfNeeded(); resize.append((now()-begin)*1000) }
        if mode == "text-native" {
            func findText(_ view: NSView) -> NSTextView? { if let text = view as? NSTextView { return text }; for child in view.subviews { if let match = findText(child) { return match } }; return nil }
            guard let view = findText(host), view.string == text, view.textLayoutManager != nil else { throw Failure(message: "complete native TextKit 2 text missing") }
            guard let scroll = view.enclosingScrollView, scroll.contentSize.width > 700, scroll.contentSize.height > 400,
                  view.frame.width >= scroll.contentSize.width - 1, view.frame.height > scroll.contentSize.height else {
                throw Failure(message: "native text viewport/document dimensions are invalid: \(view.frame)")
            }
            let tail = (text as NSString).length-10
            let begin=now(); view.scrollRangeToVisible(.init(location: tail, length: 10)); view.setSelectedRange(.init(location: tail, length: 10)); host.layoutSubtreeIfNeeded()
            guard view.selectedRange().location == tail, view.string == text else { throw Failure(message: "tail selection lost") }
            guard scroll.contentView.bounds.origin.y > 0 else { throw Failure(message: "tail scroll did not move viewport") }
            report("text-native.scroll-tail", [(now()-begin)*1000])
            print("PASS native complete text, nonzero viewport and scrollable document, tail selection")
            // Exercise native copy without overwriting the user's general clipboard.
            let pasteboard = NSPasteboard.withUniqueName()
            if view.writeSelection(to: pasteboard, types: [.string]) {
                guard pasteboard.string(forType: .string) == (text as NSString).substring(from: tail) else { throw Failure(message: "native copy lost selected text") }
                print("PASS native tail copy to isolated pasteboard")
            } else { print("NOTE isolated pasteboard unavailable in this execution environment") }
            let selected = view.selectedRange(), offset = scroll.contentView.bounds.origin
            host.rootView = AnyView(KnowledgeTextView(text: text, monospaced: true).equatable()).padding(12).preferredColorScheme(.light)
            host.layoutSubtreeIfNeeded()
            guard findText(host) === view, view.selectedRange() == selected, scroll.contentView.bounds.origin == offset else {
                throw Failure(message: "unchanged text redraw lost native selection/scroll position")
            }
            let replacement = text + "\n完整更新后的尾部"
            host.rootView = AnyView(KnowledgeTextView(text: replacement, monospaced: true).equatable()).padding(12).preferredColorScheme(.light)
            host.layoutSubtreeIfNeeded()
            guard findText(host) === view, view.string == replacement, view.selectedRange().location == 0,
                  scroll.contentView.bounds.origin.y == 0 else { throw Failure(message: "changed text did not reset native document") }
            print("PASS native unchanged redraw preserves selection/scroll; changed text updates in place and resets viewport")
        }
        report(mode+".cold-layout", [cold]); report(mode+".resize", resize)
        print("KNOWLEDGE \(mode) bytes=\(text.utf8.count) footprint-delta-MiB=\((Double(footprint())-Double(before))/1048576)")
        window.close(); return
    }
    let sources = root.appendingPathComponent("sources"), library = root.appendingPathComponent("library")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try text.write(to: sources.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
    let line = "- 偏好 使用中文回答 分析性能 memory performance data\n  每个项目规则\n"
    let big = String(repeating: line, count: 5500)
    for i in 0..<15 { try big.write(to: sources.appendingPathComponent("fixture-\(i).md"), atomically: true, encoding: .utf8) }
    let origin = Date(timeIntervalSince1970: 1791900000)
    struct FixtureRevision: Codable { let number: Int; let savedAt: Date; let reason: String; let draft: KnowledgeDraft }
    struct FixtureEntry: Codable { let id: String; let versions: [FixtureRevision] }
    let entries = (0..<200).map { i -> FixtureEntry in
        let draft = KnowledgeDraft(title: "记忆\(i)", body: String(repeating: line, count: 375), state: .active)
        return .init(id: draft.id, versions: [.init(number: 1, savedAt: origin.addingTimeInterval(Double(i)), reason: "fixture", draft: draft)])
    }
    struct Document: Codable { var version=2; let entries: [FixtureEntry] }
    let encoder=JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let bytes=try encoder.encode(Document(entries: entries)); try bytes.write(to: library.appendingPathComponent("library.json")); chmod(library.appendingPathComponent("library.json").path, 0o600)
    let beforeIndex = footprint()
    let model=KnowledgeDesktopModel(directoryURL: library, sourceRoot: sources)
    let begin=now(); await model.reload(); await model.readSources(); try await settled { model.isFiltering }
    print("KNOWLEDGE fixture entries=\(model.catalog.entries.count) sources=\(model.sourceCatalog.documents.count) json-bytes=\(bytes.count) read-index-ms=\((now()-begin)*1000)")
    guard model.searchIndexByteCount <= 16 * 1024 * 1024 else { throw Failure(message: "search index exceeds 16 MiB fixture budget") }
    print("KNOWLEDGE index-buffer-bytes=\(model.searchIndexByteCount) model-load-footprint-delta-MiB=\((Double(footprint())-Double(beforeIndex))/1048576)")
    try await queryProbe("current", set: { model.query=$0 }, busy: { model.isFiltering }, counts: { (model.filteredEntries.count, model.filteredSources.count) })
    #if BASELINE
    let baseline = BaselineKnowledgeDesktopModel(directoryURL: library, sourceRoot: sources)
    await baseline.reload(); await baseline.readSources(); try await settled { baseline.isFiltering }
    try await queryProbe("baseline", set: { baseline.query=$0 }, busy: { baseline.isFiltering }, counts: { (baseline.filteredEntries.count, baseline.filteredSources.count) })
    #endif
    let document=model.sourceCatalog.documents.first { $0.relativePath == "MEMORY.md" }!
    try measure("metadata.cached-16-titles-420-labels") {
        let titles=model.sourceCatalog.documents.map(\.title); let labels=document.items.map(\.label)
        guard titles.count == 16 && labels.count == 420 else { throw Failure(message: "metadata") }
    }
    try measure("metadata.legacy-16-titles-420-labels") {
        let titles=model.sourceCatalog.documents.map { $0.text.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? $0.fileURL.lastPathComponent }
        let items=CodexMemoryItem.parse(document.text); let labels=items.map { String(($0.context+" · "+$0.text).prefix(100)) }
        guard titles.count == 16 && labels.count == 420 else { throw Failure(message: "metadata") }
    }
    print("PASS knowledge performance: synthetic fixtures, complete text and latest-query checks")
}
Task { @MainActor in do { try await run(); exit(0) } catch { print("FAIL \(error)"); exit(1) } }
RunLoop.main.run()
'''

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline-ref', help='Git revision containing the pre-optimization desktop model')
    parser.add_argument('--skip-render', action='store_true')
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('helper', project/'scripts/check-desktop-ai.py')
    helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
    release, objects = helper.release_inputs(project)
    with tempfile.TemporaryDirectory(prefix='knowledge-performance-') as tmp:
        temp=Path(tmp); source=temp/'main.swift'; source.write_text(SWIFT); binary=temp/'checks'
        sources=[project/'Sources/GPTMemoryDesktop'/name for name in ['KnowledgeDesktopModel.swift', 'KnowledgeViews.swift', 'KnowledgeExtractionViews.swift', 'DesktopAIModel.swift', 'PromptTemplateLibraryModel.swift', 'AIReportLibraryModel.swift', 'SessionDesktopModel.swift', 'SessionManagementModel.swift', 'AIViews.swift', 'AIReportViews.swift', 'AIProviderEditorModel.swift', 'PromptTemplateViews.swift', 'Style.swift', 'SessionViews.swift', 'SessionProjectViews.swift', 'SessionManagementViews.swift', 'SessionHandoffAIViews.swift']]
        command=['swiftc','-O','-swift-version','5','-target',f'{platform.machine()}-apple-macosx14.0','-module-cache-path',str(temp/'cache'),'-I',str(release/'Modules'),'-I',str(release/'CNative.build'),'-o',str(binary)]
        if args.baseline_ref:
            previous=subprocess.run(['git','show',f'{args.baseline_ref}:Sources/GPTMemoryDesktop/KnowledgeDesktopModel.swift'],cwd=project,text=True,capture_output=True,check=True).stdout
            for name in ['KnowledgeDesktopModel','KnowledgeEditRequest','KnowledgeSnapshot','KnowledgeIO']:
                previous=re.sub(r'\b'+name+r'\b','Baseline'+name,previous)
            baseline=temp/'BaselineKnowledgeDesktopModel.swift'; baseline.write_text(previous); sources.append(baseline); command.append('-DBASELINE')
        subprocess.run(command+list(map(str,sources))+[str(source)]+list(map(str,objects))+['-lproc','-lsqlite3'],cwd=project,check=True,timeout=180)
        for mode in ['search']+([] if args.skip_render else ['text-baseline','text-native']):
            fixture=temp/mode; fixture.mkdir()
            subprocess.run([str(binary),str(fixture),mode],check=True,timeout=90)
if __name__=='__main__': main()
