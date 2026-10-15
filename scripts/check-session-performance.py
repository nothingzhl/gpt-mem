#!/usr/bin/env python3
"""Measure production session state with synthetic data; never reads user logs."""
from pathlib import Path
import argparse
import importlib.util
import os
import platform
import subprocess
import tempfile

SWIFT = r'''
import Foundation
import Combine
import GPTSessionKit
#if SESSION_RENDER
import AppKit
import SwiftUI
import CNative
#endif

struct Failure: Error { let message: String }
@MainActor func waitFor(_ predicate: () -> Bool) async throws {
    let until = ProcessInfo.processInfo.systemUptime + 20
    while !predicate() {
        if ProcessInfo.processInfo.systemUptime > until { throw Failure(message: "operation timed out") }
        try await Task.sleep(nanoseconds: 500_000)
    }
}
func item(_ index: Int) -> CodexSessionSummary {
    .init(id: "fixture-\(index)", sessionID: "session-\(index)",
          fileURL: URL(fileURLWithPath: "/fixture/sessions/\(index).jsonl"),
          title: "模拟会话 \(index)", projectPath: "/fixture/project-\(index % 40)",
          startedAt: Date(timeIntervalSince1970: 1_791_792_000 + Double(index)),
          updatedAt: Date(timeIntervalSince1970: 1_791_792_100 + Double(index)),
          model: "fixture-model", messageCount: 2, tokens: .init(input: 100, output: 20),
          searchText: "fixture indexed prompt", metadataSessionID: "session-\(index)")
}
@MainActor func run() async throws {
    #if SESSION_RENDER
    let mode = CommandLine.arguments.dropFirst().first ?? "state"
    if mode != "state" { try await renderLongMessage(mode); return }
    #endif
    let catalog = (0..<2_000).map(item)
    let state = SessionDesktopModel(rootURL: URL(fileURLWithPath: "/fixture"),
        catalogLoader: { .init(sessions: catalog) }, transcriptLoader: { summary in
            .init(summary: summary, messages: [.init(id: summary.id + "-user", kind: .user, text: "fixture indexed prompt")])
        })
    state.loadIfNeeded()
    try await waitFor { state.hasLoaded && !state.isLoading && !state.isFiltering && state.management.hasLoaded }
    var rebuilds = 0
    let observation = state.$analytics.dropFirst().sink { _ in rebuilds += 1 }
    var detailTimes: [Double] = []
    for index in 0..<30 {
        let start = ProcessInfo.processInfo.systemUptime
        state.select(catalog[catalog.count - index - 1].id)
        try await waitFor { !state.isLoadingTranscript && !state.isFiltering }
        detailTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }
    let start = ProcessInfo.processInfo.systemUptime
    var found = 0
    for _ in 0..<50_000 { if state.selectedSession != nil { found += 1 } }
    guard found == 50_000 else { throw Failure(message: "selected session disappeared") }
    let lookup = (ProcessInfo.processInfo.systemUptime - start) * 1_000
    var publications = 0
    let progressObservation = state.$fullTextScanned.dropFirst().sink { _ in publications += 1 }
    let searchStart = ProcessInfo.processInfo.systemUptime
    state.searchFullText(query: "absent", scope: .all, project: nil, archived: false)
    try await waitFor { !state.isSearchingFullText }
    guard state.fullTextResult?.scannedSessions == catalog.count else { throw Failure(message: "full search did not cover fixture") }
    guard rebuilds == 0 else { throw Failure(message: "unchanged detail rebuilt all session analytics") }
    guard publications < catalog.count / 10 else { throw Failure(message: "search flooded the main actor with progress updates") }
    print(String(format: "SESSION_PERFORMANCE sessions=2000 detail-median-ms=%.3f detail-p95-ms=%.3f analytics-rebuilds=%d selected-50000-ms=%.3f full-search-ms=%.3f progress-publications=%d",
        detailTimes.sorted()[detailTimes.count / 2], detailTimes.sorted()[detailTimes.count * 95 / 100], rebuilds,
        lookup, (ProcessInfo.processInfo.systemUptime - searchStart) * 1_000, publications))
    withExtendedLifetime((observation, progressObservation)) {}
}
Task { @MainActor in
    do { try await run(); exit(0) } catch { print("FAILED \(error)"); exit(1) }
}
RunLoop.main.run()
'''

