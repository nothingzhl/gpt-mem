#!/usr/bin/env python3
"""Check the real desktop AI model against local mocks; optionally render its UI.

Uses already-built release modules and objects. No real Keychain, network, app
launch, default history, or UserDefaults writes are involved.
"""
from pathlib import Path
import argparse
import os
import platform
import subprocess
import sys
import tempfile


SWIFT_CHECKS = r'''
import Foundation
import Darwin
import GPTAnalysisKit
import GPTSessionKit
#if RENDER_AI
import AppKit
import SwiftUI
#endif

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor var assertionCount = 0
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    assertionCount += 1
    if !condition() { throw CheckFailure(description: message) }
}

final class MockCredentials: AICredentialStore {
    private var values: [UUID: String] = [:]
    func key(for id: UUID) throws -> String? { values[id] }
    func setKey(_ key: String, for id: UUID) throws { values[id] = key }
    func deleteKey(for id: UUID) throws { values.removeValue(forKey: id) }
}

struct CapturedRequest {
    let input: AIAnalysisInput
    let configuration: AIProviderConfiguration
    let apiKey: String?
}

actor MockAIClient: AIProviderClient {
    private var requests: [CapturedRequest] = []
    func captured() -> [CapturedRequest] { requests }

    func analyze(input: AIAnalysisInput, configuration: AIProviderConfiguration,
                 apiKey: String?) async throws -> AIAnalysisResult {
        requests.append(CapturedRequest(input: input, configuration: configuration, apiKey: apiKey))
        if input.context == "slow-old" {
            // Intentionally ignore task cancellation, like an already accepted request.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) { continuation.resume() }
            }
        }
        if input.context == "fail" { throw AIAnalysisError.transport("模拟来源失败") }
        if input.context == "length-limit-always" || (input.context == "length-limit" && configuration.maxOutputTokens < 8192) {
            throw AIAnalysisError.generationLengthLimit(limit: configuration.maxOutputTokens,
                generatedTokens: configuration.maxOutputTokens, reasoningTokens: 1200)
        }
        if input.moduleID == SessionHandoffAIModule.moduleID {
            return AIAnalysisResult(summary: "模拟交接：继续实现搜索功能",
                observations: [.init(text: "用户要求继续实现搜索，需核对代码。", evidenceIDs: ["m1"])],
                hypotheses: [], nextSteps: [.init(subjectID: "session", action: "核对实现和测试", purpose: "确认当前进度")],
                limitations: ["只是冻结会话摘录，不代表当前代码。"])
        }
        return AIAnalysisResult(
            summary: "模拟服务：\(input.context)",
            observations: [AIObservation(text: "模拟事实显示 12 份样本内增长 150 MiB。",
                                         evidenceIDs: ["fixture.fact"])],
            hypotheses: [AIHypothesis(title: "模拟假设：活动结束后缓存尚未释放",
                explanation: "增长与主动补充的活动说明相符，需要核对活动结束后的占用变化。",
                evidenceIDs: ["fixture.fact"], missingEvidence: ["活动结束后的新样本", "进程内存摘要"])],
            nextSteps: [AINextStep(subjectID: "s1", action: "核对本地映射中的进程实例，再手动采集诊断摘要。",
                                  purpose: "区分可回收缓存与持续增长。")],
            limitations: ["这是 mock 流程的模拟结果，没有调用真实模型，也不代表真实进程诊断。"])
    }
}

final class MutableFixtureModule: AIAnalysisModule {
    var input: AIAnalysisInput
    init(_ input: AIAnalysisInput) { self.input = input }
    func makeInput() throws -> AIAnalysisInput { input }
}

func fixtureInput(_ context: String, offset: TimeInterval = 0) -> AIAnalysisInput {
    let start = Date(timeIntervalSince1970: 1_791_792_000 + offset)
    return AIAnalysisInput(moduleID: "fixture", moduleTitle: "模拟内存分析", promptVersion: "fixture-1",
        guidance: "只依据模拟事实给出中文结论，区分事实和待验证假设。",
        windowStart: start, windowEnd: start.addingTimeInterval(600),
        facts: [AIAnalysisFact(id: "fixture.fact", title: "模拟窗口增长", data: .object([
            "sampleCount": .number(12), "growthMiB": .number(150), "subjectID": .string("s1")
        ]))], subjects: [AIAnalysisSubject(id: "s1", label: "模拟对象 s1", canInspect: true)], context: context)
}

@MainActor struct Fixture {
    let model: DesktopAIModel
    let credentials: MockCredentials
    let client: MockAIClient
    let store: AIConfigurationStore
    var provider: AIProviderConfiguration { model.settings.providers[0] }
}

@MainActor func makeFixture(_ name: String) throws -> Fixture {
    guard let directory = ProcessInfo.processInfo.environment["GPT_DESKTOP_AI_CHECK_DIR"] else {
        throw CheckFailure(description: "missing temporary fixture directory")
    }
    let store = AIConfigurationStore(url: URL(fileURLWithPath: directory)
        .appendingPathComponent(name).appendingPathComponent("ai-services.json"))
    let credentials = MockCredentials()
    let client = MockAIClient()
    let coordinator = AIAnalysisCoordinator(client: client, credentials: credentials)
    let model = DesktopAIModel(configurationStore: store, credentials: credentials, coordinator: coordinator)
    let provider = AIProviderConfiguration(name: "模拟服务", kind: .openAIResponses,
        baseURL: "https://fixture.invalid/v1", model: "fixture-model")
    try expect(model.saveProvider(provider, key: "fixture-old-key", clearKey: false), "initial provider save")
    return Fixture(model: model, credentials: credentials, client: client, store: store)
}

@MainActor func waitUntilIdle(_ model: DesktopAIModel) async throws {
    let deadline = Date().addingTimeInterval(3)
    while model.isAnalyzing {
        if Date() >= deadline { throw CheckFailure(description: "analysis did not finish within timeout") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor func waitForRequests(_ client: MockAIClient, count: Int) async throws {
    let deadline = Date().addingTimeInterval(3)
    while await client.captured().count < count {
        if Date() >= deadline { throw CheckFailure(description: "mock request did not start within timeout") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor func prepare(_ fixture: Fixture, input: AIAnalysisInput,
                        labels: [String: String] = ["s1": "模拟对象 · 本地实例 A"]) throws -> AIAnalysisPreview {
    fixture.model.activityContext = input.context
    fixture.model.updateWindow(start: input.windowStart, end: input.windowEnd, selectionSeconds: 1800)
    fixture.model.prepare(module: MutableFixtureModule(input), subjectLabels: labels, windowSelectionSeconds: 1800)
    guard let prepared = fixture.model.preview else { throw CheckFailure(description: "preview was not prepared") }
    return prepared
}

@MainActor func checkProviderCRUD() async throws {
    let fixture = try makeFixture("crud")
    let firstID = fixture.provider.id
    let compatible = AIProviderConfiguration(name: "模拟兼容来源", kind: .openAICompatible,
        baseURL: "https://compatible.invalid/v1", model: "fixture-model")
    let ollama = AIProviderConfiguration(name: "模拟本机来源", kind: .ollama,
        baseURL: "http://localhost:11434", model: "fixture-model")
    try expect(fixture.model.saveProvider(compatible, key: "fixture-compatible-key", clearKey: false), "add compatible source")
    try expect(fixture.model.saveProvider(ollama, key: "", clearKey: false), "add local source without key")
    try expect(fixture.model.settings.providers.count == 3, "three provider kinds coexist")
    try expect(fixture.model.selectProvider(ollama.id), "select local source")
    try expect(fixture.model.settings.selectedProviderID == ollama.id, "selection persisted")

    var edit = fixture.provider
    edit.name = "模拟服务已编辑"
    let revision = edit.revision
    try expect(fixture.model.saveProvider(edit, key: "", clearKey: false), "edit with empty secret")
    let retainedKey = try fixture.credentials.key(for: firstID)
    try expect(retainedKey == "fixture-old-key", "empty secret retains existing key")
    try expect(fixture.provider.revision == revision + 1, "editing increments revision")
    try expect(fixture.model.saveProvider(fixture.provider, key: "ignored", clearKey: true), "explicitly clear secret")
    let clearedKey = try fixture.credentials.key(for: firstID)
    try expect(clearedKey == nil, "clear flag removes key independently")
    try expect(fixture.model.saveProvider(fixture.provider, key: "fixture-restored-key", clearKey: false), "restore mock key")
    let contents = try String(contentsOf: fixture.store.url, encoding: .utf8)
    try expect(!contents.contains("fixture-restored-key") && !contents.contains("fixture-compatible-key"), "configuration contains no secrets")

    try expect(fixture.model.selectProvider(firstID), "select first source")
    _ = try prepare(fixture, input: fixtureInput("crud-preview"))
    try expect(fixture.model.saveProvider(fixture.provider, key: "", clearKey: false), "save related preview source")
    try expect(fixture.model.preview == nil, "saving source clears its preview")
    _ = try prepare(fixture, input: fixtureInput("crud-remove"))
    fixture.model.removeProvider(firstID)
    try expect(fixture.model.preview == nil, "removing source clears its preview")
    try expect(fixture.model.settings.providers.count == 2, "remove one source")
    let removedKey = try fixture.credentials.key(for: firstID)
    try expect(removedKey == nil, "source removal deletes corresponding mock key")
    try expect(fixture.model.settings.providers.contains { $0.id == fixture.model.settings.selectedProviderID }, "removed selection changes to existing source")
    let calls = await fixture.client.captured()
    try expect(calls.isEmpty, "provider CRUD and previews send no requests")
    print("PASS provider CRUD, selection, credential semantics, preview invalidation")
}

@MainActor func checkCorruptConfiguration() throws {
    let fixture = try makeFixture("corrupt")
    let broken = Data("{broken configuration".utf8)
    try broken.write(to: fixture.store.url)
    fixture.model.reloadSettings()
    try expect(fixture.model.configurationError != nil, "corrupt configuration is visible")
    try expect(!fixture.model.saveProvider(fixture.provider, key: "replacement", clearKey: false), "corrupt configuration blocks save")
    try expect(!fixture.model.selectProvider(nil), "corrupt configuration blocks selection save")
    fixture.model.removeProvider(fixture.provider.id)
    let preservedData = try Data(contentsOf: fixture.store.url)
    try expect(preservedData == broken, "corrupt file is not overwritten")
    let key = try fixture.credentials.key(for: fixture.provider.id)
    try expect(key == "fixture-old-key", "blocked mutation leaves credential unchanged")
    try fixture.store.save(AISettings())
    fixture.model.reloadSettings()
    try expect(fixture.model.configurationError == nil && fixture.model.settings.providers.isEmpty, "reloading repaired configuration recovers")
    print("PASS corrupt configuration protection and recovery")
}

@MainActor func checkModelDiscoveryCredentials() throws {
    let fixture = try makeFixture("model-discovery")
    let original = try Data(contentsOf: fixture.store.url)
    let saved = fixture.provider
    let retained = try fixture.model.modelDiscoveryKey(configuration: saved, draftKey: "", clearKey: false)
    try expect(retained == "fixture-old-key", "model discovery can reuse same destination saved key")
    let typed = try fixture.model.modelDiscoveryKey(configuration: saved, draftKey: " fixture-new-key ", clearKey: false)
    try expect(typed == "fixture-new-key", "typed draft key takes precedence")
    let cleared = try fixture.model.modelDiscoveryKey(configuration: saved, draftKey: "ignored", clearKey: true)
    try expect(cleared == nil, "clear key flag prevents reuse for model discovery")
    var changed = saved
    changed.baseURL = "https://other.invalid/v1"
    var refused = false
    do { _ = try fixture.model.modelDiscoveryKey(configuration: changed, draftKey: "", clearKey: false) }
    catch { refused = true }
    try expect(refused, "changed destination cannot silently reuse saved key")
    changed = saved
    changed.kind = .openAICompatible
    refused = false
    do { _ = try fixture.model.modelDiscoveryKey(configuration: changed, draftKey: "", clearKey: false) }
    catch { refused = true }
    try expect(refused, "changed protocol cannot silently reuse saved key")
    changed = saved
    changed.baseURL = "http://localhost:11434"
    changed.kind = .ollama
    let local = try fixture.model.modelDiscoveryKey(configuration: changed, draftKey: "", clearKey: false)
    try expect(local == nil, "local source does not inherit remote saved key")
    let after = try Data(contentsOf: fixture.store.url)
    let stored = try fixture.credentials.key(for: saved.id)
    try expect(after == original && stored == "fixture-old-key", "discovery leaves saved metadata and key unchanged")
    changed = saved
    changed.baseURL = "https://other.invalid/v1"
    try expect(!fixture.model.saveProvider(changed, key: "", clearKey: false), "changed destination cannot save with silently retained key")
    let preservedKey = try fixture.credentials.key(for: saved.id)
    try expect(fixture.provider == saved && preservedKey == "fixture-old-key", "rejected save preserves source and key")
    try expect(fixture.model.saveProvider(changed, key: "fixture-other-key", clearKey: false), "changed destination accepts its new key")
    let replacedKey = try fixture.credentials.key(for: saved.id)
    try expect(replacedKey == "fixture-other-key", "new destination stores its explicitly supplied key")
    changed = fixture.provider
    changed.kind = .ollama
    changed.baseURL = "http://localhost:11434"
    try expect(fixture.model.saveProvider(changed, key: "", clearKey: true), "keyless local destination permits explicitly clearing saved key")
    let noLocalKey = try fixture.credentials.key(for: saved.id)
    try expect(noLocalKey == nil, "local destination has no inherited remote key")
    print("PASS model discovery binds credentials to their saved destination")
}

@MainActor func checkFrozenPreviewAndStaleness() async throws {
    let fixture = try makeFixture("frozen")
    let input = fixtureInput("frozen-input")
    let module = MutableFixtureModule(input)
    var labels = ["s1": "模拟对象 · 本地实例 A"]
    fixture.model.activityContext = input.context
    fixture.model.updateWindow(start: input.windowStart, end: input.windowEnd, selectionSeconds: 1800)
    fixture.model.prepare(module: module, subjectLabels: labels, windowSelectionSeconds: 1800)
    guard let prepared = fixture.model.preview else { throw CheckFailure(description: "missing frozen preview") }
    let before = await fixture.client.captured()
    try expect(before.isEmpty, "preparing preview sends zero requests")
    try expect(prepared.input == input && prepared.subjectLabels == labels, "preview freezes input and local labels")
    module.input = fixtureInput("replacement-input", offset: 90)
    labels["s1"] = "模拟对象 · 不同本地实例 B"
    fixture.model.beginAnalysis(prepared)
    try await waitUntilIdle(fixture.model)
    let calls = await fixture.client.captured()
    try expect(calls.count == 1 && calls[0].input == input, "confirmed request sends the frozen input")
    try expect(fixture.model.recordInput == input, "result keeps the same input")
    try expect(fixture.model.recordSubjectLabels["s1"] == "模拟对象 · 本地实例 A", "result uses frozen alias mapping")
    try expect(fixture.model.record?.providerName == "模拟服务" && fixture.model.record?.model == "fixture-model", "result includes simulated source metadata")
    try expect(!fixture.model.resultIsStale, "unchanged window context and source are current")
    fixture.model.updateWindow(start: input.windowStart, end: input.windowEnd.addingTimeInterval(1), selectionSeconds: 1800)
    try expect(fixture.model.resultIsStale, "new sample window marks old result stale")
    fixture.model.updateWindow(start: input.windowStart, end: input.windowEnd, selectionSeconds: 1800)
    fixture.model.activityContext = "new activity description"
    try expect(fixture.model.resultIsStale, "changed context marks result stale without sampling")
    fixture.model.activityContext = input.context
    let other = AIProviderConfiguration(name: "模拟其他来源", kind: .ollama, baseURL: "http://localhost:11434", model: "fixture-model")
    try expect(fixture.model.saveProvider(other, key: "", clearKey: false), "add alternate source")
    try expect(fixture.model.selectProvider(other.id), "select alternate source")
    try expect(fixture.model.resultIsStale, "changed provider marks old result stale")
    print("PASS zero-request preview, frozen input and aliases, result provenance and staleness")
}

@MainActor func checkRejectChangedDestination() async throws {
    let fixture = try makeFixture("reject")
    let prepared = try prepare(fixture, input: fixtureInput("reject-destination"))
    var changed = fixture.provider
    changed.baseURL = "https://replacement.invalid/v1"
    try expect(fixture.model.saveProvider(changed, key: "fixture-replacement-key", clearKey: false), "change same ID destination and key")
    fixture.model.beginAnalysis(prepared)
    let calls = await fixture.client.captured()
    try expect(calls.isEmpty && !fixture.model.isAnalyzing, "stale approved destination is never sent")
    try expect(fixture.model.analysisError?.contains("重新预览") == true, "changed destination asks for a fresh preview")

    let next = try prepare(fixture, input: fixtureInput("reject-corrupt"))
    try Data("invalid".utf8).write(to: fixture.store.url)
    fixture.model.beginAnalysis(next)
    let corruptCalls = await fixture.client.captured()
    try expect(corruptCalls.isEmpty && fixture.model.configurationError != nil, "confirmation rereads and rejects corrupt persisted configuration")
    print("PASS confirmation rejects changed destinations and unreadable persisted metadata")
}

@MainActor func checkCredentialSnapshot() async throws {
    let fixture = try makeFixture("credential-snapshot")
    let prepared = try prepare(fixture, input: fixtureInput("bound-key"))
    fixture.model.beginAnalysis(prepared)
    // There is no await before this edit: the analysis Task has not started yet.
    var changed = fixture.provider
    changed.baseURL = "https://new-destination.invalid/v1"
    try expect(fixture.model.saveProvider(changed, key: "fixture-new-key", clearKey: false), "edit before asynchronous request starts")
    try await waitUntilIdle(fixture.model)
    let calls = await fixture.client.captured()
    try expect(calls.count == 1, "one bound confirmation request")
    try expect(calls[0].configuration == prepared.configuration, "request destination remains the approved configuration")
    try expect(calls[0].apiKey == "fixture-old-key", "request key remains the confirmation-time credential")
    let currentKey = try fixture.credentials.key(for: fixture.provider.id)
    try expect(currentKey == "fixture-new-key", "later edit still updates the stored credential")
    try expect(fixture.model.resultIsStale, "result preserves provenance after source edit")
    print("PASS destination and credential bound before async task execution")
}

@MainActor func checkCancellationAndFailure() async throws {
    let fixture = try makeFixture("cancellation")
    let old = try prepare(fixture, input: fixtureInput("slow-old"), labels: ["s1": "模拟旧实例"])
    fixture.model.beginAnalysis(old)
    try await waitForRequests(fixture.client, count: 1)
    fixture.model.cancelAnalysis()
    try expect(!fixture.model.isAnalyzing, "cancellation releases independent analysis state")
    let next = try prepare(fixture, input: fixtureInput("new-after-cancel", offset: 1), labels: ["s1": "模拟新实例"])
    fixture.model.beginAnalysis(next)
    try await waitUntilIdle(fixture.model)
    guard let newest = fixture.model.record else { throw CheckFailure(description: "new request did not produce a result") }
    try expect(newest.result.summary.contains("new-after-cancel"), "new request wins after cancellation")
    try await Task.sleep(nanoseconds: 450_000_000)
    try expect(fixture.model.record == newest, "late cancellation-ignoring mock cannot overwrite newer result")
    try expect(fixture.model.recordSubjectLabels == next.subjectLabels, "late completion cannot replace local alias provenance")
    try expect(fixture.model.analysisError == nil, "old cancelled task cannot add a new error")
    let failure = try prepare(fixture, input: fixtureInput("fail", offset: 2))
    fixture.model.beginAnalysis(failure)
    try await waitUntilIdle(fixture.model)
    try expect(fixture.model.analysisError != nil && fixture.model.record == newest, "request failure preserves previous record")
    try expect(fixture.model.recordInput == next.input && fixture.model.recordSubjectLabels == next.subjectLabels, "failure preserves previous input and local aliases")
    print("PASS cancelled late completion, new request ownership, failure preserves prior result")
}

@MainActor func checkSaveFailureRollback() throws {
    let fixture = try makeFixture("save-failure")
    let originalSettings = fixture.model.settings
    let backup = fixture.store.url.appendingPathExtension("saved")
    try FileManager.default.moveItem(at: fixture.store.url, to: backup)
    try FileManager.default.createDirectory(at: fixture.store.url, withIntermediateDirectories: false)
    defer {
        try? FileManager.default.removeItem(at: fixture.store.url)
        try? FileManager.default.moveItem(at: backup, to: fixture.store.url)
    }
    try expect(!fixture.model.selectProvider(nil), "selection save failure is returned")
    try expect(fixture.model.operationError != nil, "selection save failure remains visible to card")
    try expect(fixture.model.settings == originalSettings, "selection save failure keeps selected source")
    var changed = fixture.provider
    changed.name = "模拟保存失败"
    try expect(!fixture.model.saveProvider(changed, key: "fixture-rejected-key", clearKey: false), "configuration rename failure rejects edit")
    let restoredKey = try fixture.credentials.key(for: fixture.provider.id)
    try expect(restoredKey == "fixture-old-key", "configuration failure rolls credential back")
    try expect(fixture.model.settings == originalSettings, "failed edit preserves in-memory settings")
    try expect(FileManager.default.fileExists(atPath: backup.path), "failed replacement keeps original configuration backup")
    print("PASS selection save error and credential rollback on configuration write failure")
}

@MainActor func checkConfigurationConflict() throws {
    let fixture = try makeFixture("configuration-conflict")
    let opened = fixture.provider
    var edited = opened
    edited.name = "旧编辑页中的修改"
    var latest = fixture.model.settings
    latest.providers[0].model = "external-model"
    // Even a hand-edited file that does not increment revision is a conflict.
    try fixture.store.save(latest)
    try expect(!fixture.model.saveProvider(edited, key: "must-not-be-written", clearKey: false,
        expectedProvider: opened), "stale draft cannot overwrite externally changed source")
    try expect(fixture.model.operationError?.contains("编辑期间已变化") == true, "conflict gives a concrete recovery action")
    let preserved = try fixture.store.load()
    let key = try fixture.credentials.key(for: opened.id)
    try expect(preserved == latest && key == "fixture-old-key", "conflict preserves persisted source and credential")
    fixture.model.removeProvider(opened.id, expectedProvider: opened)
    let afterRemoval = try fixture.store.load()
    try expect(afterRemoval == latest, "stale remove confirmation cannot delete changed source")

    var unrelated = AIProviderPreset.ollama.makeConfiguration()
    unrelated.model = "fixture-local-model"
    latest.providers.append(unrelated)
    try fixture.store.save(latest)
    var current = fixture.provider
    current.name = "最新来源的编辑"
    try expect(fixture.model.saveProvider(current, key: "", clearKey: false,
        expectedProvider: fixture.provider), "current draft can save while preserving another new source")
    let merged = try fixture.store.load()
    try expect(merged.providers.count == 2 && merged.providers.contains(unrelated), "saving one source retains externally added source")
    var third = AIProviderPreset.ollama.makeConfiguration()
    third.model = "third-model"
    var withThird = merged
    withThird.providers.append(third)
    try fixture.store.save(withThird)
    try expect(fixture.model.selectProvider(third.id), "selection reads newly added source before persistence")
    let selected = try fixture.store.load()
    try expect(selected == fixture.model.settings && fixture.model.settings.providers.count == 3,
        "selection preserves latest complete metadata")

    let saved = fixture.provider
    var destinationChange = fixture.model.settings
    destinationChange.providers[0].baseURL = "https://changed-externally.invalid/v1"
    try fixture.store.save(destinationChange)
    var refused = false
    do { _ = try fixture.model.modelDiscoveryKey(configuration: saved, draftKey: "", clearKey: false) }
    catch { refused = true }
    try expect(refused, "stored key cannot follow a stale draft after persisted destination changed")
    print("PASS editing/removal conflicts, fresh source merging and current destination credential binding")
}

@MainActor func checkOutputBudgetPreview() async throws {
    let fixture = try makeFixture("preview-budget")
    try expect(fixture.provider.maxOutputTokens == 8192, "new sources default to a larger output budget")
    var low = fixture.provider
    low.maxOutputTokens = 2000
    try expect(fixture.model.saveProvider(low, key: "", clearKey: false), "save explicitly chosen old budget")
    let loaded = try fixture.store.load()
    try expect(loaded.providers[0].maxOutputTokens == 2000, "loading existing settings never silently raises their budget")
    let input = fixtureInput("budget-preview")
    let preview = try prepare(fixture, input: input, labels: ["s1": "冻结的本地对象"])
    try expect(fixture.model.increaseOutputLimitForPreview(preview), "raise budget before sending an old low-budget preview")
    guard let refreshed = fixture.model.preview else { throw CheckFailure(description: "missing refreshed budget preview") }
    try expect(refreshed.id != preview.id && refreshed.configuration.maxOutputTokens == 8192, "budget upgrade creates a fresh approval preview")
    try expect(refreshed.input == preview.input && refreshed.json == preview.json
        && refreshed.subjectLabels == preview.subjectLabels && refreshed.windowSelectionSeconds == preview.windowSelectionSeconds,
        "budget upgrade preserves exact frozen input, JSON, labels and window")
    try expect(fixture.provider.maxOutputTokens == 8192, "new budget is persisted for same source")
    let key = try fixture.credentials.key(for: fixture.provider.id)
    try expect(key == "fixture-old-key", "budget-only update preserves credential")
    let calls = await fixture.client.captured()
    try expect(calls.isEmpty, "budget upgrade never sends an analysis request")
    try expect(!fixture.model.increaseOutputLimitForPreview(preview), "obsolete approval preview cannot update settings")
    try expect(fixture.model.preview?.id == refreshed.id, "obsolete operation preserves current preview")

    let damaged = try makeFixture("preview-budget-unreadable")
    low = damaged.provider
    low.maxOutputTokens = 2000
    try expect(damaged.model.saveProvider(low, key: "", clearKey: false), "prepare low budget before file failure")
    let before = try prepare(damaged, input: fixtureInput("budget-unreadable"))
    let settings = damaged.model.settings
    try Data("invalid-configuration".utf8).write(to: damaged.store.url)
    try expect(!damaged.model.increaseOutputLimitForPreview(before), "unreadable settings reject budget update")
    try expect(damaged.model.settings == settings && damaged.model.preview?.id == before.id,
        "failed upgrade preserves old settings and preview")
    try expect(damaged.model.configurationError != nil && damaged.model.operationError != nil,
        "failed budget upgrade exposes error inside preview")
    let damagedCalls = await damaged.client.captured()
    try expect(damagedCalls.isEmpty, "failed budget update sends zero requests")
    print("PASS low-budget preview upgrade, immutable facts and no implicit request")
}

@MainActor func checkLengthLimitRecovery() async throws {
    let fixture = try makeFixture("length-recovery")
    var low = fixture.provider
    low.maxOutputTokens = 2000
    try expect(fixture.model.saveProvider(low, key: "", clearKey: false), "set small mock output budget")
    let success = try prepare(fixture, input: fixtureInput("successful-prior-report"))
    fixture.model.beginAnalysis(success)
    try await waitUntilIdle(fixture.model)
    guard let original = fixture.model.record else { throw CheckFailure(description: "missing prior report") }
    let failed = try prepare(fixture, input: fixtureInput("length-limit", offset: 1))
    fixture.model.beginAnalysis(failed)
    try await waitUntilIdle(fixture.model)
    try expect(fixture.model.record == original, "length failure retains previous report")
    try expect(fixture.model.analysisError?.contains("2000") == true && fixture.model.analysisError?.contains("长度") == true,
        "length failure shows actual request budget")
    try expect(fixture.model.suggestedOutputLimitAfterFailure == 8192, "failed same source offers larger output budget")
    var calls = await fixture.client.captured()
    try expect(calls.count == 2, "length failure is not automatically retried")
    try expect(fixture.model.increaseOutputLimitAfterFailure(), "raise same source after explicit recovery action")
    calls = await fixture.client.captured()
    try expect(calls.count == 2 && fixture.model.record == original, "budget recovery preserves report and sends no request")
    let retry = try prepare(fixture, input: failed.input)
    try expect(retry.configuration.maxOutputTokens == 8192, "new preview binds raised budget")
    fixture.model.beginAnalysis(retry)
    try await waitUntilIdle(fixture.model)
    calls = await fixture.client.captured()
    try expect(calls.count == 3 && calls[2].configuration.maxOutputTokens == 8192, "only a new confirmation sends raised-budget request")
    try expect(fixture.model.analysisError == nil && fixture.model.outputLimitFailureConfiguration == nil,
        "successful explicitly confirmed request clears recovery state")

    let changed = try makeFixture("length-other-source")
    let old = try prepare(changed, input: fixtureInput("length-limit-always"))
    changed.model.beginAnalysis(old)
    try await waitUntilIdle(changed.model)
    try expect(changed.model.suggestedOutputLimitAfterFailure == 16384, "8192 failure can suggest 16384")
    var alternate = AIProviderPreset.ollama.makeConfiguration()
    alternate.model = "fixture-model"
    try expect(changed.model.saveProvider(alternate, key: "", clearKey: false), "add alternate source after failure")
    try expect(changed.model.selectProvider(alternate.id), "select another source after failure")
    let before = changed.model.settings
    try expect(changed.model.suggestedOutputLimitAfterFailure == nil, "other source never receives old failure recovery suggestion")
    try expect(!changed.model.increaseOutputLimitAfterFailure() && changed.model.settings == before,
        "old failure cannot modify another selected source")
    let changedCalls = await changed.client.captured()
    try expect(changedCalls.count == 1, "changing source or refusing old recovery sends no request")

    let capped = try makeFixture("length-max-budget")
    var maximum = capped.provider
    maximum.maxOutputTokens = 16384
    try expect(capped.model.saveProvider(maximum, key: "", clearKey: false), "set maximum budget")
    let cappedPreview = try prepare(capped, input: fixtureInput("length-limit-always"))
    capped.model.beginAnalysis(cappedPreview)
    try await waitUntilIdle(capped.model)
    try expect(capped.model.suggestedOutputLimitAfterFailure == nil, "maximum budget never suggests exceeding allowed bound")
    try expect(!capped.model.increaseOutputLimitAfterFailure(), "maximum budget cannot be increased")
    print("PASS length failure retention, bounded same-source recovery and explicit new confirmation")
}

#if RENDER_AI
struct MockModelCatalog: AIModelCatalogClient {
    func models(configuration: AIProviderConfiguration, apiKey: String?) async throws -> [String] {
        ["fixture-analysis-model"]
    }
}

@MainActor func renderFixture(to path: String) async throws {
    let fixture = try makeFixture("render")
    let prepared = try prepare(fixture, input: fixtureInput("模拟增长窗口：打开页面后占用增加"),
        labels: ["s1": "模拟页面进程 · 本地实例 A"])
    fixture.model.beginAnalysis(prepared)
    try await waitUntilIdle(fixture.model)
    var constrained = fixture.provider
    constrained.maxOutputTokens = 2000
    try expect(fixture.model.saveProvider(constrained, key: "", clearKey: false), "render low budget simulation")
    let failed = try prepare(fixture, input: fixtureInput("length-limit"), labels: ["s1": "模拟页面进程 · 本地实例 A"])
    fixture.model.beginAnalysis(failed)
    try await waitUntilIdle(fixture.model)
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    let content = VStack(alignment: .leading, spacing: 18) {
        Text("桌面 AI 工作流预览 · 模拟数据").font(.system(size: 24, weight: .semibold))
        Text("模拟来源与模拟模型；没有调用真实模型。").font(.system(size: 12)).foregroundStyle(MemoryStyle.secondary)
        AIAnalysisCard(model: fixture.model, hasInput: true, onPrepare: {})
        AISettingsView(model: fixture.model)
        Spacer(minLength: 0)
    }.padding(28).frame(width: 1100, height: 1250, alignment: .topLeading)
        .background(MemoryStyle.background).foregroundStyle(MemoryStyle.text).tint(MemoryStyle.accent)
    let hosting = NSHostingView(rootView: content)
    hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 1250)
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 50_000_000)
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw CheckFailure(description: "could not create offscreen image")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CheckFailure(description: "could not encode offscreen PNG")
    }
    let output = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: output)
    print("RENDER \(output.lastPathComponent)")

    let sessionFixture = try makeFixture("render-session")
    let sessionSummary = CodexSessionSummary(id: "preview", sessionID: "preview", fileURL: URL(fileURLWithPath: "/mock/session.jsonl"),
        title: "模拟搜索功能开发", projectPath: "/mock/project", startedAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200))
    let sessionTranscript = SessionTranscript(summary: sessionSummary, messages: [
        .init(id: "user", kind: .user, text: "继续完善跨会话搜索，支持助手答复与工具结果。"),
        .init(id: "assistant", kind: .assistant, text: "已实现搜索和跳转，测试通过。下一步核对大日志搜索性能。")])
    let sessionModule = try SessionHandoffAIModule(transcript: sessionTranscript)
    sessionFixture.model.prepare(module: sessionModule, subjectLabels: sessionModule.subjectLabels, windowSelectionSeconds: 100)
    guard let sessionPreview = sessionFixture.model.preview else { throw CheckFailure(description: "session render preview missing") }
    let previewView = AnyView(AIAnalysisPreviewView(model: sessionFixture.model, prepared: sessionPreview))
    sessionFixture.model.beginAnalysis(sessionPreview)
    try await waitUntilIdle(sessionFixture.model)
    let editorView = AnyView(SessionHandoffEditor(initialText: SessionHandoff.draft(transcript: sessionTranscript),
        transcript: sessionTranscript, aiModel: sessionFixture.model))
    for (name, rootView, width, height) in [("desktop-ai-handoff-confirmation.png", previewView, CGFloat(700), CGFloat(830)),
                                           ("desktop-ai-handoff-editor.png", editorView, CGFloat(760), CGFloat(720))] {
        let view = NSHostingView(rootView: rootView.background(MemoryStyle.surface).foregroundStyle(MemoryStyle.text).tint(MemoryStyle.accent))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 70_000_000)
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CheckFailure(description: "handoff bitmap") }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw CheckFailure(description: "handoff PNG") }
        try data.write(to: output.deletingLastPathComponent().appendingPathComponent(name))
        window.close()
        print("RENDER \(name)")
    }

    let promptFixture = try makeFixture("render-prompts")
    let promptLibrary = promptFixture.model.promptLibrary
    await promptLibrary.loadIfNeeded()
    let customPrompt = AIPromptTemplate(title: "我的交接标准", text: "先写当前目标和用户最后一次决定，再逐项列出已报告的进展、真实验证记录和待办。\n每项保留来源依据，优先标出验收缺口，结论简洁。", moduleID: "session.handoff")
    let templateSaved = await promptLibrary.save(customPrompt, expected: nil)
    try expect(templateSaved, "render prompt saved")
    let managerView = AnyView(PromptTemplateManager(library: promptLibrary, initial: customPrompt))
    let settingsView = AnyView(PromptTemplateSettingsCard(library: promptLibrary))
    promptFixture.model.choosePrompt(AIPromptTemplate.builtIns[0], for: "fixture")
    promptFixture.model.promptText += "优先给出可执行的检查清单。"
    let promptPreview = try prepare(promptFixture, input: fixtureInput("模拟活动说明"))
    let promptPreviewView = AnyView(AIAnalysisPreviewView(model: promptFixture.model, prepared: promptPreview))
    for (name, rootView, width, height) in [("desktop-prompt-library.png", managerView, CGFloat(760), CGFloat(550)),
                                           ("desktop-prompt-defaults.png", settingsView, CGFloat(760), CGFloat(220)),
                                           ("desktop-prompt-confirmation.png", promptPreviewView, CGFloat(700), CGFloat(800))] {
        let view = NSHostingView(rootView: rootView.background(MemoryStyle.surface).foregroundStyle(MemoryStyle.text).tint(MemoryStyle.accent))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 70_000_000)
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CheckFailure(description: "prompt bitmap") }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw CheckFailure(description: "prompt PNG") }
        try data.write(to: output.deletingLastPathComponent().appendingPathComponent(name))
        window.close()
        print("RENDER \(name)")
    }

    // Render the production setup view without opening an app or fetching models.
    let setup = VStack(alignment: .leading, spacing: 12) {
        Text("添加来源界面预览 · 未配置密钥、未请求服务")
            .font(.system(size: 13, weight: .medium)).padding(.horizontal, 24).padding(.top, 20)
        AIProviderEditor(model: fixture.model, initial: AIProviderPreset.deepSeek.makeConfiguration(),
                         catalog: MockModelCatalog())
    }.background(MemoryStyle.surface).foregroundStyle(MemoryStyle.text).tint(MemoryStyle.accent)
    let setupHosting = NSHostingView(rootView: setup)
    setupHosting.frame = NSRect(x: 0, y: 0, width: 720, height: 720)
    setupHosting.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 50_000_000)
    setupHosting.layoutSubtreeIfNeeded()
    guard let setupBitmap = setupHosting.bitmapImageRepForCachingDisplay(in: setupHosting.bounds) else {
        throw CheckFailure(description: "could not render provider setup")
    }
    setupHosting.cacheDisplay(in: setupHosting.bounds, to: setupBitmap)
    guard let setupPNG = setupBitmap.representation(using: .png, properties: [:]) else {
        throw CheckFailure(description: "could not encode provider setup PNG")
    }
    let setupOutput = output.deletingLastPathComponent().appendingPathComponent("provider-setup-preview.png")
    try setupPNG.write(to: setupOutput)
    print("RENDER \(setupOutput.lastPathComponent)")
}
#endif

@MainActor func checkSessionHandoffIsolationAndPersistence() async throws {
    let fixture = try makeFixture("session-handoff")
    let memoryPreview = try prepare(fixture, input: fixtureInput("memory-result"))
    fixture.model.beginAnalysis(memoryPreview)
    try await waitUntilIdle(fixture.model)
    while fixture.model.reportLibrary.isSaving { try await Task.sleep(nanoseconds: 10_000_000) }
    let memoryRecord = fixture.model.record
    let session = DesktopAIModel(configurationStore: fixture.store, credentials: fixture.credentials,
        coordinator: AIAnalysisCoordinator(client: fixture.client, credentials: fixture.credentials), reportLibrary: fixture.model.reportLibrary, promptLibrary: fixture.model.promptLibrary)
    let summary = CodexSessionSummary(id: "s", sessionID: "s", fileURL: URL(fileURLWithPath: "/fixture/session.jsonl"), title: "Mock session",
                                     startedAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200))
    let transcript = SessionTranscript(summary: summary, messages: [.init(id: "u", kind: .user, text: "继续实现搜索功能")])
    let module = try SessionHandoffAIModule(transcript: transcript, context: "mock-session-context")
    session.prepare(module: module, subjectLabels: module.subjectLabels, windowSelectionSeconds: 100)
    let initialRequests = await fixture.client.captured().count
    try expect(initialRequests == 1, "preparing session excerpts never sends")
    guard let preview = session.preview else { throw CheckFailure(description: "session preview missing") }
    try expect(preview.input == module.input && preview.subjectLabels == module.subjectLabels, "preview freezes text and local references")
    session.beginAnalysis(preview)
    try await waitUntilIdle(session)
    while session.reportLibrary.isSaving { try await Task.sleep(nanoseconds: 10_000_000) }
    try expect(session.analysisError == nil && session.reportSaveError == nil, "session AI and save complete")
    try expect(session.record?.moduleID == SessionHandoffAIModule.moduleID, "session result uses separate module")
    try expect(fixture.model.record == memoryRecord && fixture.model.recordInput?.moduleID == "fixture", "session analysis cannot replace memory result")
    try expect(session.reportLibrary === fixture.model.reportLibrary && session.reportLibrary.reports.count == 2, "modules share one report history")
    let saved = session.reportLibrary.reports.first { $0.input.moduleID == SessionHandoffAIModule.moduleID }
    try expect(saved?.input == module.input && saved?.subjectLabels == module.subjectLabels, "history freezes excerpts and local source mapping")
    let reopened = AIReportLibraryModel(store: session.reportLibrary.store)
    reopened.loadIfNeeded()
    while reopened.isLoading || reopened.isFiltering { try await Task.sleep(nanoseconds: 10_000_000) }
    try expect(reopened.reports.contains { $0.id == saved?.id }, "session report survives reopening without AI calls")
    let requestCount = await fixture.client.captured().count
    try expect(requestCount == 2, "reopening is local-only")
    let previous = session.record
    let failing = try SessionHandoffAIModule(transcript: transcript, context: "fail")
    session.prepare(module: failing, subjectLabels: failing.subjectLabels, windowSelectionSeconds: 100)
    guard let failedPreview = session.preview else { throw CheckFailure(description: "failure preview missing") }
    session.beginAnalysis(failedPreview)
    try await waitUntilIdle(session)
    try expect(session.analysisError != nil && session.record == previous, "failed handoff preserves previous result")
    let slow = try SessionHandoffAIModule(transcript: transcript, context: "slow-old")
    session.prepare(module: slow, subjectLabels: slow.subjectLabels, windowSelectionSeconds: 100)
    guard let slowPreview = session.preview else { throw CheckFailure(description: "cancel preview missing") }
    session.beginAnalysis(slowPreview)
    try await waitForRequests(fixture.client, count: 4)
    session.cancelAnalysis()
    try await Task.sleep(nanoseconds: 450_000_000)
    try expect(session.record == previous && session.reportLibrary.reports.count == 2, "cancelled completion cannot replace or save a handoff")
    print("PASS session frozen preview, result isolation, shared report persistence, failure preservation and cancellation")
}

@MainActor func checkPromptTemplateDefaultsAndFrozenInput() async throws {
    let fixture = try makeFixture("prompt-workflow")
    let library = fixture.model.promptLibrary
    await library.loadIfNeeded()
    let template = AIPromptTemplate(title: "我的复盘", text: "先列出验收缺口")
    let templateSaved = await library.save(template, expected: nil)
    try expect(templateSaved, "save prompt template")
    let defaultSaved = await library.setDefault(template.id, module: "fixture")
    try expect(defaultSaved, "set module prompt default")
    await fixture.model.configurePrompt(for: "fixture")
    try expect(fixture.model.promptText == template.text, "default prompt applied")
    let input = fixtureInput("prompt-result")
    fixture.model.updateWindow(start: input.windowStart, end: input.windowEnd, selectionSeconds: 600)
    fixture.model.activityContext = input.context
    let prepared = try prepare(fixture, input: input)
    let noRequests = await fixture.client.captured().count
    try expect(noRequests == 0, "choosing, saving and previewing templates never calls AI")
    try expect(prepared.input.prompt?.templateID == template.id && prepared.input.prompt?.text == template.text, "preview includes actual prompt and version")
    fixture.model.promptText = "本次临时修改"
    var edited = template; edited.text = "新版模板正文"
    let editedSaved = await library.save(edited, expected: template)
    try expect(editedSaved, "edit saved template")
    fixture.model.beginAnalysis(prepared)
    try await waitUntilIdle(fixture.model)
    while fixture.model.reportLibrary.isSaving { try await Task.sleep(nanoseconds: 10_000_000) }
    let requests = await fixture.client.captured()
    try expect(requests.first?.input.prompt?.text == template.text, "confirmation sends frozen original prompt despite later edits")
    try expect(fixture.model.resultIsStale, "changed prompt marks previous result stale")
    try expect(fixture.model.reportLibrary.reports.first?.input.prompt?.text == template.text, "saved report preserves historical wording")
    let secondPreview = try prepare(fixture, input: input)
    try expect(secondPreview.input.prompt?.text == "本次临时修改" && secondPreview.input.prompt?.isModified == true, "temporary edits have explicit provenance")
    fixture.model.beginAnalysis(secondPreview)
    try await waitUntilIdle(fixture.model)
    while fixture.model.reportLibrary.isSaving { try await Task.sleep(nanoseconds: 10_000_000) }
    let nextRequests = await fixture.client.captured().count
    try expect(nextRequests == 2 && fixture.model.reportLibrary.reports.count == 2, "changed prompt changes cache identity and report snapshot")
    let reopened = DesktopAIModel(configurationStore: fixture.store, credentials: fixture.credentials,
        coordinator: AIAnalysisCoordinator(client: fixture.client, credentials: fixture.credentials))
    await reopened.configurePrompt(for: "fixture")
    try expect(reopened.promptText == edited.text && reopened.promptTemplate?.revision == 2, "reopening uses stored default and latest version")
    let memoryDefaultSaved = await reopened.promptLibrary.setDefault("builtin.memory.inspect", module: "memory")
    try expect(memoryDefaultSaved, "memory default independently saved")
    let session = DesktopAIModel(configurationStore: fixture.store, credentials: fixture.credentials,
        coordinator: AIAnalysisCoordinator(client: fixture.client, credentials: fixture.credentials), promptLibrary: reopened.promptLibrary)
    await session.configurePrompt(for: "memory")
    try expect(session.promptTemplate?.id == "builtin.memory.inspect" && reopened.promptTemplate?.id == template.id,
               "modules share templates while retaining separate selections")
    let finalRequestCount = await fixture.client.captured().count
    try expect(finalRequestCount == 2, "reloading defaults is local only")
    fixture.model.promptText = String(repeating: "x", count: 9_000)
    fixture.model.prepare(module: MutableFixtureModule(input), windowSelectionSeconds: 600)
    try expect(fixture.model.preview == nil && fixture.model.analysisError != nil, "invalid prompt cannot leave an old sendable preview")
    print("PASS prompt persistence/defaults, zero-request reuse, exact frozen wording, temporary edits, cache identity and module isolation")
}

@MainActor func checkPromptLibraryCorruptionAndDefaultUpdates() async throws {
    let fixture = try makeFixture("prompt-library-recovery")
    let library = fixture.model.promptLibrary
    await library.loadIfNeeded()
    await fixture.model.configurePrompt(for: "memory")
    try expect(fixture.model.promptTemplate == nil, "empty library uses module-only guidance")
    let initialDefaultSaved = await library.setDefault("builtin.memory.inspect", module: "memory")
    try expect(initialDefaultSaved, "set a default after initial load")
    await fixture.model.configurePrompt(for: "memory")
    try expect(fixture.model.promptTemplate?.id == "builtin.memory.inspect", "untouched selection follows updated defaults")
    fixture.model.promptText = "我的临时说明"
    let changedDefaultSaved = await library.setDefault("builtin.concise", module: "memory")
    try expect(changedDefaultSaved, "change stored default")
    await fixture.model.configurePrompt(for: "memory")
    try expect(fixture.model.promptText == "我的临时说明", "default changes cannot discard an edited draft")
    let file = fixture.store.url.deletingLastPathComponent().appendingPathComponent("prompt-templates/library.json")
    let good = try Data(contentsOf: file), broken = Data("broken".utf8)
    try broken.write(to: file)
    await library.refresh()
    try expect(library.loadError != nil, "corrupt templates show an error")
    let rejected = await library.setDefault(nil, module: "memory")
    let retainedBytes = try Data(contentsOf: file)
    try expect(!rejected && retainedBytes == broken, "corrupt data cannot be overwritten")
    try good.write(to: file)
    await library.refresh()
    try expect(library.loadError == nil && library.catalog.defaults["memory"] == "builtin.concise", "repaired library can be reloaded")
    print("PASS prompt default refresh, retained dirty draft, corrupt-file preservation and recovery")
}

@MainActor func runChecks() async throws {
    try await checkProviderCRUD()
    try checkCorruptConfiguration()
    try checkModelDiscoveryCredentials()
    try await checkFrozenPreviewAndStaleness()
    try await checkRejectChangedDestination()
    try await checkCredentialSnapshot()
    try await checkCancellationAndFailure()
    try checkSaveFailureRollback()
    try checkConfigurationConflict()
    try await checkOutputBudgetPreview()
    try await checkLengthLimitRecovery()
    try await checkSessionHandoffIsolationAndPersistence()
    try await checkPromptTemplateDefaultsAndFrozenInput()
    try await checkPromptLibraryCorruptionAndDefaultUpdates()
    print("DESKTOP AI CHECKS PASSED: 14 workflows, \(assertionCount) assertions; mock providers and credentials only")
    #if RENDER_AI
    if let output = ProcessInfo.processInfo.environment["GPT_DESKTOP_AI_RENDER_PATH"] {
        try await renderFixture(to: output)
    }
    #endif
}

Task { @MainActor in
    do { try await runChecks(); exit(0) }
    catch { fputs("DESKTOP AI CHECK FAILED: \(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
'''


