#!/usr/bin/env python3
"""Check the production provider editor with mocks and existing Release objects.

No real network, credentials, persisted settings, application launch or default
history writes. A Release build is a prerequisite, never performed here.
"""
from pathlib import Path
import os
import platform
import subprocess
import sys
import tempfile


SWIFT_CHECKS = r'''
import Foundation
import Darwin
import GPTAnalysisKit

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor var assertions = 0
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    assertions += 1
    if !condition() { throw CheckFailure(description: message) }
}

struct CatalogCall {
    let configuration: AIProviderConfiguration
    let key: String?
}

actor MockCatalog: AIModelCatalogClient {
    private var requests: [CatalogCall] = []
    private var pending: [Int: CheckedContinuation<[String], Error>] = [:]
    func captured() -> [CatalogCall] { requests }
    func models(configuration: AIProviderConfiguration, apiKey: String?) async throws -> [String] {
        let index = requests.count
        requests.append(CatalogCall(configuration: configuration, key: apiKey))
        // Deliberately ignore cancellation, matching an already accepted request.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, with models: [String]) { pending.removeValue(forKey: index)?.resume(returning: models) }
    func fail(_ index: Int, with error: Error) { pending.removeValue(forKey: index)?.resume(throwing: error) }
}

struct RawPrivateError: Error, LocalizedError {
    var errorDescription: String? { "raw-secret-body-that-must-never-be-shown" }
}

@MainActor final class CredentialProbe {
    let original: AIProviderConfiguration
    var storedKey: String? = "mock-stored-key"
    var calls: [(AIProviderConfiguration, String, Bool)] = []
    init(original: AIProviderConfiguration) { self.original = original }
    func resolve(_ configuration: AIProviderConfiguration, _ draftKey: String, _ clearKey: Bool) throws -> String? {
        calls.append((configuration, draftKey, clearKey))
        let key: String?
        if clearKey { key = nil }
        else if !draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if configuration.kind == original.kind && configuration.baseURL == original.baseURL {
            key = storedKey
        } else { key = nil }
        if configuration.requiresAPIKey && key == nil { throw AIAnalysisError.missingCredential }
        return key
    }
}

@MainActor struct Fixture {
    let model: AIProviderEditorModel
    let catalog: MockCatalog
    let credentials: CredentialProbe
    let original: AIProviderConfiguration
}

@MainActor func fixture(model: String = "manual-model", local: Bool = false) -> Fixture {
    var provider = (local ? AIProviderPreset.ollama : AIProviderPreset.openAI).makeConfiguration(id: UUID())
    provider.model = model
    provider.name = "Saved provider name"
    provider.timeoutSeconds = 87
    provider.maxOutputTokens = 3210
    provider.jsonMode = false
    provider.revision = 9
    let catalog = MockCatalog()
    let probe = CredentialProbe(original: provider)
    let editor = AIProviderEditorModel(configuration: provider, catalog: catalog) { configuration, key, clear in
        try probe.resolve(configuration, key, clear)
    }
    return Fixture(model: editor, catalog: catalog, credentials: probe, original: provider)
}

@MainActor func waitForRequests(_ catalog: MockCatalog, count: Int) async throws {
    let deadline = Date().addingTimeInterval(3)
    while await catalog.captured().count < count {
        if Date() >= deadline { throw CheckFailure(description: "model request did not start") }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

@MainActor func waitUntilIdle(_ model: AIProviderEditorModel) async throws {
    let deadline = Date().addingTimeInterval(3)
    while model.isLoading {
        if Date() >= deadline { throw CheckFailure(description: "model request did not finish") }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

@MainActor func drainLateResponse() async throws {
    // All mock completions are immediate; give their MainActor tasks time to run.
    try await Task.sleep(nanoseconds: 20_000_000)
}

@MainActor func checkPresetsAndDraftIsolation() async throws {
    let f = fixture()
    try expect(f.model.selectedPreset == .openAI, "recognize saved official provider")
    try expect(f.credentials.calls.isEmpty, "opening editor reads no credentials")
    let openedCalls = await f.catalog.captured()
    try expect(openedCalls.isEmpty, "opening editor sends zero requests")
    f.model.key = "new-draft-key"
    f.model.clearKey = true
    f.model.selectPreset(.deepSeek)
    let expected = AIProviderPreset.deepSeek.makeConfiguration(id: f.original.id)
    try expect(f.model.configuration.id == f.original.id, "preset retains saved provider identity")
    try expect(f.model.configuration.name == expected.name && f.model.configuration.kind == expected.kind,
               "preset fills provider name and protocol")
    try expect(f.model.configuration.baseURL == expected.baseURL && f.model.configuration.model == expected.model,
               "preset fills endpoint and default model")
    try expect(f.model.configuration.timeoutSeconds == 87 && f.model.configuration.maxOutputTokens == 3210,
               "preset retains advanced numeric settings")
    try expect(!f.model.configuration.jsonMode && f.model.configuration.revision == 9,
               "preset retains structured output and revision")
    try expect(f.model.key.isEmpty && !f.model.clearKey, "secret draft never moves to another preset")
    f.model.selectPreset(.ollama)
    try expect(f.model.configuration.model.isEmpty && f.model.configuration.kind == .ollama,
               "Ollama starts with empty model for user selection")
    f.model.selectPreset(.custom)
    try expect(f.model.configuration.name.isEmpty && f.model.configuration.baseURL.isEmpty,
               "custom source permits explicitly filled metadata")
    try expect(f.original.name == "Saved provider name" && f.original.model == "manual-model",
               "draft changes do not mutate saved configuration")
    try expect(f.credentials.storedKey == "mock-stored-key" && f.credentials.calls.isEmpty,
               "draft edits do not read or write saved secrets")
    let calls = await f.catalog.captured()
    try expect(calls.isEmpty, "preset changes send zero requests")
    print("PASS presets, advanced settings, isolated draft and zero-request editing")
}

@MainActor func checkFrozenCredentialAndManualModel() async throws {
    let f = fixture()
    f.model.fetchModels()
    try expect(f.credentials.calls.count == 1, "manual fetch resolves credential once")
    try expect(f.credentials.calls[0].1.isEmpty && !f.credentials.calls[0].2, "empty draft key delegates saved-key lookup")
    f.credentials.storedKey = "changed-after-fetch"
    try await waitForRequests(f.catalog, count: 1)
    let captured = await f.catalog.captured()
    try expect(captured[0].configuration == f.original && captured[0].key == "mock-stored-key",
               "request binds the configuration and credential present at click")
    f.model.configuration.model = "typed-during-fetch"
    try expect(f.model.isLoading, "manual model edit keeps the catalog request")
    await f.catalog.finish(0, with: ["alpha", "beta"])
    try await waitUntilIdle(f.model)
    try expect(f.model.models == ["alpha", "beta"], "successful response exposes selectable models")
    try expect(f.model.configuration.model == "typed-during-fetch", "response preserves the manually typed model")
    f.model.configuration.model = "another-manual-model"
    try expect(f.model.models == ["alpha", "beta"], "manual model changes retain selectable catalog")
    f.model.configuration.name = "renamed draft"
    f.model.configuration.maxOutputTokens = 4096
    try expect(f.model.models.count == 2, "non-catalog metadata changes retain models")
    print("PASS frozen credential, manual model preservation and selectable catalog")
}

@MainActor func checkSingleAndEmptyCatalog() async throws {
    let single = fixture(model: "", local: true)
    single.model.fetchModels()
    try await waitForRequests(single.catalog, count: 1)
    await single.catalog.finish(0, with: ["only-model"])
    try await waitUntilIdle(single.model)
    try expect(single.model.configuration.model == "only-model", "sole model fills an untouched empty field")
    let typed = fixture(model: "", local: true)
    typed.model.fetchModels()
    try await waitForRequests(typed.catalog, count: 1)
    typed.model.configuration.model = "my-model"
    await typed.catalog.finish(0, with: ["only-model"])
    try await waitUntilIdle(typed.model)
    try expect(typed.model.configuration.model == "my-model", "sole result does not overwrite a concurrent manual model")
    let many = fixture(model: "", local: true)
    many.model.fetchModels()
    try await waitForRequests(many.catalog, count: 1)
    await many.catalog.finish(0, with: ["alpha", "beta"])
    try await waitUntilIdle(many.model)
    try expect(many.model.configuration.model.isEmpty, "multiple models require explicit choice")
    many.model.fetchModels()
    try await waitForRequests(many.catalog, count: 2)
    await many.catalog.finish(1, with: [])
    try await waitUntilIdle(many.model)
    try expect(many.model.models.isEmpty && many.model.modelError == nil, "empty valid catalog is not a network failure")
    try expect(many.model.statusMessage?.contains("手动填写") == true, "empty catalog directs manual model entry")
    print("PASS single, multiple, manually typed and empty model catalogs")
}

@MainActor func checkDraftInvalidation() async throws {
    let notStarted = fixture()
    notStarted.model.fetchModels()
    notStarted.model.configuration.baseURL = "https://changed-before-start.invalid/v1"
    try await drainLateResponse()
    let unstartedCalls = await notStarted.catalog.captured()
    try expect(unstartedCalls.isEmpty, "draft invalidation before the task starts sends zero requests")
    for change in ["endpoint", "kind", "timeout", "key", "clear"] {
        let f = fixture()
        f.model.fetchModels()
        try await waitForRequests(f.catalog, count: 1)
        switch change {
        case "endpoint": f.model.configuration.baseURL = "https://changed.invalid/v1"
        case "kind": f.model.configuration.kind = .openAICompatible
        case "timeout": f.model.configuration.timeoutSeconds = 30
        case "key": f.model.key = "replacement-key"
        default: f.model.clearKey = true
        }
        try expect(!f.model.isLoading && f.model.models.isEmpty, "\(change) cancels loading and clears catalog")
        try expect(f.model.configuration.model == "manual-model", "\(change) retains manually entered model")
        await f.catalog.finish(0, with: ["wrong-old-model"])
        try await drainLateResponse()
        try expect(f.model.models.isEmpty && f.model.statusMessage == nil && f.model.modelError == nil,
                   "\(change) rejects late response from previous configuration")
    }
    let success = fixture()
    success.model.fetchModels()
    try await waitForRequests(success.catalog, count: 1)
    await success.catalog.finish(0, with: ["before-change"])
    try await waitUntilIdle(success.model)
    success.model.key = "new-key"
    try expect(success.model.models.isEmpty && success.model.statusMessage == nil,
               "credential edit also clears a completed catalog")
    print("PASS endpoint, protocol, timeout and credential invalidation, late response protection")
}

@MainActor func checkCancelAndReplacement() async throws {
    let f = fixture()
    f.model.fetchModels()
    try await waitForRequests(f.catalog, count: 1)
    f.model.cancelFetch()
    try expect(!f.model.isLoading && f.model.statusMessage?.contains("取消") == true, "explicit cancellation ends loading")
    await f.catalog.finish(0, with: ["cancelled-model"])
    try await drainLateResponse()
    try expect(f.model.models.isEmpty && f.model.statusMessage?.contains("取消") == true,
               "cancelled request cannot replace cancellation state")
    f.model.fetchModels()
    try await waitForRequests(f.catalog, count: 2)
    f.model.fetchModels()
    try await waitForRequests(f.catalog, count: 3)
    await f.catalog.finish(2, with: ["latest-model"])
    try await waitUntilIdle(f.model)
    await f.catalog.finish(1, with: ["replaced-model"])
    try await drainLateResponse()
    try expect(f.model.models == ["latest-model"] && !f.model.isLoading, "replacement request owns the result after reversed completion")
    try expect(f.credentials.calls.count == 3, "each explicit fetch resolves current credential separately")
    print("PASS cancellation, repeated fetches and reversed completion ownership")
}

@MainActor func checkPresetCancelsCatalog() async throws {
    for destinationChange in ["endpoint", "kind"] {
        let draft = fixture()
        draft.model.key = "typed-for-original-destination"
        if destinationChange == "endpoint" {
            draft.model.configuration.baseURL = "https://new-destination.invalid/v1"
        } else {
            draft.model.configuration.kind = .openAICompatible
        }
        try expect(draft.model.key.isEmpty, "manual \(destinationChange) edit clears original draft secret")
        draft.model.fetchModels()
        let before = await draft.catalog.captured()
        try expect(before.isEmpty && draft.model.modelError?.contains("API Key") == true,
                   "manual \(destinationChange) change cannot send the original draft credential")
        draft.model.key = "typed-for-new-destination"
        draft.model.fetchModels()
        try await waitForRequests(draft.catalog, count: 1)
        let after = await draft.catalog.captured()
        try expect(after[0].key == "typed-for-new-destination",
                   "manual \(destinationChange) edit accepts newly supplied credential")
        try expect(after[0].configuration == draft.model.configuration,
                   "manual \(destinationChange) fetch uses the updated destination")
        await draft.catalog.finish(0, with: ["new-destination-model"])
        try await waitUntilIdle(draft.model)
    }
    let formatting = fixture()
    formatting.model.key = "same-service-key"
    formatting.model.configuration.name = "renamed source"
    formatting.model.configuration.model = "typed-model"
    try expect(formatting.model.key == "same-service-key", "name and model edits retain draft secret")
    formatting.model.fetchModels()
    try await waitForRequests(formatting.catalog, count: 1)
    await formatting.catalog.finish(0, with: ["listed-model"])
    try await waitUntilIdle(formatting.model)
    formatting.model.configuration.baseURL = "  \(formatting.original.baseURL)/  "
    try expect(formatting.model.key == "same-service-key", "endpoint whitespace and trailing slash retain same-service draft secret")
    try expect(formatting.model.models.isEmpty, "format-only endpoint edits still invalidate the model catalog")
    let f = fixture()
    f.model.key = "typed-for-openai"
    f.model.fetchModels()
    try await waitForRequests(f.catalog, count: 1)
    f.model.selectPreset(.deepSeek)
    try expect(!f.model.isLoading && f.model.key.isEmpty, "preset change cancels old service and clears its draft credential")
    await f.catalog.finish(0, with: ["old-service-model"])
    try await drainLateResponse()
    try expect(f.model.models.isEmpty, "old service models never populate new preset")
    f.model.fetchModels()
    try expect(f.model.modelError?.contains("API Key") == true && !f.model.isLoading,
               "saved original secret is not reused for new remote destination")
    let calls = await f.catalog.captured()
    try expect(calls.count == 1, "missing new credential produces no catalog request")
    f.model.key = "new-service-key"
    f.model.fetchModels()
    try await waitForRequests(f.catalog, count: 2)
    let current = await f.catalog.captured()
    try expect(current[1].configuration.kind == .openAICompatible && current[1].key == "new-service-key",
               "new destination receives only newly supplied credential")
    await f.catalog.finish(1, with: ["deepseek-model"])
    try await waitUntilIdle(f.model)
    print("PASS preset/manual destination changes, draft secret clearing and format-only edits")
}

@MainActor func checkFailuresAndRecovery() async throws {
    let f = fixture()
    f.model.fetchModels()
    try await waitForRequests(f.catalog, count: 1)
    await f.catalog.fail(0, with: AIAnalysisError.httpStatus(401))
    try await waitUntilIdle(f.model)
    try expect(f.model.modelError?.contains("401") == true && f.model.models.isEmpty,
               "typed HTTP error exposes status without response data")
    try expect(f.model.configuration.model == "manual-model", "failure retains manually entered model")
    f.model.fetchModels()
    try expect(f.model.modelError == nil && f.model.isLoading, "manual retry clears previous failure")
    try await waitForRequests(f.catalog, count: 2)
    await f.catalog.fail(1, with: RawPrivateError())
    try await waitUntilIdle(f.model)
    try expect(f.model.modelError != nil && f.model.modelError?.contains("raw-secret") == false,
               "untrusted errors never display raw private details")
    f.model.fetchModels()
    try await waitForRequests(f.catalog, count: 3)
    await f.catalog.finish(2, with: ["recovered-model"])
    try await waitUntilIdle(f.model)
    try expect(f.model.models == ["recovered-model"] && f.model.modelError == nil, "successful retry recovers without saving")
    f.model.clearKey = true
    f.model.fetchModels()
    try expect(f.model.modelError?.contains("API Key") == true, "clear saved credential is applied to model lookup")
    let calls = await f.catalog.captured()
    try expect(calls.count == 3, "credential resolution failure sends zero requests")
    try expect(f.credentials.storedKey == "mock-stored-key", "clear draft never deletes saved credential")
    print("PASS safe failures, manual recovery and draft clear-key semantics")
}

@MainActor func runChecks() async throws {
    try await checkPresetsAndDraftIsolation()
    try await checkFrozenCredentialAndManualModel()
    try await checkSingleAndEmptyCatalog()
    try await checkDraftInvalidation()
    try await checkCancelAndReplacement()
    try await checkPresetCancelsCatalog()
    try await checkFailuresAndRecovery()
    print("PROVIDER EDITOR CHECKS PASSED: 7 workflows, \(assertions) assertions; mock catalog and credentials only")
}

Task { @MainActor in
    do { try await runChecks(); exit(0) }
    catch { fputs("PROVIDER EDITOR CHECK FAILED: \(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
'''


