#!/usr/bin/env python3
"""Exercise the production desktop report library using temporary files and mock AI.

No user configuration, Keychain, Codex sessions, or real network requests are read.
Uses the release AnalysisKit objects, following the existing desktop CLT harness.
"""
from pathlib import Path
import argparse
import importlib.util
import os
import platform
import subprocess
import sys
import tempfile


SWIFT_CHECKS = r'''
import Foundation
import Darwin
import GPTAnalysisKit
#if RENDER_REPORT_LIBRARY
import AppKit
import SwiftUI
#endif

struct CheckFailure: Error, CustomStringConvertible { let description: String }
@MainActor var assertionCount = 0
@MainActor func expect(_ value: @autoclosure () -> Bool, _ text: String) throws {
    assertionCount += 1
    if !value() { throw CheckFailure(description: text) }
}
@MainActor func wait(_ text: String, until done: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !done() {
        if Date() >= deadline { throw CheckFailure(description: "timeout: " + text) }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
@MainActor func waitIdle(_ model: AIReportLibraryModel) async throws {
    try await wait("library idle") {
        !model.isLoading && !model.isSaving && !model.isRemoving && !model.isExporting && !model.isFiltering
    }
}
func fixture(_ number: Int, module: String = "memory", context: String = "启动后增长") -> AISavedReport {
    let start = Date(timeIntervalSince1970: 1_791_792_000 + Double(number * 600))
    let input = AIAnalysisInput(moduleID: module, moduleTitle: module == "memory" ? "内存分析" : "会话分析",
        promptVersion: "fixture-1", guidance: "只依据本地证据给出假设。", windowStart: start,
        windowEnd: start.addingTimeInterval(300), facts: [AIAnalysisFact(id: "fact.1", title: "窗口变化",
            data: .object(["growth": .number(120)]))],
        subjects: [AIAnalysisSubject(id: "s1", label: "匿名对象 s1", canInspect: true)], context: context)
    let result = AIAnalysisResult(summary: "报告 \(number)：启动后增长，仍需确认回收。",
        observations: [AIObservation(text: "窗口增长 120 MiB。", evidenceIDs: ["fact.1"])],
        hypotheses: [AIHypothesis(title: "页面缓存", explanation: "需要活动结束后的样本验证。",
            evidenceIDs: ["fact.1"], missingEvidence: ["活动结束后的采样"])],
        nextSteps: [AINextStep(subjectID: "s1", action: "核对对象后采集摘要。", purpose: "检查增长。")],
        limitations: ["记录不等于已确定内存泄漏。"])
    let record = AIAnalysisRecord(moduleID: input.moduleID, moduleTitle: input.moduleTitle,
        providerID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, providerName: "模拟来源",
        model: "fixture-model", inputFingerprint: String(repeating: "a", count: 64),
        windowStart: input.windowStart, windowEnd: input.windowEnd,
        generatedAt: start.addingTimeInterval(301.123), result: result)
    return AISavedReport(record: record, input: input, subjectLabels: ["s1": "私密本地进程 \(number)"],
                         windowSelectionSeconds: 600)
}
func temporaryStore(_ name: String) throws -> AIReportStore {
    guard let base = ProcessInfo.processInfo.environment["GPT_REPORT_LIBRARY_CHECK_DIR"] else {
        throw CheckFailure(description: "missing temporary directory")
    }
    return AIReportStore(directoryURL: URL(fileURLWithPath: base).appendingPathComponent(name))
}
@MainActor func enqueue(_ report: AISavedReport, into model: AIReportLibraryModel) {
    model.save(record: report.record, input: report.input, subjectLabels: report.subjectLabels,
               windowSelectionSeconds: report.windowSelectionSeconds)
}

@MainActor func checkPersistenceAndFiltering() async throws {
    let store = try temporaryStore("persistence")
    let model = AIReportLibraryModel(store: store)
    model.loadIfNeeded()
    try await waitIdle(model)
    try expect(model.hasLoaded && model.reports.isEmpty, "empty library loads")
    try expect(!FileManager.default.fileExists(atPath: store.directoryURL.path), "empty reads do not create storage")
    let first = fixture(1), second = fixture(2, module: "session", context: "搜索性能")
    enqueue(first, into: model); enqueue(second, into: model)
    try await waitIdle(model)
    try expect(model.reports.count == 2 && model.reports.first?.id == second.id, "saves queue and newest sorts first")
    try expect(model.pendingSaveCount == 0 && !model.canRetrySave, "successful saves leave no pending recovery")
    let reopened = AIReportLibraryModel(store: AIReportStore(directoryURL: store.directoryURL))
    reopened.loadIfNeeded()
    try await waitIdle(reopened)
    try expect(reopened.reports == model.reports, "closing and reopening retains complete frozen reports")
    try expect(reopened.moduleIDs.sorted() == ["memory", "session"], "module choices come from saved reports")
    reopened.query = "fixture-MODEL 搜索性能"
    try await waitIdle(reopened)
    try expect(reopened.filteredReports.map(\.id) == [second.id], "case-insensitive AND search includes context and model")
    reopened.query = "页面缓存"; reopened.selectedModuleID = "memory"
    try await waitIdle(reopened)
    try expect(reopened.filteredReports.map(\.id) == [first.id], "hypothesis search combines with module filter")
    reopened.select(first.id)
    reopened.query = "没有匹配"
    try await waitIdle(reopened)
    try expect(reopened.filteredReports.isEmpty && reopened.selectedReport == nil, "hidden selection is cleared")
    reopened.query = "old-query"; reopened.query = "搜索性能"; reopened.selectedModuleID = nil
    try await waitIdle(reopened)
    try expect(reopened.filteredReports.map(\.id) == [second.id], "cancelled search never overrides final query")
    print("PASS persistent reports, frozen evidence, module scopes and search generations")
}

@MainActor func checkFailureAndRetry() async throws {
    let store = try temporaryStore("failure")
    let model = AIReportLibraryModel(store: store)
    let first = fixture(3), pending = fixture(4)
    enqueue(first, into: model)
    try await waitIdle(model)
    let backup = store.directoryURL.appendingPathExtension("backup")
    try FileManager.default.moveItem(at: store.directoryURL, to: backup)
    try Data("blocked directory".utf8).write(to: store.directoryURL)
    model.refresh()
    try await waitIdle(model)
    try expect(model.reports.count == 1 && model.errorMessage != nil, "read failure preserves previous catalog")
    enqueue(pending, into: model)
    try await waitIdle(model)
    try expect(model.reports.count == 1 && model.pendingSaveCount == 1, "save failure preserves catalog and pending report")
    try expect(model.saveErrorMessage?.contains("分析完成，报告保存失败") == true, "save failure is distinct from model failure")
    try expect(model.canRetrySave, "failed persistence has local retry")
    let blocked = try String(contentsOf: store.directoryURL, encoding: .utf8)
    try expect(blocked == "blocked directory", "unsafe destination is not overwritten")
    try FileManager.default.removeItem(at: store.directoryURL)
    try FileManager.default.moveItem(at: backup, to: store.directoryURL)
    model.retrySave()
    try await waitIdle(model)
    try expect(model.reports.count == 2 && model.pendingSaveCount == 0, "retry persists exact pending evidence")
    try expect(model.saveErrorMessage == nil && model.errorMessage == nil, "successful retry clears recovery error")
    let saved = model.reports.first { $0.id == pending.id }
    try expect(saved == pending, "retry does not regenerate result or change mapping")
    print("PASS failed reads/writes retain data and exact local save retry")
}

@MainActor func checkRemovalSelectionAndUndo() async throws {
    let store = try temporaryStore("removal")
    let model = AIReportLibraryModel(store: store)
    let first = fixture(5), second = fixture(6)
    enqueue(first, into: model); enqueue(second, into: model)
    try await waitIdle(model)
    model.select(first.id)
    model.removeSelectedReport()
    model.select(second.id)
    try await waitIdle(model)
    try expect(model.reports.map(\.id) == [second.id], "remove freezes the original selected report")
    try expect(model.selectedReportID == second.id, "remove completion preserves changed selection")
    try expect(model.canUndoRemoval, "soft removal exposes undo")
    let trash = store.directoryURL.appendingPathComponent("trash").appendingPathComponent(first.id.uuidString.lowercased() + ".json")
    try expect(FileManager.default.fileExists(atPath: trash.path), "report remains in private trash")
    enqueue(first, into: model)
    try await waitIdle(model)
    try expect(model.reports.count == 1, "cached success does not resurrect removed report")
    model.undoRemoval()
    try await waitIdle(model)
    try expect(model.reports.count == 2 && !model.canUndoRemoval, "undo restores exact report once")
    try expect(model.selectedReportID == second.id, "restoring another report does not steal existing selection")
    try expect(model.reports.first { $0.id == first.id } == first, "restore retains full frozen evidence")
    model.selectedModuleID = "memory"
    try await waitIdle(model)
    model.select(second.id); model.removeSelectedReport()
    try await waitIdle(model)
    model.select(first.id); model.removeSelectedReport()
    try await waitIdle(model)
    try expect(model.moduleChoices.isEmpty && model.selectedModuleID == nil, "removing the last filtered module resets invalid picker selection")
    try expect(model.filteredReports.isEmpty, "last report removal retains an accurate empty state")
    print("PASS frozen removal target, selection races, cache deletion semantics and undo")
}

@MainActor func checkExportFreezeAndProtection() async throws {
    let store = try temporaryStore("exports")
    let model = AIReportLibraryModel(store: store)
    let first = fixture(7), second = fixture(8)
    enqueue(first, into: model); enqueue(second, into: model)
    try await waitIdle(model)
    model.select(first.id)
    guard let frozen = model.selectedReport else { throw CheckFailure(description: "missing export selection") }
    let json = store.directoryURL.deletingLastPathComponent().appendingPathComponent("report-export.json")
    model.exportReport(frozen, to: json, format: .json)
    model.select(second.id)
    try await waitIdle(model)
    let exportedJSON = try Data(contentsOf: json)
    let expectedJSON = try AIReportExport.json(first)
    try expect(exportedJSON == expectedJSON, "export uses frozen report despite changed selection")
    try expect(model.lastExportURL == json, "export success exposes destination")
    let markdown = json.deletingPathExtension().appendingPathExtension("md")
    model.exportReport(first, to: markdown, format: .markdown)
    try await waitIdle(model)
    let text = try String(contentsOf: markdown, encoding: .utf8)
    try expect(text.contains(first.record.result.summary) && text.contains("fact\\.1"), "UTF-8 markdown contains conclusion and escaped evidence")
    let source = store.directoryURL.appendingPathComponent(first.id.uuidString.lowercased() + ".json")
    let original = try Data(contentsOf: source)
    model.exportReport(second, to: source, format: .json)
    try await waitIdle(model)
    try expect(model.errorMessage?.contains("导出位置属于报告库") == true, "storage overwrite is rejected")
    let preserved = try Data(contentsOf: source)
    try expect(preserved == original, "rejected export preserves original report bytes")
    let alias = store.directoryURL.deletingLastPathComponent().appendingPathComponent("report-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: store.directoryURL)
    model.exportReport(second, to: alias.appendingPathComponent("should-not-exist.json"), format: .json)
    try await waitIdle(model)
    try expect(model.errorMessage != nil && !FileManager.default.fileExists(atPath: store.directoryURL.appendingPathComponent("should-not-exist.json").path), "symlink aliases cannot bypass protected storage")
    for name in ["ai-services.json", "history.sqlite3", "history.sqlite3-wal", "history.sqlite3-shm", "history.sqlite3-journal", "monitor.lock"] {
        let file = store.directoryURL.deletingLastPathComponent().appendingPathComponent(name)
        let bytes = Data(("existing application data: " + name).utf8)
        try bytes.write(to: file)
        model.exportReport(first, to: file, format: .json)
        try await waitIdle(model)
        let preserved = try Data(contentsOf: file)
        try expect(model.errorMessage?.contains("应用配置或历史数据") == true && preserved == bytes,
                   "export preserves protected application file: " + name)
    }
    model.exportReport(first, to: json, format: .json)
    try await waitIdle(model)
    try expect(model.errorMessage == nil && model.lastExportURL == json, "ordinary sibling export remains allowed")
    print("PASS frozen UTF-8 export, evidence and protected source/alias destinations")
}

final class NoCredentials: AICredentialStore {
    var reads = 0
    func key(for id: UUID) throws -> String? { reads += 1; return nil }
    func setKey(_ key: String, for id: UUID) throws { throw CheckFailure(description: "unexpected credential write") }
    func deleteKey(for id: UUID) throws { throw CheckFailure(description: "unexpected credential delete") }
}
actor FixtureClient: AIProviderClient {
    var count = 0
    let output: AIAnalysisResult
    init(output: AIAnalysisResult) { self.output = output }
    func requestCount() -> Int { count }
    func analyze(input: AIAnalysisInput, configuration: AIProviderConfiguration, apiKey: String?) async throws -> AIAnalysisResult {
        count += 1
        return output
    }
}
struct FixtureModule: AIAnalysisModule {
    let input: AIAnalysisInput
    func makeInput() throws -> AIAnalysisInput { input }
}

@MainActor func checkAnalysisAutoSaveAndIsolation() async throws {
    let store = try temporaryStore("analysis")
    let library = AIReportLibraryModel(store: store)
    let configuration = AIConfigurationStore(url: store.directoryURL.deletingLastPathComponent().appendingPathComponent("analysis-source.json"))
    let provider = AIProviderConfiguration(name: "本地模拟来源", kind: .ollama, baseURL: "http://localhost:11434", model: "fixture-model")
    try configuration.save(AISettings(providers: [provider], selectedProviderID: provider.id))
    let frozen = fixture(9)
    let credentials = NoCredentials()
    let client = FixtureClient(output: frozen.record.result)
    let coordinator = AIAnalysisCoordinator(client: client, credentials: credentials)
    let model = DesktopAIModel(configurationStore: configuration, credentials: credentials,
                               coordinator: coordinator, reportLibrary: library)
    model.prepare(module: FixtureModule(input: frozen.input), subjectLabels: frozen.subjectLabels, windowSelectionSeconds: 600)
    guard let preview = model.preview else { throw CheckFailure(description: "missing analysis preview") }
    model.beginAnalysis(preview)
    try await wait("mock analysis completed") { !model.isAnalyzing }
    try await waitIdle(library)
    try expect(library.reports.count == 1 && model.record != nil && model.analysisError == nil, "validated successful output automatically saves")
    try expect(library.reports.first?.input == frozen.input && library.reports.first?.subjectLabels == frozen.subjectLabels, "auto-save uses frozen input and local mapping")
    let liveRecord = model.record
    library.select(library.reports.first?.id)
    library.refresh(); library.query = "页面缓存"
    try await waitIdle(library)
    try expect(model.record == liveRecord, "history selection and refresh do not replace current live analysis")
    let previousCredentialReads = credentials.reads
    library.refresh(); library.query = ""; library.selectedModuleID = nil
    try await waitIdle(library)
    try expect(credentials.reads == previousCredentialReads, "library does not read credentials")
    let requests = await client.requestCount()
    try expect(requests == 1, "history operations never call AI")
    model.prepare(module: FixtureModule(input: frozen.input), subjectLabels: frozen.subjectLabels, windowSelectionSeconds: 600)
    guard let repeated = model.preview else { throw CheckFailure(description: "missing repeated preview") }
    model.beginAnalysis(repeated)
    try await wait("cached analysis completed") { !model.isAnalyzing }
    try await waitIdle(library)
    let cachedRequests = await client.requestCount()
    try expect(cachedRequests == 1 && model.record?.wasCached == true && library.reports.count == 1, "cache success saves idempotently without a second request")
    print("PASS successful auto-save, frozen input, live-result isolation and cache deduplication")
}

@MainActor func checkAutoSaveFailureKeepsLiveResult() async throws {
    let store = try temporaryStore("analysis-save-failure")
    try FileManager.default.createDirectory(at: store.directoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("blocked report directory".utf8).write(to: store.directoryURL)
    let library = AIReportLibraryModel(store: store)
    let configuration = AIConfigurationStore(url: store.directoryURL.deletingLastPathComponent().appendingPathComponent("failure-source.json"))
    let provider = AIProviderConfiguration(name: "本地模拟来源", kind: .ollama, baseURL: "http://localhost:11434", model: "fixture-model")
    try configuration.save(AISettings(providers: [provider], selectedProviderID: provider.id))
    let frozen = fixture(10)
    let credentials = NoCredentials()
    let client = FixtureClient(output: frozen.record.result)
    let model = DesktopAIModel(configurationStore: configuration, credentials: credentials,
        coordinator: AIAnalysisCoordinator(client: client, credentials: credentials), reportLibrary: library)
    model.prepare(module: FixtureModule(input: frozen.input), subjectLabels: frozen.subjectLabels, windowSelectionSeconds: 600)
    guard let preview = model.preview else { throw CheckFailure(description: "missing failure fixture preview") }
    model.beginAnalysis(preview)
    try await wait("successful analysis with failed persistence") { !model.isAnalyzing }
    try await waitIdle(library)
    try expect(model.record != nil && model.analysisError == nil, "persistence failure never becomes AI failure")
    try expect(model.reportSaveError?.contains("分析完成，报告保存失败") == true && library.canRetrySave,
               "live result exposes a recoverable persistence error")
    let original = model.record
    try FileManager.default.removeItem(at: store.directoryURL)
    library.retrySave()
    try await waitIdle(library)
    let calls = await client.requestCount()
    try expect(calls == 1 && model.record == original, "retry only saves and neither calls AI nor replaces current result")
    try expect(library.reports.count == 1 && model.reportSaveError == nil, "successful local retry resolves live recovery state")
    print("PASS auto-save failure keeps live AI result and retry never sends another request")
}

@MainActor func checkSavedReportOutsideCatalogBudget() async throws {
    let store = try temporaryStore("catalog-budget")
    let original = fixture(20)
    _ = try store.save(original)
    let savedURL = store.directoryURL.appendingPathComponent(original.id.uuidString.lowercased() + ".json")
    let before = try Data(contentsOf: savedURL)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: savedURL.path)
    for number in 0..<1_000 {
        let name = "00000000-0000-4000-8000-" + String(format: "%012d", number) + ".json"
        try Data("{}".utf8).write(to: store.directoryURL.appendingPathComponent(name))
    }
    let library = AIReportLibraryModel(store: store)
    enqueue(original, into: library)
    try await waitIdle(library)
    try expect(library.pendingSaveCount == 0 && library.saveErrorMessage == nil, "bounded catalog does not negate a successful cached save")
    try expect(library.statusMessage?.contains("已保存在本地") == true, "an existing active report outside catalog budget remains saved")
    try expect(library.statusMessage?.contains("此前已移除") != true, "catalog omission is never confused with trash")
    try expect(library.warnings.contains(where: { $0.contains("1,000") }), "catalog limit remains visible")
    let after = try Data(contentsOf: savedURL)
    try expect(after == before, "budget handling preserves original frozen content")
    print("PASS saved reports outside catalog limits retain correct location and status")
}

#if RENDER_REPORT_LIBRARY
@MainActor func renderLibrary(to path: String) async throws {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    let library = AIReportLibraryModel(store: try temporaryStore("render"))
    for item in [fixture(11, context: "打开项目后占用增加"), fixture(12, module: "session", context: "模拟会话分析"), fixture(13)] {
        enqueue(item, into: library)
    }
    try await waitIdle(library)
    library.select(library.filteredReports.first?.id)
    let empty = AIReportLibraryModel(store: try temporaryStore("render-empty"))
    empty.loadIfNeeded(); try await waitIdle(empty)
    let output = URL(fileURLWithPath: path)
    let emptyOutput = output.deletingPathExtension().appendingPathExtension("empty.png")
    for (destination, model) in [(output, library), (emptyOutput, empty)] {
        let content = VStack(alignment: .leading, spacing: 14) {
            Text("AI 报告库 · 模拟数据预览").font(.system(size: 23, weight: .semibold))
            Text("临时本地报告；没有调用真实模型或读取用户配置。").font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            AIReportsContent(model: model)
        }.padding(18).frame(width: 888, height: 620, alignment: .topLeading)
            .background(MemoryStyle.background).foregroundStyle(MemoryStyle.text).tint(MemoryStyle.accent)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 888, height: 620)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 70_000_000)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CheckFailure(description: "could not render report library")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(description: "could not encode report library preview")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destination)
        print("RENDER \(destination.lastPathComponent)")
    }
}
#endif

@MainActor func runChecks() async throws {
    try await checkPersistenceAndFiltering()
    try await checkFailureAndRetry()
    try await checkRemovalSelectionAndUndo()
    try await checkExportFreezeAndProtection()
    try await checkAnalysisAutoSaveAndIsolation()
    try await checkAutoSaveFailureKeepsLiveResult()
    try await checkSavedReportOutsideCatalogBudget()
    print("REPORT LIBRARY CHECKS PASSED: 7 workflows, \(assertionCount) assertions; temporary stores and mock AI only")
    #if RENDER_REPORT_LIBRARY
    if let path = ProcessInfo.processInfo.environment["GPT_REPORT_LIBRARY_RENDER_PATH"] {
        try await renderLibrary(to: path)
    }
    #endif
}
Task { @MainActor in
    do { try await runChecks(); exit(0) }
    catch { fputs("REPORT LIBRARY CHECK FAILED: \(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
'''


