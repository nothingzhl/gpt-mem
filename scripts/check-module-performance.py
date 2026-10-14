#!/usr/bin/env python3
"""Release-production performance probes using isolated synthetic fixtures only."""
import importlib.util, platform, subprocess, tempfile
from pathlib import Path
SWIFT = r'''
import Foundation
import Darwin
import GPTSessionKit
import GPTAnalysisKit
import GPTMemoryCore
func measure(_ name: String, repeats: Int = 5, _ body: () throws -> Void) throws {
    var times: [Double] = []
    for _ in 0..<repeats {
        let begin = ProcessInfo.processInfo.systemUptime
        try autoreleasepool { try body() }
        times.append((ProcessInfo.processInfo.systemUptime - begin) * 1000)
    }
    print("PERF \(name) median_ms=\(String(format: "%.3f", times.sorted()[times.count/2]))"); fflush(stdout)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let origin = Date(timeIntervalSince1970: 1791900000)
let sessions = (0..<2000).map { i in
    CodexSessionSummary(id: "s\(i)", sessionID: "s\(i)", fileURL: root.appendingPathComponent("s\(i).jsonl"), title: "会话 \(i)", projectPath: "/fixture/project\(i % 100)", startedAt: origin.addingTimeInterval(Double(i * 300)), updatedAt: origin, model: "model\(i % 8)", messageCount: 100, tokens: .init(input: 10000, output: 1000), searchText: "讨论性能分析方案")
}
try measure("sessions.analytics.2000") { precondition(SessionAnalytics(sessions: sessions).totalSessionCount == 2000) }
try measure("sessions.metadata-search.2000") { precondition(sessions.filter { $0.matches(query: "性能 分析") }.count == 2000) }
let snapshots = (0..<720).map { i in
    MemorySnapshot(id: "m\(i)", capturedAt: origin.addingTimeInterval(Double(i * 5)), processes: (0..<100).map { pid in
        ProcessSample(bootID: "fixture", pid: pid + 100, parentPID: 1, startTimeTicks: 1, startedAt: origin, executable: "fixture", role: .renderer, footprintBytes: UInt64(1000000 + i * 100))
    })
}
let store = try MemoryStore(url: root.appendingPathComponent("history.sqlite3"), decodedCacheByteLimit: 32 * 1024 * 1024)
for snapshot in snapshots { try store.save(snapshot) }
try measure("history.cold-load.720x100", repeats: 1) { let loaded = try store.load(since: origin); precondition(loaded.count == 720) }
try measure("history.warm-load.720x100") { let loaded = try store.load(since: origin); precondition(loaded.count == 720) }
print("CACHE decoded=\(store.lastReadMetrics.decodedSnapshots) reused=\(store.lastReadMetrics.reusedSnapshots) bytes=\(store.lastReadMetrics.cachedPayloadBytes)")
try measure("overview.analysis.720x100") { precondition(MemoryAnalyzer.analyze(snapshots).sampleCount == 720) }
let knowledge = KnowledgeStore(directoryURL: root.appendingPathComponent("knowledge"))
for i in 0..<100 { _ = try knowledge.save(.init(title: "记忆\(i)", body: String(repeating: "测试内容", count: 100), state: .active), expected: nil) }
try measure("knowledge.load.100") { let loaded = try knowledge.load(); precondition(loaded.entries.count == 100) }
let catalog = try knowledge.load()
try measure("knowledge.reuse.100") { precondition(!catalog.bundle(ids: Set(catalog.entries.map(\.id)), project: "", session: "").isEmpty) }
let memories = root.appendingPathComponent("memories")
try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
for i in 0..<100 { try String(repeating: "- 原始记忆测试\n", count: 100).write(to: memories.appendingPathComponent("fixture\(i).md"), atomically: true, encoding: .utf8) }
try measure("codex-memory.read.100") { let loaded = try CodexMemoryReader(rootURL: memories).read(); precondition(!loaded.documents.isEmpty) }


let sessionRoot = root.appendingPathComponent("session-fixture")
let logs = sessionRoot.appendingPathComponent("sessions/2026/10/14")
try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
func logRecord(_ type: String, _ payload: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-14T00:00:00.000Z", "type": type, "payload": payload]); data.append(10); return data
}
for i in 0..<100 {
    var bytes = try logRecord("session_meta", ["id": "fixture-\(i)", "cwd": "/fixture/project", "originator": "Codex Desktop"])
    bytes += try logRecord("turn_context", ["model": "fixture-model"])
    for j in 0..<100 { bytes += try logRecord("event_msg", ["type": j % 2 == 0 ? "user_message" : "agent_message", "message": "消息\(j) " + String(repeating: "x", count: 640)]) }
    try bytes.write(to: logs.appendingPathComponent("fixture-\(i).jsonl"))
}
try measure("sessions.catalog.cold.100x100", repeats: 3) { let catalog = try CodexSessionRepository(rootURL: sessionRoot).loadCatalog(); precondition(catalog.sessions.count == 100) }
let repository = CodexSessionRepository(rootURL: sessionRoot)
let sessionCatalog = try repository.loadCatalog()
try measure("sessions.catalog.warm.100x100") { let catalog = try repository.loadCatalog(); precondition(catalog.sessions.count == 100) }
let firstSession = sessionCatalog.sessions[0]
try measure("sessions.transcript.cold.100-messages", repeats: 3) { let transcript = try CodexSessionRepository(rootURL: sessionRoot).loadTranscript(for: firstSession); precondition(transcript.messages.count == 100) }
_ = try repository.loadTranscript(for: firstSession)
try measure("sessions.transcript.warm.100-messages") { let transcript = try repository.loadTranscript(for: firstSession); precondition(transcript.messages.count == 100) }
try measure("sessions.fulltext.no-hit.100x100", repeats: 3) {
    let reader = CodexSessionRepository(rootURL: sessionRoot)
    let result = try SessionFullTextSearch.search(sessions: sessionCatalog.sessions, query: "missing-fixture", scope: .all, loader: reader.loadTranscript)
    precondition(result.scannedSessions == 100 && result.hits.isEmpty)
}
var appRoot = ProcessSample(bootID: "fixture", pid: 500, parentPID: 1, startTimeTicks: 1, startedAt: origin, executable: "/fixture/Codex.app/Contents/MacOS/Codex", role: .appMain, footprintBytes: 100000000)
appRoot.rootKey = appRoot.key
let workers = (0..<200).map { i in ProcessSample(bootID: "fixture", pid: 501 + i, parentPID: 500, startTimeTicks: 2, startedAt: origin, executable: "fixture-node", role: .mcpApp, rootKey: appRoot.key, footprintBytes: 64000000, cpuPercent: 0) }
let planSnapshot = MemorySnapshot(id: "plan", capturedAt: origin, processes: [appRoot] + workers)
try measure("process-plan.baseline.200-workers") { precondition(BaselineMemoryOptimizationPlanner.candidates(snapshot: planSnapshot, protectedPIDs: []).count == 200) }
try measure("process-plan.200-workers") { precondition(MemoryOptimizationPlanner.candidates(snapshot: planSnapshot, protectedPIDs: []).count == 200) }
let settingsStore = AIConfigurationStore(url: root.appendingPathComponent("settings.json"))
let providers = (0..<30).map { i in AIProviderConfiguration(name: "fixture-\(i)", kind: .openAICompatible, baseURL: "https://fixture.invalid/v1", model: "fixture-model") }
try settingsStore.save(.init(providers: providers))
try measure("settings.load-validate.30") { let settings = try settingsStore.load(); try settings.validate(); precondition(settings.providers.count == 30) }
let templates = AIPromptTemplateStore(directoryURL: root.appendingPathComponent("templates"))
for i in 0..<40 { _ = try templates.save(.init(title: "模板\(i)", text: "只引用提供的证据"), expected: nil) }
try measure("templates.load-filter.40") { let catalog = try templates.load(); precondition(catalog.choices(for: "memory").count >= 40) }
let reports = AIReportStore(directoryURL: root.appendingPathComponent("reports"))
let input = AIAnalysisInput(moduleID: "memory", moduleTitle: "测试分析", promptVersion: "1", guidance: "只引用证据", windowStart: origin, windowEnd: origin.addingTimeInterval(60), facts: [.init(id: "f1", title: "fixture", data: .number(100))], subjects: [])
let result = AIAnalysisResult(summary: String(repeating: "fixture ", count: 100), observations: [.init(text: "fixture", evidenceIDs: ["f1"])], hypotheses: [], nextSteps: [.init(subjectID: nil, action: "检查fixture", purpose: "验证fixture")], limitations: ["fixture"])
let providerID = UUID()
var saved: AISavedReport?
for i in 0..<100 {
    let record = AIAnalysisRecord(moduleID: "memory", moduleTitle: "测试分析", providerID: providerID, providerName: "fixture", model: "fixture", inputFingerprint: String(format: "%064x", i), windowStart: origin, windowEnd: origin.addingTimeInterval(60), generatedAt: origin.addingTimeInterval(Double(i)), result: result)
    saved = try reports.save(.init(record: record, input: input, windowSelectionSeconds: 60))
}
try measure("reports.load.100") { let catalog = try reports.loadCatalog(); precondition(catalog.reports.count == 100) }
try measure("reports.export.markdown-json") { let markdown = try AIReportExport.markdown(saved!); let json = try AIReportExport.json(saved!); precondition(!markdown.isEmpty && !json.isEmpty) }

let resultBytes = try AIAnalysisCodec.encoder().encode(result)
try measure("ai.result.decode-validate") { let parsed = try AIAnalysisCodec.decoder().decode(AIAnalysisResult.self, from: resultBytes); try parsed.validate(against: input) }
let original = "# 规则\n" + (0..<1000).map { "- 规则\($0) 中文测试内容\n\n" }.joined()
try measure("codex-memory.preview.1000-items") {
    let items = CodexMemoryItem.parse(original)
    precondition(items.count == 1000)
    let preview = try items[500].replacing(in: original, with: "- 修改规则\n\n")
    precondition(preview.contains("修改规则") && !preview.contains("规则500 "))
}
if CommandLine.arguments.contains("--native") {
    let collector = NativeCollector()
    try measure("native.readonly-collection", repeats: 3) { let sample = try collector.sample(); precondition(sample.capturedAt.timeIntervalSince1970 > 0) }
}
print("PASS isolated module performance probes; zero network requests")

'''
def main():
    project = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('helper', project/'scripts/check-desktop-ai.py')
    helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
    release, objects = helper.release_inputs(project)
    with tempfile.TemporaryDirectory(prefix='module-performance-') as tmp:
        temp = Path(tmp); source = temp/'main.swift'
        baseline = subprocess.run(['git', 'show', 'f3b3675:Sources/GPTMemoryCore/ProcessControl.swift'], cwd=project, check=True, text=True, capture_output=True).stdout
        baseline = baseline[baseline.index('public struct MemoryOptimizationCandidate'):baseline.index('public enum ProcessCommandReader')]
        baseline = baseline.replace('MemoryOptimizationCandidate', 'BaselineMemoryOptimizationCandidate').replace('MemoryOptimizationPlanner', 'BaselineMemoryOptimizationPlanner')
        source.write_text(SWIFT + '\n' + baseline)
        binary = temp/'checks'
        command = ['swiftc', '-O', '-swift-version', '5', '-target', f'{platform.machine()}-apple-macosx14.0', '-module-cache-path', str(temp/'cache'), '-I', str(release/'Modules'), '-I', str(release/'CNative.build'), str(source), '-o', str(binary)]
        subprocess.run(command + list(map(str, objects)) + ['-lproc', '-lsqlite3'], check=True, timeout=90)
        subprocess.run([str(binary), str(temp)] + (["--native"] if "--native" in __import__("sys").argv else []), check=True, timeout=120)
if __name__ == '__main__': main()