def release_inputs(project: Path) -> tuple[Path, list[Path]]:
    release = project / ".build" / "release"
    objects = []
    missing = []
    stale = []
    if not (release / "Modules" / "GPTAnalysisKit.swiftmodule").is_file():
        missing.append("GPTAnalysisKit.swiftmodule")
    for source in sorted((project / "Sources" / "GPTAnalysisKit").glob("*.swift")):
        artifact = release / "GPTAnalysisKit.build" / f"{source.name}.o"
        if not artifact.is_file():
            missing.append(artifact.name)
        elif artifact.stat().st_mtime_ns < source.stat().st_mtime_ns:
            stale.append(source.name)
        objects.append(artifact)
    if missing or stale:
        detail = "缺少产物：" + ", ".join(missing) if missing else "Release 产物早于源码：" + ", ".join(stale)
        raise RuntimeError(f"{detail}。请先构建 Release；本脚本不会自行构建项目。")
    return release, objects


def main() -> int:
    project = Path(__file__).resolve().parents[1]
    release, objects = release_inputs(project)
    architecture = platform.machine()
    if architecture not in {"arm64", "x86_64"}:
        raise RuntimeError(f"不支持的 macOS 架构：{architecture}")
    with tempfile.TemporaryDirectory(prefix="gpt-provider-editor-checks-") as temporary:
        directory = Path(temporary)
        swift_main = directory / "main.swift"
        swift_main.write_text(SWIFT_CHECKS, encoding="utf-8")
        executable = directory / "provider-editor-checks"
        command = ["swiftc", "-swift-version", "5", "-target", f"{architecture}-apple-macosx14.0",
                   "-module-cache-path", str(directory / "module-cache"), "-I", str(release / "Modules"),
                   "-o", str(executable), str(project / "Sources" / "GPTMemoryDesktop" / "AIProviderEditorModel.swift"),
                   str(swift_main)] + [str(obj) for obj in objects]
        print("编译来源编辑器 mock harness（使用现有 Release 产物）", flush=True)
        subprocess.run(command, cwd=project, check=True, timeout=60)
        subprocess.run([str(executable)], cwd=project, env=os.environ.copy(), check=True, timeout=20)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"来源编辑器检查未通过：{error}", file=sys.stderr)
        raise SystemExit(1)
