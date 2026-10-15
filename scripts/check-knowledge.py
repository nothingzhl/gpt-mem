#!/usr/bin/env python3
"""Exercise knowledge management with temporary local fixtures; no user library writes or AI calls."""
from pathlib import Path
import importlib.util
import os
import platform
import subprocess
import tempfile
import argparse

SWIFT = r'''
import Foundation
import Observation
import SwiftUI
import AppKit
import GPTAnalysisKit
import GPTSessionKit
struct Failure: Error { let message: String }
final class NoCredentials: AICredentialStore {
    func key(for id: UUID) throws -> String? { nil }
    func setKey(_ key: String, for id: UUID) throws {}
    func deleteKey(for id: UUID) throws {}
}
actor KnowledgeMock: AIProviderClient {
    var count = 0
    func calls() -> Int { count }
    func analyze(input: AIAnalysisInput, configuration: AIProviderConfiguration, apiKey: String?) async throws -> AIAnalysisResult {
        count += 1
        return .init(summary: "发现一条稳定偏好", observations: [.init(text: "使用中文回答", evidenceIDs: ["m1"])], hypotheses: [], nextSteps: [], limitations: ["有限摘录，须人工审核"])
    }
}
final class ObservationChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
var assertions = 0
@MainActor func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    assertions += 1; if !value() { throw Failure(message: message) }
}
@MainActor func settle(_ model: KnowledgeDesktopModel) async throws {
    for _ in 0..<200 { if !model.isFiltering { return }; try await Task.sleep(nanoseconds: 10_000_000) }
    throw Failure(message: "filter did not finish")
}
@MainActor func checks() async throws {
    for (text, term) in [("Straße 中文", "STRASSE"), ("café", "cafe\u{301}"), ("Σίσυφος", "σίσυφος"), ("가", "가"), ("é", "e"), ("İstanbul", "istanbul"), ("中文规则", "规则"), ("中文", "不存在"), ("①", "1"), ("1", "①"), ("²", "2"), ("½", "1⁄2"), ("ﬃ", "ffi"), ("👩🏽‍💻", "👩"), ("👩🏽‍💻 👩", "👩"), ("a\u{0301}b", "a"), ("a\u{200D}b", "ab"), ("ＡＢＣ", "abc"), ("ß", "s"), ("ﬃ", "f"), ("ﬃ", "ff"), ("ß", "SS"), ("ss", "ß"), ("ᄀᄀ", "ᄀ"), ("ß①", "s1")] {
        try expect(KnowledgeSearchText(text).contains(KnowledgeSearchText.fold(term)) == text.localizedCaseInsensitiveContains(term), "indexed search preserves Unicode/case semantics")
    }
    let unicodePieces = ["a", "A", "中", "文", "é", "e\u{0301}", "e", "E", "a\u{0315}\u{0300}", "👩🏽‍💻", "👩", "🏽", "💻", "\u{200D}", "👩💻", "ß", "s", "SS", "ﬃ", "f", "ff", "fi", "ffi", "ᄀᄀ", "ᄀ", "①", "1", "²", "2", "½", "1⁄2", "１", "Ⅳ", "IV", "٤", "4", "ﬓ", "մն", "Å", "Å", "Σ", "ς", "σ", "İ", "i", "i\u{0307}", "\u{FE0F}", "🇺🇸", "🇺", "🇸", "\r\n", "\n", " ", "\u{00A0}", "א", "שׁ", "ש", "Ａ", "𝕒"]
    for piece in unicodePieces {
        for text in [piece, "head" + piece + "tail", piece + " " + piece] {
            let indexed = KnowledgeSearchText(text)
            for term in unicodePieces {
                try expect(indexed.contains(KnowledgeSearchText.fold(term)) == text.localizedCaseInsensitiveContains(term), "native Unicode search differential: " + text.debugDescription + " / " + term.debugDescription)
            }
        }
    }
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KNOWLEDGE_FIXTURE"]!)
    let sources = root.appendingPathComponent("sources")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let sourceData = Data("# Codex 记忆\n/repo/a 使用中文".utf8)
    try sourceData.write(to: sources.appendingPathComponent("MEMORY.md"))
    let model = KnowledgeDesktopModel(directoryURL: root.appendingPathComponent("library"), sourceRoot: sources)
    await model.loadIfNeeded(); try await settle(model)
    try expect(model.catalog.entries.isEmpty, "empty library")
    try expect(!FileManager.default.fileExists(atPath: model.directoryURL.path), "initial read must not create store")
    await model.readSources(); try await settle(model)
    try expect(model.filteredSources.count == 1, "source indexing")
    let originalSource = model.filteredSources[0]
    let controls = ObservationChanges(), sourceCatalogChanges = ObservationChanges(), results = ObservationChanges(), queryChanges = ObservationChanges()
    withObservationTracking { _ = model.isSaving; _ = model.loadError } onChange: { controls.increment() }
    withObservationTracking { _ = model.sourceCatalog } onChange: { sourceCatalogChanges.increment() }
    withObservationTracking { _ = model.filteredSources } onChange: { results.increment() }
    withObservationTracking { _ = model.query } onChange: { queryChanges.increment() }
    for query in ["Codex", "记忆", "中文"] { model.query = query; try await settle(model) }
    try expect(controls.count == 0, "search never invalidates original item controls")
    try expect(sourceCatalogChanges.count == 0, "search never invalidates source metadata/text observers")
    try expect(results.count == 0, "same source matches never republish source list")
    try expect(queryChanges.count == 1, "search field observers receive genuine input")
    try expect(model.searchIndexByteCount > 0 && model.searchIndexByteCount <= sourceData.count * 2, "source index stays within fixture memory budget")
    model.query = ""; try await settle(model)
    try expect(model.originalBackups.isEmpty, "read source does not create operation backups")
    let originalWithItem = "# Fixture\n- Original rule\n\n- Keep rule\n"
    try Data(originalWithItem.utf8).write(to: sources.appendingPathComponent("MEMORY.md"))
    await model.readSources(); try await settle(model)
    let editableSource = model.filteredSources[0]
    let item = CodexMemoryItem.parse(editableSource.text)[0]
    let changed = try item.replacing(in: editableSource.text, with: "- Reviewed rule\n\n")
    let applied = await model.editOriginal(source: editableSource, replacement: changed, action: "编辑单条记忆")
    try expect(applied && model.originalBackups.count == 1, "reviewed original edit saves backup")
    let backup = model.originalBackups[0]
    let stale = await model.editOriginal(source: editableSource, replacement: "- Stale overwrite\n", action: "编辑单条记忆")
    try expect(!stale && model.sourceError != nil, "stale original draft rejected")
    let restoredOriginal = await model.restoreOriginal(backup)
    try expect(restoredOriginal, "original rollback")
    let restoredText = try String(contentsOf: sources.appendingPathComponent("MEMORY.md"), encoding: .utf8)
    try expect(restoredText == originalWithItem, "original contents restored exactly")
    await model.removeOriginalBackup(backup)
    try expect(model.originalBackups.count == 1, "explicit backup removal preserves remaining backup")
    try sourceData.write(to: sources.appendingPathComponent("MEMORY.md"))
    await model.readSources(); try await settle(model)
    var draft = originalSource.importedDraft()
    model.editor = .init(draft: draft, expected: nil)
    try expect(model.catalog.entries.isEmpty, "opening editor must not save")
    let save = await model.save(model.editor!)
    try expect(save && model.catalog.entries.count == 1, "save reviewed source draft")
    let first = model.catalog.entries[0]
    try expect(first.current.state == .draft, "import never active")
    draft.state = .active; draft.scope = .project; draft.projectPath = "/repo/a"
    let activated = await model.save(.init(draft: draft, expected: first)); try expect(activated, "activate after review")
    let active = model.catalog.entries[0]
    try expect(active.revision == 2, "complete version")
    model.query = "no match"; model.query = "中文"; model.projectFilter = "/repo/a"; try await settle(model)
    try expect(model.filteredEntries.count == 1 && model.filteredSources.count == 1, "latest filter wins")
    model.query = ""; model.projectFilter = ""; try await settle(model)
    let retainedEditor = model.editor?.draft
    let oldDraft = first.current
    let failed = await model.save(.init(draft: oldDraft, expected: first))
    try expect(!failed && model.operationError != nil, "stale save rejected")
    try expect(model.editor?.draft == retainedEditor, "error preserves editor draft")
    try expect(model.catalog.entries[0].current.state == .active, "stale save leaves catalog intact")
    await model.changeState(active, to: .archived); try await settle(model)
    try expect(model.filteredEntries.isEmpty, "archived hidden")
    model.includeArchived = true; try await settle(model)
    try expect(model.filteredEntries.count == 1, "archived discoverable")
    let archived = model.catalog.entries[0]
    await model.changeState(archived, to: .draft)
    let secondDraft = KnowledgeDraft(title: "补充规则", body: "先说明结果", scope: .project, projectPath: "/repo/a")
    let added = await model.save(.init(draft: secondDraft, expected: nil)); try expect(added, "second entry")
    model.beginMerge(model.catalog.entries)
    try expect(model.editor?.mergeSource != nil, "merge review only")
    let countBefore = model.catalog.entries.count
    let merged = await model.save(model.editor!); try expect(merged, "merge save")
    try expect(model.catalog.entries.count == countBefore, "merge preserves both histories")
    try expect(model.catalog.entries.filter { $0.current.state == .archived }.count == 1, "source archived atomically")
    let unchangedSource = try Data(contentsOf: sources.appendingPathComponent("MEMORY.md")); try expect(unchangedSource == sourceData, "original source unchanged")
    await model.readSources(root: root.appendingPathComponent("missing")); try await settle(model)
    try expect(model.filteredSources.isEmpty && !model.sourceCatalog.warnings.isEmpty, "missing source explicit")
    let libraryIndexBytes = model.searchIndexByteCount
    await model.readSources(root: sources); model.includeArchived = true; try await settle(model)
    try expect(model.searchIndexByteCount > libraryIndexBytes, "missing source snapshot releases old source index")
    let reopened = KnowledgeDesktopModel(directoryURL: model.directoryURL, sourceRoot: sources)
    await reopened.loadIfNeeded(); try await settle(reopened)
    try expect(reopened.catalog == model.catalog, "persistence reopened")
    let target = model.catalog.entries.first { $0.current.state != .archived }!
    await model.trash(target); try await settle(model)
    try expect(!model.filteredEntries.contains { $0.id == target.id }, "trash hidden from normal library")
    model.showTrash = true; try await settle(model)
    try expect(model.filteredEntries.count == 1, "trash visible in trash view")
    let trashed = model.filteredEntries[0]
    await model.trash(trashed, restore: true); try await settle(model)
    try expect(model.filteredEntries.isEmpty, "restore removes from trash view")
    model.showTrash = false; try await settle(model)
    let restored = model.catalog.entries.first { $0.id == target.id }!
    try expect(restored.versions == target.versions, "trash restore preserves complete history")
    await model.trash(restored); try await settle(model)
    let removal = model.catalog.entries.first { $0.id == target.id }!
    await model.trash(removal, permanently: true); try await settle(model)
    try expect(!model.catalog.entries.contains { $0.id == target.id }, "explicit permanent deletion removes entry")
    let credentials = NoCredentials(), client = KnowledgeMock()
    let store = AIConfigurationStore(url: root.appendingPathComponent("mock-ai.json"))
    let ai = DesktopAIModel(configurationStore: store, credentials: credentials, coordinator: AIAnalysisCoordinator(client: client, credentials: credentials))
    let provider = AIProviderConfiguration(name: "模拟本地来源", kind: .ollama, baseURL: "http://localhost:11434", model: "fixture")
    try expect(ai.saveProvider(provider, key: "", clearKey: false), "mock source configured")
    let shared = DesktopAIModel(configurationStore: store, credentials: credentials, reportLibrary: ai.reportLibrary, promptLibrary: ai.promptLibrary)
    try expect(shared.reportLibrary === ai.reportLibrary && shared.promptLibrary === ai.promptLibrary, "shared reports and prompt templates")
    let summary = CodexSessionSummary(id: "fixture", sessionID: "fixture", fileURL: root.appendingPathComponent("fixture.jsonl"), title: "偏好来源", projectPath: "/repo/a")
    let module = try KnowledgeExtractionModule(transcript: .init(summary: summary, messages: [.init(id: "user", kind: .user, text: "使用中文回答")]))
    await ai.configurePrompt(for: KnowledgeExtractionModule.moduleID)
    ai.prepare(module: module, subjectLabels: module.subjectLabels, windowSelectionSeconds: 1)
    guard let preview = ai.preview else { throw Failure(message: "missing extraction preview") }
    let beforeCalls = await client.calls()
    try expect(beforeCalls == 0 && !ai.isAnalyzing, "preview never sends")
    let libraryBefore = model.catalog
    ai.beginAnalysis(preview)
    for _ in 0..<300 { if !ai.isAnalyzing && !ai.reportLibrary.isSaving { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    guard let record = ai.record, let input = ai.recordInput else { throw Failure(message: "missing mock result") }
    let calls = await client.calls()
    try expect(calls == 1 && ai.analysisError == nil, "only explicit confirmation sends")
    let drafts = try KnowledgeExtractionModule.drafts(record: record, input: input, source: summary, subjectLabels: ai.recordSubjectLabels)
    try expect(drafts.count == 1 && drafts[0].state == .draft, "mock candidate stays draft")
    let candidateCache = KnowledgeExtractionCandidateCache()
    let cached = candidateCache.evaluate(prepared: input, input: input, record: record, source: summary, labels: ai.recordSubjectLabels, context: input.context, prompt: input.prompt)
    let cachedAgain = candidateCache.evaluate(prepared: input, input: input, record: record, source: summary, labels: ai.recordSubjectLabels, context: input.context, prompt: input.prompt)
    try expect(cached.drafts.count == 1 && cached.drafts.map(\.id) == cachedAgain.drafts.map(\.id), "candidate identity survives redraw")
    let changedContext = candidateCache.evaluate(prepared: input, input: input, record: record, source: summary, labels: ai.recordSubjectLabels, context: "changed", prompt: input.prompt)
    try expect(changedContext.drafts.isEmpty, "changed extraction context cannot reuse cached candidates")
    let wrongSource = CodexSessionSummary(id: "other", sessionID: "other", fileURL: root.appendingPathComponent("other.jsonl"), title: "wrong")
    let wrongCandidates = candidateCache.evaluate(prepared: input, input: input, record: record, source: wrongSource, labels: ai.recordSubjectLabels, context: input.context, prompt: input.prompt)
    try expect(wrongCandidates.drafts.isEmpty && wrongCandidates.error != nil, "invalid source still fails cached candidate validation")
    try expect(model.catalog == libraryBefore, "AI completion does not write knowledge")
    model.editor = .init(draft: drafts[0], expected: nil)
    try expect(model.catalog == libraryBefore, "review opening does not write knowledge")
    try expect(ai.reportLibrary.reports.count == 1, "report saved separately")
    if let output = ProcessInfo.processInfo.environment["KNOWLEDGE_RENDER"] {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let renderAI = DesktopAIModel(configurationStore: AIConfigurationStore(url: root.appendingPathComponent("empty-ai.json")), credentials: credentials)
        let sessions = SessionDesktopModel(indexDirectoryURL: root.appendingPathComponent("index"), managementDirectoryURL: root.appendingPathComponent("management"))
        model.editor = nil
        let content = KnowledgeWorkspace(model: model, ai: renderAI, sessions: sessions, onOpenSessions: {})
            .background(MemoryStyle.background).foregroundStyle(MemoryStyle.text).tint(MemoryStyle.accent).preferredColorScheme(.light)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure(message: "render") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "png") }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: output).deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: output)); window.close()
    }
    print("PASS knowledge desktop: \(assertions) checks, temporary sources/store only")
}
Task { @MainActor in
    do { try await checks(); exit(0) } catch { print("FAIL \(error)"); exit(1) }
}
RunLoop.main.run()
'''

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--render')
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location('desktop_ai', project / 'scripts/check-desktop-ai.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    release, objects = helper.release_inputs(project)
    with tempfile.TemporaryDirectory(prefix='gpt-knowledge-check-') as temp:
        directory = Path(temp)
        source = directory / 'main.swift'; source.write_text(SWIFT)
        executable = directory / 'checks'
        names = ['KnowledgeDesktopModel.swift', 'KnowledgeViews.swift', 'KnowledgeExtractionViews.swift', 'DesktopAIModel.swift', 'PromptTemplateLibraryModel.swift', 'AIReportLibraryModel.swift', 'SessionDesktopModel.swift', 'SessionManagementModel.swift', 'AIViews.swift', 'AIReportViews.swift', 'AIProviderEditorModel.swift', 'PromptTemplateViews.swift', 'Style.swift', 'SessionViews.swift', 'SessionProjectViews.swift', 'SessionManagementViews.swift', 'SessionHandoffAIViews.swift']
        command = ['swiftc', '-swift-version', '5', '-target', f'{platform.machine()}-apple-macosx14.0', '-module-cache-path', str(directory / 'cache'), '-I', str(release / 'Modules'), '-I', str(release / 'CNative.build'), '-o', str(executable)]
        command += [str(project / 'Sources/GPTMemoryDesktop' / name) for name in names] + [str(source)] + [str(obj) for obj in objects] + ['-lproc', '-lsqlite3']
        subprocess.run(command, cwd=project, check=True, timeout=120)
        env = os.environ.copy(); env['KNOWLEDGE_FIXTURE'] = str(directory / 'fixtures')
        if args.render: env['KNOWLEDGE_RENDER'] = str(Path(args.render).resolve())
        subprocess.run([str(executable)], env=env, check=True, timeout=30)

if __name__ == '__main__': main()