def main() -> int:
    parser = argparse.ArgumentParser(description="使用临时报告与mock AI验证报告库，可离屏渲染生产界面。")
    parser.add_argument("--render", nargs="?", const="reports/report-library-preview.png", metavar="PNG")
    args = parser.parse_args()
    output = Path(args.render).expanduser().resolve() if args.render else None
    project = Path(__file__).resolve().parents[1]
    specification = importlib.util.spec_from_file_location("desktop_ai_checks", project / "scripts" / "check-desktop-ai.py")
    if specification is None or specification.loader is None:
        raise RuntimeError("无法读取桌面测试编译配置")
    harness = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(harness)
    release, objects = harness.release_inputs(project)
    architecture = platform.machine()
    if architecture not in {"arm64", "x86_64"}:
        raise RuntimeError(f"不支持的 macOS 架构：{architecture}")
    with tempfile.TemporaryDirectory(prefix="gpt-report-library-checks-") as temporary:
        directory = Path(temporary)
        swift = directory / "main.swift"
        swift.write_text(SWIFT_CHECKS, encoding="utf-8")
        executable = directory / "report-library-checks"
        desktop = project / "Sources" / "GPTMemoryDesktop"
        command = ["swiftc", "-swift-version", "5", "-target", f"{architecture}-apple-macosx14.0",
                   "-module-cache-path", str(directory / "module-cache"), "-I", str(release / "Modules"),
                   "-I", str(release / "CNative.build"), "-o", str(executable)]
        command += [str(desktop / "AIReportLibraryModel.swift"), str(desktop / "DesktopAIModel.swift"), str(desktop / "PromptTemplateLibraryModel.swift"), str(swift)]
        if output:
            command += ["-D", "RENDER_REPORT_LIBRARY"]
            command += [str(desktop / name) for name in ["AIReportViews.swift", "AIViews.swift", "AIProviderEditorModel.swift", "Style.swift", "PromptTemplateViews.swift", "SessionViews.swift", "SessionProjectViews.swift", "SessionManagementViews.swift", "SessionDesktopModel.swift", "SessionManagementModel.swift", "SessionHandoffAIViews.swift"]]
        command += [str(obj) for obj in objects] + ["-lproc", "-lsqlite3"]
        print("编译报告库本地检查（使用现有 Release 产物）", flush=True)
        subprocess.run(command, cwd=project, check=True, timeout=60)
        environment = os.environ.copy()
        environment["GPT_REPORT_LIBRARY_CHECK_DIR"] = str(directory / "fixtures")
        if output:
            environment["GPT_REPORT_LIBRARY_RENDER_PATH"] = str(output)
        subprocess.run([str(executable)], cwd=project, env=environment, check=True, timeout=30)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"报告库检查未通过：{error}", file=sys.stderr)
        raise SystemExit(1)