def release_inputs(project: Path) -> tuple[Path, list[Path]]:
    release = project / ".build" / "release"
    modules = release / "Modules"
    objects = []
    missing = []
    stale = []
    for target in ["GPTAnalysisKit", "GPTMemoryCore", "GPTSessionKit"]:
        if not (modules / f"{target}.swiftmodule").is_file():
            missing.append(f"{target}.swiftmodule")
        for source in sorted((project / "Sources" / target).glob("*.swift")):
            artifact = release / f"{target}.build" / f"{source.name}.o"
            if not artifact.is_file():
                missing.append(artifact.name)
            elif artifact.stat().st_mtime_ns < source.stat().st_mtime_ns:
                stale.append(source.name)
            objects.append(artifact)
    native = release / "CNative.build" / "native.c.o"
    native_source = project / "Sources" / "CNative" / "native.c"
    if not native.is_file():
        missing.append(native.name)
    elif native.stat().st_mtime_ns < native_source.stat().st_mtime_ns:
        stale.append(native_source.name)
    objects.append(native)
    if not (release / "CNative.build" / "module.modulemap").is_file():
        missing.append("CNative module.modulemap")
    if missing or stale:
        detail = "缺少产物：" + ", ".join(missing) if missing else "Release 产物早于源码：" + ", ".join(stale)
        raise RuntimeError(f"{detail}。请先运行 swift build --configuration release；本脚本不会自行构建项目。")
    return release, objects