SWIFT_RENDER = r'''
#if SESSION_RENDER
func footprint() -> UInt64 {
    var info = gpt_process_info()
    return gpt_read_process(getpid(), &info) == 0 ? info.footprint_bytes : 0
}
func report(_ name: String, _ samples: [Double]) {
    let sorted = samples.sorted()
    print(String(format: "SESSION_RENDER %@ median-ms=%.3f p95-ms=%.3f max-ms=%.3f",
        name, sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 95 / 100)], sorted.last!))
}
@MainActor func nativeText(in view: NSView) -> NSTextView? {
    if let text = view as? NSTextView, text.accessibilityLabel() == "会话消息全文" { return text }
    for child in view.subviews { if let text = nativeText(in: child) { return text } }
    return nil
}
@MainActor func expandButton(in value: Any) -> (any NSAccessibilityProtocol)? {
    guard let element = value as? any NSAccessibilityProtocol else { return nil }
    if element.accessibilityIdentifier() == "session-expand-full-text" { return element }
    for child in element.accessibilityChildren() ?? [] {
        if let button = expandButton(in: child) { return button }
    }
    if let view = value as? NSView {
        for child in view.subviews { if let button = expandButton(in: child) { return button } }
    }
    return nil
}
@MainActor func renderLongMessage(_ mode: String) async throws {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    let count = mode == "text-native-large" ? 24_000 : 1_500
    let text = (0..<count).map { "fixture \($0) 工具输出与用户消息 保留完整文本，不截断全文。 token 123456\n" }.joined()
    let initialFootprint = footprint(), start = ProcessInfo.processInfo.systemUptime
    func nativeBody(expanded: Bool, identity: Int) -> AnyView {
        AnyView(ScrollView { SessionMessageBody(text: text, monospaced: true, initiallyExpanded: expanded).equatable()
            .padding(14) }.id(identity))
    }
    let content: AnyView
    if mode == "text-baseline" {
        content = AnyView(ScrollView { Text(text).font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading) })
    } else {
        // Exercise the production expanded message body, including the native
        // text viewport and the surrounding transcript scroll container.
        content = nativeBody(expanded: true, identity: 0)
    }
    let host = NSHostingView(rootView: content.background(MemoryStyle.background).preferredColorScheme(.light))
    host.frame = .init(x: 0, y: 0, width: 760, height: 460)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(message: "long message bitmap") }
    func draw() {
        // A transparent cached bitmap otherwise accumulates glyphs from earlier
        // scroll offsets; clear it before timing a complete viewport paint.
        NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext.clear(.init(x: 0, y: 0,
            width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        host.cacheDisplay(in: host.bounds, to: bitmap)
    }
    draw()
    report(mode + ".cold-layout-draw", [(ProcessInfo.processInfo.systemUptime - start) * 1_000])
    try await Task.sleep(nanoseconds: 80_000_000)
    var resizing: [Double] = []
    for _ in 0..<7 {
        let begin = ProcessInfo.processInfo.systemUptime
        host.frame.size.width += 2
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        draw()
        resizing.append((ProcessInfo.processInfo.systemUptime - begin) * 1_000)
    }
    report(mode + ".resize-draw", resizing)
    if mode != "text-baseline" {
        // Replace the mounted message once to enter its normal collapsed state,
        // then exercise the real SwiftUI expand action after framework warm-up.
        host.rootView = nativeBody(expanded: false, identity: 1).background(MemoryStyle.background).preferredColorScheme(.light)
        host.layoutSubtreeIfNeeded()
        try await waitFor { nativeText(in: host) == nil }
        try await Task.sleep(nanoseconds: 20_000_000)
        let button = expandButton(in: host)
        let expand = ProcessInfo.processInfo.systemUptime
        if let button {
            guard button.accessibilityPerformPress() else { throw Failure(message: "production expand action failed") }
        } else {
            // Some headless WindowServer sessions do not vend SwiftUI AX nodes.
            // Still measure the same production expanded-state view creation.
            host.rootView = nativeBody(expanded: true, identity: 2).background(MemoryStyle.background).preferredColorScheme(.light)
        }
        host.layoutSubtreeIfNeeded()
        try await waitFor { nativeText(in: host) != nil }
        host.layoutSubtreeIfNeeded(); draw()
        report(mode + (button == nil ? ".warm-state-expand-draw" : ".warm-button-expand-draw"),
            [(ProcessInfo.processInfo.systemUptime - expand) * 1_000])
        if button == nil { print("NOTE offscreen SwiftUI accessibility action unavailable; measured production expanded-state mount") }
        guard let view = nativeText(in: host), view.string == text, view.textLayoutManager != nil,
              let scroll = view.enclosingScrollView, scroll.contentView.bounds.height <= 320 else {
            throw Failure(message: "expanded full message is not a complete bounded TextKit 2 viewport")
        }
        let tail = (text as NSString).length - 12
        let begin = ProcessInfo.processInfo.systemUptime
        view.scrollRangeToVisible(.init(location: tail, length: 12))
        view.setSelectedRange(.init(location: tail, length: 12))
        host.layoutSubtreeIfNeeded()
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        draw()
        report(mode + ".jump-select-tail-draw", [(ProcessInfo.processInfo.systemUptime - begin) * 1_000])
        guard view.selectedRange().location == tail, view.string == text else {
            throw Failure(message: "native long message lost tail or selection")
        }
        let pasteboard = NSPasteboard.withUniqueName()
        if view.writeSelection(to: pasteboard, types: [.string]) {
            guard pasteboard.string(forType: .string) == (text as NSString).substring(from: tail) else {
                throw Failure(message: "native selected copy changed text")
            }
            print("PASS native selected copy to isolated pasteboard")
        } else {
            print("NOTE isolated pasteboard service unavailable; native text and selected range verified")
        }
        var scrolling: [Double] = []
        for offset in 0..<30 {
            let begin = ProcessInfo.processInfo.systemUptime
            scroll.contentView.scroll(to: .init(x: 0, y: CGFloat(offset * 37)))
            scroll.reflectScrolledClipView(scroll.contentView)
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            draw()
            scrolling.append((ProcessInfo.processInfo.systemUptime - begin) * 1_000)
        }
        report(mode + ".scroll-draw", scrolling)
        // Parent re-renders must preserve the selection and complete original text.
        host.needsLayout = true; host.layoutSubtreeIfNeeded()
        guard view.selectedRange().location == tail, view.string == text else {
            throw Failure(message: "parent layout reset long-message selection")
        }
        print("PASS complete native long message, bounded viewport, tail selection and scrolling")
        if mode == "text-native-large", let path = ProcessInfo.processInfo.environment["GPT_SESSION_LONG_RENDER_PATH"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
    print(String(format: "SESSION_RENDER %@ bytes=%d footprint-delta-MiB=%.2f", mode,
        text.utf8.count, (Double(footprint()) - Double(initialFootprint)) / 1_048_576))
    window.close()
}
#endif
'''

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-render", action="store_true", help="Only benchmark session state")
    parser.add_argument("--skip-baseline", action="store_true", help="Skip the slow legacy full-text layout comparison")
    parser.add_argument("--render-preview", help="Save the production expanded long-message viewport as a PNG")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("session_checks", project / "scripts/check-desktop-sessions.py")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    render = not args.skip_render
    release, objects = helper.release_inputs(project, render)
    with tempfile.TemporaryDirectory(prefix="gpt-session-performance-") as temporary:
        directory = Path(temporary)
        source = directory / "main.swift"
        source.write_text(SWIFT + SWIFT_RENDER, encoding="utf-8")
        binary = directory / "checks"
        sources = helper.desktop_sources(project, render)
        command = ["swiftc", "-O", "-swift-version", "5", "-target", f"{platform.machine()}-apple-macosx14.0",
                   "-module-cache-path", str(directory / "cache"), "-I", str(release / "Modules"), "-o", str(binary)]
        command += [str(path) for path in sources] + [str(source)] + [str(path) for path in objects]
        if render:
            command += ["-DSESSION_RENDER", "-I", str(release / "CNative.build"), "-lproc", "-lsqlite3"]
        subprocess.run(command, cwd=project, check=True, timeout=180)
        modes = ["state"] + ((["text-baseline"] if not args.skip_baseline else []) + ["text-native", "text-native-large"] if render else [])
        environment = os.environ.copy()
        if args.render_preview:
            preview = Path(args.render_preview).expanduser().resolve()
            preview.parent.mkdir(parents=True, exist_ok=True)
            environment["GPT_SESSION_LONG_RENDER_PATH"] = str(preview)
        for mode in modes:
            subprocess.run([str(binary), mode], cwd=project, env=environment, check=True, timeout=90)

if __name__ == "__main__":
    main()
