#!/usr/bin/env python3
"""Measure production page layout in isolated processes with synthetic local data."""
from pathlib import Path
import importlib.util, os, platform, subprocess, tempfile
SWIFT = r'''
import AppKit
import CNative
import GPTAnalysisKit
import GPTSessionKit
@MainActor func runPage() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let root = URL(fileURLWithPath: CommandLine.arguments[1]), page = CommandLine.arguments[2]
    let configuration = AIConfigurationStore(url: root.appendingPathComponent("ai.json"))
    try configuration.save(.init(providers: (0..<30).map { i in .init(name: "来源\(i)", kind: .openAICompatible, baseURL: "https://fixture.invalid/v1", model: "fixture") }))
    let ai = DesktopAIModel(configurationStore: AIConfigurationStore(url: root.appendingPathComponent("ai.json")))
    let origin = Date(timeIntervalSince1970: 1791900000)
    let history = (0..<720).map { i in MemorySnapshot(id: "m\(i)", capturedAt: origin.addingTimeInterval(Double(i*5)), processes: (0..<100).map { p in ProcessSample(bootID: "fixture", pid: p+100, parentPID: 1, startTimeTicks: 1, startedAt: origin, executable: "fixture", role: .renderer, footprintBytes: UInt64(1000000+i*100)) }) }
    let snapshot = history.last!, analysis = MemoryAnalyzer.analyze(history)
    let sourceRoot = root.appendingPathComponent("sources")
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    let actions = MemoryProcessActionsModel(directoryURL: root.appendingPathComponent("actions"))
    let sessions = (0..<2000).map { i in CodexSessionSummary(id: "s\(i)", sessionID: "s\(i)", fileURL: sourceRoot.appendingPathComponent("s\(i).jsonl"), title: "临时会话\(i)", projectPath: "/fixture/project\(i%100)", startedAt: origin, model: "fixture", messageCount: 100) }
    let sessionModel = SessionDesktopModel(rootURL: sourceRoot, catalogLoader: { .init(sessions: sessions) }, transcriptLoader: { .init(summary: $0) }, managementDirectoryURL: root.appendingPathComponent("management"))
    sessionModel.loadIfNeeded()
    for _ in 0..<500 { if !sessionModel.isLoading && sessionModel.filteredSessions.count == 2000 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(sessionModel.filteredSessions.count == 2000)
    let store = KnowledgeStore(directoryURL: root.appendingPathComponent("knowledge"))
    for i in 0..<200 { _ = try store.save(.init(title: "记忆\(i)", body: String(repeating: "合成正文", count: 100), state: .active), expected: nil) }
    let knowledge = KnowledgeDesktopModel(directoryURL: store.directoryURL, sourceRoot: root.appendingPathComponent("memories"))
    await knowledge.reload()
    for _ in 0..<500 { if !knowledge.isLoading && !knowledge.isFiltering { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(knowledge.filteredEntries.count == 200)
    if page == "reports" {
        let input = AIAnalysisInput(moduleID: "memory", moduleTitle: "临时测试", promptVersion: "1", guidance: "只引用证据", windowStart: origin, windowEnd: origin.addingTimeInterval(60), facts: [.init(id: "f1", title: "fixture", data: .number(1))], subjects: [])
        let result = AIAnalysisResult(summary: "临时分析结论", observations: [.init(text: "临时观察", evidenceIDs: ["f1"])], hypotheses: [], nextSteps: [.init(subjectID: nil, action: "检查", purpose: "验证")], limitations: ["临时数据"])
        for i in 0..<100 {
            let record = AIAnalysisRecord(moduleID: input.moduleID, moduleTitle: input.moduleTitle, providerID: UUID(), providerName: "fixture", model: "fixture", inputFingerprint: String(format: "%064x", i), windowStart: input.windowStart, windowEnd: input.windowEnd, generatedAt: origin.addingTimeInterval(Double(i)), result: result)
            _ = try ai.reportLibrary.store.save(.init(record: record, input: input, windowSelectionSeconds: 60))
        }
        ai.reportLibrary.refresh()
        for _ in 0..<500 { if !ai.reportLibrary.isLoading && !ai.reportLibrary.isFiltering { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(ai.reportLibrary.reports.count == 100)
        ai.reportLibrary.select(ai.reportLibrary.filteredReports.first?.id)
    }
    let speed = DesktopSpeedModel(root: root)
    if page == "speed" {
        let now = Date(), iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let folder = DateFormatter(); folder.dateFormat = "yyyy/MM/dd"; folder.timeZone = TimeZone(secondsFromGMT: 0)
        let directory = root.appendingPathComponent("sessions/" + folder.string(from: now))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func line(_ seconds: Double, _ type: String, _ payload: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["timestamp": iso.string(from: now.addingTimeInterval(-11000 + seconds)), "type": type, "payload": payload]); data.append(10); return data
        }
        var data = try line(0, "session_meta", ["originator": "Codex Desktop", "id": "fixture"])
        data += try line(0, "turn_context", ["model": "fixture-model"])
        data += try line(0, "event_msg", ["type": "task_started"])
        for i in 1...1000 { data += try line(Double(i * 10), "event_msg", ["type": "token_count", "info": ["total_token_usage": ["output_tokens": i * 100], "last_token_usage": ["output_tokens": 100]]]) }
        try data.write(to: directory.appendingPathComponent("fixture.jsonl"))
        await speed.refresh()
        precondition(speed.snapshot.samples.count == 500)
    }
    let content: AnyView
    switch page {
    case "overview": content = AnyView(ScrollView { OverviewContent(snapshot: snapshot, history: history, analysis: analysis, minutes: .constant(30), aiModel: ai, onAIAnalysis: {}, onOpenReports: {}, onRoleSelect: { _ in }) })
    case "processes": content = AnyView(ProcessesContent(snapshot: snapshot, selectedRole: .constant(nil), isBusy: false, focusedKey: .constant(nil), actions: actions, history: history, onDiagnose: { _ in }))
    case "history": content = AnyView(ScrollView { HistoryContent(analysis: analysis, snapshot: snapshot, minutes: .constant(30), isBusy: false, lastExportURL: nil, aiModel: ai, onAIAnalysis: {}, onOpenReports: {}, onExport: {}) })
    case "settings": content = AnyView(ScrollView { SettingsContent(interval: .constant(5), snapshot: snapshot, databaseURL: root.appendingPathComponent("history.sqlite3"), isMonitoring: false, modeLabel: "临时测试", aiModel: ai, onOpenDirectory: {}) })
    case "sessions": content = AnyView(SessionWorkspaceHost(model: sessionModel, aiModel: ai))
    case "knowledge": content = AnyView(KnowledgeWorkspaceHost(model: knowledge, ai: ai, sessions: sessionModel, onOpenSessions: {}))
    case "reports": content = AnyView(AIReportsContent(model: ai.reportLibrary))
    case "speed": content = AnyView(DesktopSpeedView(model: speed))
    default: fatalError("unknown page")
    }
    func footprint() -> UInt64 { var info = gpt_process_info(); return gpt_read_process(getpid(), &info) == 0 ? info.footprint_bytes : 0 }
    let before = footprint()
    let begin = ProcessInfo.processInfo.systemUptime
    let host = NSHostingView(rootView: content.padding(20).background(MemoryStyle.background).foregroundStyle(MemoryStyle.text).preferredColorScheme(.light))
    host.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let cold = (ProcessInfo.processInfo.systemUptime - begin)*1000
    try await Task.sleep(nanoseconds: 150_000_000)
    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    precondition(!knowledge.isFiltering)
    var warm: [Double] = []
    for _ in 0..<5 {
        let begin = ProcessInfo.processInfo.systemUptime
        host.frame.size.width += 1
        host.needsLayout = true; host.layoutSubtreeIfNeeded()
        warm.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
    }
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("bitmap") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let after = footprint()
    print("PAGE \(page) cold-layout-ms=\(String(format: "%.2f", cold)) resize-layout-ms=\(String(format: "%.2f", warm.sorted()[2])) footprint-before-MiB=\(Double(before)/1048576) footprint-after-render-MiB=\(Double(after)/1048576)")
    if let folder = ProcessInfo.processInfo.environment["PAGE_RENDER"] { try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(page + ".png")) }
    speed.stop(); window.close()
}
Task { @MainActor in do { try await runPage(); exit(0) } catch { print("FAIL \(error)"); exit(1) } }
RunLoop.main.run()
'''
def main():
    project=Path(__file__).resolve().parents[1]
    spec=importlib.util.spec_from_file_location('helper',project/'scripts/check-desktop-ai.py'); helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    release,objects=helper.release_inputs(project)
    with tempfile.TemporaryDirectory(prefix='page-performance-') as tmp:
        temp=Path(tmp); source=temp/'main.swift'; source.write_text((project/'Sources/GPTMemoryDesktop/Views.swift').read_text()+'\n'+SWIFT); binary=temp/'checks'
        sources=[p for p in (project/'Sources/GPTMemoryDesktop').glob('*.swift') if p.name not in ['App.swift','Views.swift']]
        command=['swiftc','-O','-swift-version','5','-target',f'{platform.machine()}-apple-macosx14.0','-module-cache-path',str(temp/'cache'),'-I',str(release/'Modules'),'-I',str(release/'CNative.build'),'-o',str(binary)]
        subprocess.run(command+list(map(str,sources))+[str(source)]+list(map(str,objects))+['-lproc','-lsqlite3'],check=True,timeout=180)
        output=project/'reports/performance/pages';output.mkdir(parents=True,exist_ok=True)
        for page in ['overview','processes','history','settings','sessions','knowledge','reports','speed']:
            fixture=temp/page;fixture.mkdir()
            env=os.environ.copy();env['PAGE_RENDER']=str(output)
            subprocess.run([str(binary),str(fixture),page],env=env,check=True,timeout=60)
if __name__=='__main__':main()