def main() -> int:
    parser = argparse.ArgumentParser(description="使用已构建 Release 产物验证真实桌面 AI 状态机，凭据和模型全部使用 mock。")
    parser.add_argument("--render", nargs="?", const="reports/desktop-ai-preview.png", metavar="PNG",
                        help="可选：离屏渲染模拟结果，省略路径时输出 reports/desktop-ai-preview.png")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    release, objects = release_inputs(project)
    output = Path(args.render).expanduser().resolve() if args.render else None
    with tempfile.TemporaryDirectory(prefix="gpt-desktop-ai-checks-") as temporary:
        directory = Path(temporary)
        swift_main = directory / "main.swift"
        swift_main.write_text(SWIFT_CHECKS, encoding="utf-8")
        executable = directory / "desktop-ai-checks"
        desktop = project / "Sources" / "GPTMemoryDesktop"
        sources = [desktop / "DesktopAIModel.swift", desktop / "PromptTemplateLibraryModel.swift", desktop / "AIReportLibraryModel.swift"]
        if output:
            sources += [desktop / name for name in ["DesktopModel.swift", "Views.swift", "DesktopSpeedModel.swift", "DesktopSpeedViews.swift", "KnowledgeDesktopModel.swift", "KnowledgeViews.swift", "KnowledgeExtractionViews.swift", "MemoryProcessActionsModel.swift", "MemoryProcessActionViews.swift", "AIViews.swift", "AIReportViews.swift", "AIProviderEditorModel.swift", "Style.swift", "SessionDesktopModel.swift", "SessionManagementModel.swift", "SessionManagementViews.swift", "SessionViews.swift", "SessionProjectViews.swift", "SessionHandoffAIViews.swift", "PromptTemplateViews.swift"]]
        architecture = platform.machine()
        if architecture not in {"arm64", "x86_64"}:
            raise RuntimeError(f"不支持的 macOS 架构：{architecture}")
        command = ["swiftc", "-swift-version", "5", "-target", f"{architecture}-apple-macosx14.0",
                   "-module-cache-path", str(directory / "module-cache"), "-I", str(release / "Modules"),
                   "-I", str(release / "CNative.build"), "-o", str(executable)]
        if output:
            command += ["-D", "RENDER_AI"]
        command += [str(source) for source in sources] + [str(swift_main)] + [str(obj) for obj in objects]
        command += ["-lproc", "-lsqlite3"]
        print("编译桌面 AI mock harness（使用现有 Release 产物）", flush=True)
        subprocess.run(command, cwd=project, check=True, timeout=60)
        environment = os.environ.copy()
        environment["GPT_DESKTOP_AI_CHECK_DIR"] = str(directory / "fixtures")
        if output:
            environment["GPT_DESKTOP_AI_RENDER_PATH"] = str(output)
        subprocess.run([str(executable)], cwd=project, env=environment, check=True, timeout=20)
        if output:
            print(f"模拟桌面预览已生成：{output.name}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"桌面 AI 检查未通过：{error}", file=sys.stderr)
        raise SystemExit(1)
