#!/usr/bin/env python3
"""Validate the production session desktop model and optionally render its view.

Only temporary fixtures and injected local loaders are used. This never reads the
user's Codex directory, opens the app, accesses credentials, or sends requests.
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
import GPTSessionKit
#if RENDER_SESSIONS
import AppKit
import SwiftUI
#endif

struct CheckFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor var assertionCount = 0
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    assertionCount += 1
    if !condition() { throw CheckFailure(message: message) }
}

struct CatalogStep {
    let delay: TimeInterval
    let result: Result<SessionCatalog, Error>
}

struct TranscriptStep {
    let delay: TimeInterval
    let result: Result<SessionTranscript, Error>
}

final class FixtureSource: @unchecked Sendable {
    private let lock = NSLock()
    private var catalogs: [CatalogStep]
    private var transcripts: [String: [TranscriptStep]]
    private var catalogCount = 0
    private var transcriptIDs: [String] = []
    private var cancelledCatalogCount = 0
    private var cancelledTranscriptCount = 0
    init(catalogs: [CatalogStep], transcripts: [String: [TranscriptStep]] = [:]) {
        self.catalogs = catalogs; self.transcripts = transcripts
    }
    var calls: (catalog: Int, transcripts: [String], cancelledCatalogs: Int, cancelledTranscripts: Int) {
        lock.lock(); defer { lock.unlock() }
        return (catalogCount, transcriptIDs, cancelledCatalogCount, cancelledTranscriptCount)
    }
    private func wait(_ delay: TimeInterval, catalog: Bool) throws {
        let deadline = Date().addingTimeInterval(delay)
        do {
            while Date() < deadline {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: min(0.005, deadline.timeIntervalSinceNow))
            }
            try Task.checkCancellation()
        } catch {
            lock.lock()
            if catalog { cancelledCatalogCount += 1 } else { cancelledTranscriptCount += 1 }
            lock.unlock()
            throw error
        }
    }
    func catalog() throws -> SessionCatalog {
        lock.lock()
        let index = min(catalogCount, max(0, catalogs.count - 1))
        catalogCount += 1
        let step = catalogs.isEmpty ? CatalogStep(delay: 0, result: .success(.init())) : catalogs[index]
        lock.unlock()
        try wait(step.delay, catalog: true)
        return try step.result.get()
    }
    func transcript(_ summary: CodexSessionSummary) throws -> SessionTranscript {
        lock.lock()
        let index = transcriptIDs.filter { $0 == summary.id }.count
        transcriptIDs.append(summary.id)
        let steps = transcripts[summary.id] ?? []
        let step = steps.isEmpty ? TranscriptStep(delay: 0, result: .success(.init(summary: summary)))
            : steps[min(index, steps.count - 1)]
        lock.unlock()
        try wait(step.delay, catalog: false)
        return try step.result.get()
    }
}

func fixtureRoot(_ name: String) throws -> URL {
    guard let directory = ProcessInfo.processInfo.environment["GPT_DESKTOP_SESSION_CHECK_DIR"] else {
        throw CheckFailure(message: "missing isolated fixture directory")
    }
    return URL(fileURLWithPath: directory).appendingPathComponent(name, isDirectory: true)
}

func summary(_ id: String, project: String = "/workspace/mock", archived: Bool = false,
             tokens: CodexTokenUsage = .init(), metadataSessionID: String? = nil) -> CodexSessionSummary {
    CodexSessionSummary(id: id, sessionID: "session-\(id)",
        fileURL: URL(fileURLWithPath: "/fixture/sessions/\(id).jsonl"),
        title: "模拟会话 \(id)", projectPath: project,
        startedAt: Date(timeIntervalSince1970: 1_791_792_000),
        updatedAt: Date(timeIntervalSince1970: 1_791_792_060), model: "mock-codex",
        messageCount: 2, toolCallCount: 1, tokens: tokens, isArchived: archived,
        searchText: "模拟用户日志\nsecond prompt \(id)", metadataSessionID: metadataSessionID)
}

@MainActor func model(_ source: FixtureSource, name: String) throws -> SessionDesktopModel {
    SessionDesktopModel(rootURL: try fixtureRoot(name),
        catalogLoader: { try source.catalog() }, transcriptLoader: { try source.transcript($0) })
}

@MainActor func waitFor(_ predicate: () -> Bool, _ message: String) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !predicate() {
        if Date() >= deadline { throw CheckFailure(message: message) }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor func load(_ model: SessionDesktopModel) async throws {
    model.loadIfNeeded()
    try await waitFor({ !model.isLoading && !model.isFiltering && model.management.hasLoaded
        && !model.management.isLoading }, "catalog loader timed out")
}

@MainActor func filtered(_ model: SessionDesktopModel) async throws {
    try await waitFor({ !model.isFiltering }, "background filter timed out")
}

/// Inspect task ownership without exposing diagnostics in the shipping model.
/// Completed Task results must not outlive the published catalog/detail values.
@MainActor func retainedTaskHandles(_ model: SessionDesktopModel) -> [String] {
    let names: Set<String> = ["catalogTask", "catalogOperation", "transcriptTask", "transcriptOperation",
                              "filterTask", "filterOperation"]
    return Mirror(reflecting: model).children.compactMap { child in
        guard let name = child.label, names.contains(name) else { return nil }
        return Mirror(reflecting: child.value).children.isEmpty ? nil : name
    }
}

@MainActor func checkTaskResultOwnership() async throws {
    let item = summary("task-ownership")
    let messages = [SessionMessage(id: "owned-prompt", kind: .user, text: "保留可见正文"),
                    SessionMessage(id: "owned-result", kind: .toolResult,
                                   text: String(repeating: "离线模拟工具内容", count: 1_000))]
    let failure = CheckFailure(message: "模拟读取失败")
    let source = FixtureSource(catalogs: [
        .init(delay: 0, result: .success(.init(sessions: [item]))),
        .init(delay: 0, result: .failure(failure))
    ], transcripts: [item.id: [
        .init(delay: 0, result: .success(.init(summary: item, messages: messages))),
        .init(delay: 0, result: .failure(failure)),
        .init(delay: 0.5, result: .success(.init(summary: item, messages: messages)))
    ]])
    let state = try model(source, name: "task-ownership")
    try await load(state)
    try expect(retainedTaskHandles(state).isEmpty, "completed catalog/filter task results are released")
    state.select(item.id)
    try await waitFor({ !state.isLoadingTranscript && !state.isFiltering }, "ownership transcript timed out")
    try expect(state.transcript?.messages == messages, "releasing task handles preserves published messages")
    try expect(state.transcriptIndex?.index(of: "owned-result") == 1, "published transcript index remains usable")
    try expect(retainedTaskHandles(state).isEmpty, "completed transcript/filter task results are released")
    state.select(item.id, forceReload: true)
    try await waitFor({ !state.isLoadingTranscript }, "ownership failure timed out")
    try expect(state.transcriptErrorMessage?.contains(failure.message) == true, "failed detail still reports its error")
    try expect(retainedTaskHandles(state).isEmpty, "failed transcript task result is released")
    state.select(item.id, forceReload: true)
    try await waitFor({ source.calls.transcripts.count == 3 }, "pending detail did not start")
    state.clearSelection()
    try expect(state.transcript == nil && state.transcriptIndex == nil, "clearing selection releases visible detail")
    try expect(retainedTaskHandles(state).isEmpty, "clearing selection drops cancelled task handles immediately")
    try await waitFor({ source.calls.cancelledTranscripts == 1 }, "cancelled detail read did not stop")
    state.refresh()
    try await waitFor({ !state.isLoading }, "ownership catalog failure timed out")
    try expect(state.errorMessage?.contains(failure.message) == true && state.sessions == [item],
               "failed refresh preserves the existing catalog")
    try expect(retainedTaskHandles(state).isEmpty, "failed catalog task result is released")
    print("PASS completed/failed/cancelled task result ownership, retained visible content and cooperative cancellation")
}

@MainActor func checkLazyLoadAndFiltering() async throws {
    let a = summary("a", tokens: .init(input: 10, cachedInput: 2, output: 4, reasoningOutput: 1))
    let b = summary("b", project: "/workspace/other")
    let archived = summary("archive", archived: true, tokens: .init(input: 20, output: 6, total: 26))
    let source = FixtureSource(catalogs: [.init(delay: 0.03,
        result: .success(.init(sessions: [a, b, archived], warnings: ["模拟索引提示"])))])
    let state = try model(source, name: "filter")
    try expect(source.calls.catalog == 0 && !state.hasLoaded, "initialization never scans")
    state.loadIfNeeded(); state.loadIfNeeded()
    try await waitFor({ !state.isLoading && !state.isFiltering }, "lazy scan timed out")
    try expect(source.calls.catalog == 1 && state.hasLoaded, "first appearance scans exactly once")
    try expect(state.sessions.count == 3 && state.filteredSessions.count == 2, "archives hidden by default")
    try expect(state.catalogWarnings == ["模拟索引提示"], "catalog warnings preserved")
    let total = state.total(\.effectiveTotal)
    try expect(total.value == 14 && total.missingSessionCount == 1, "missing counters remain unknown")
    try expect(total.displayValue.hasPrefix("≥") && total.detail.contains("1"), "partial total labeled as known lower bound")
    state.includeArchived = true
    try await filtered(state)
    try expect(state.filteredSessions.count == 3 && state.total(\.effectiveTotal).value == 40, "archive toggle updates recorded totals")
    state.includeArchived = false
    state.query = "second prompt session-a"
    try await filtered(state)
    try expect(state.filteredSessions.map(\.id) == ["a"], "multiple search terms match user prompts")
    state.select("a")
    try await waitFor({ !state.isLoadingTranscript }, "transcript load timed out")
    try expect(state.transcript?.summary.id == "a", "selection loads the matching content")
    state.query = "SESSION-A"
    try await filtered(state)
    try expect(state.selectedSessionID == "a", "case-insensitive session id search retains visible selection")
    state.selectedProject = "/workspace/other"
    try await filtered(state)
    try expect(state.selectedSessionID == nil && state.transcript == nil, "incompatible project filter clears detail")
    state.query = ""; state.selectedProject = nil; state.includeArchived = false
    try await filtered(state)
    try expect(state.projectPaths == ["/workspace/mock", "/workspace/other"], "project options deduplicated and stable")
    state.select("archive")
    try expect(state.selectedSessionID == nil, "hidden archived session cannot be selected")
    state.loadIfNeeded()
    try expect(source.calls.catalog == 1, "returning to page does not rescan automatically")
    print("PASS lazy loading, local filters, archive behavior and unknown usage")
}

@MainActor func checkRefreshGenerations() async throws {
    let old = summary("old"), latest = summary("latest")
    let source = FixtureSource(catalogs: [
        .init(delay: 0.25, result: .success(.init(sessions: [old]))),
        .init(delay: 0.01, result: .success(.init(sessions: [latest])))])
    let state = try model(source, name: "catalog-generation")
    state.refresh()
    try await waitFor({ source.calls.catalog == 1 }, "first catalog did not start")
    state.refresh()
    try await waitFor({ !state.isLoading && !state.isFiltering }, "latest catalog timed out")
    try expect(state.sessions.map(\.id) == ["latest"], "new refresh can finish before old refresh")
    try await Task.sleep(nanoseconds: 350_000_000)
    try expect(state.sessions.map(\.id) == ["latest"] && !state.isLoading, "late old scan cannot overwrite current catalog")
    try expect(source.calls.cancelledCatalogs == 1, "refresh cancellation reaches the detached catalog loader")
    print("PASS overlapping catalog refresh generation guards")
}

@MainActor func checkTranscriptGenerations() async throws {
    let a = summary("slow"), b = summary("fast")
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: [a, b])))],
        transcripts: ["slow": [.init(delay: 0.25, result: .success(.init(summary: a))),
                               .init(delay: 0.6, result: .success(.init(summary: a)))],
                      "fast": [.init(delay: 0.01, result: .success(.init(summary: b)))]] )
    let state = try model(source, name: "transcript-generation")
    try await load(state)
    state.select("slow")
    try await waitFor({ source.calls.transcripts.contains("slow") }, "old transcript did not start")
    state.select("fast")
    try await waitFor({ !state.isLoadingTranscript }, "latest transcript timed out")
    try expect(state.transcript?.summary.id == "fast", "new selected session gets its own transcript")
    try await Task.sleep(nanoseconds: 350_000_000)
    try expect(state.selectedSessionID == "fast" && state.transcript?.summary.id == "fast", "late old transcript cannot overwrite selection")
    try expect(source.calls.cancelledTranscripts == 1, "new selection cancels actual detached detail work")
    state.select("slow")
    try await waitFor({ source.calls.transcripts.count == 3 }, "second old transcript did not start")
    state.query = "impossible-filter"
    try await filtered(state)
    try expect(state.selectedSessionID == nil && !state.isLoadingTranscript && state.transcript == nil, "settled search clears excluded pending selection")
    try await Task.sleep(nanoseconds: 350_000_000)
    try expect(state.transcript == nil && state.transcriptErrorMessage == nil, "hidden pending load cannot reappear")
    try expect(source.calls.cancelledTranscripts == 2, "clearing a hidden selection cancels actual detail work without a failure warning")
    print("PASS selection races and filter invalidation of pending detail")
}

@MainActor func checkRefreshDuringPendingTranscript() async throws {
    let initial = summary("same", tokens: .init(input: 10, output: 2))
    let updated = summary("same", tokens: .init(input: 100, output: 20))
    let source = FixtureSource(catalogs: [
        .init(delay: 0, result: .success(.init(sessions: [initial]))),
        .init(delay: 0, result: .success(.init(sessions: [updated])))],
        transcripts: ["same": [
            .init(delay: 0.25, result: .success(.init(summary: initial))),
            .init(delay: 0.01, result: .success(.init(summary: updated)))]] )
    let state = try model(source, name: "refresh-pending-detail")
    try await load(state)
    state.select("same")
    try await waitFor({ source.calls.transcripts.count == 1 }, "old detail did not start")
    state.refresh()
    try await waitFor({ !state.isLoading && !state.isFiltering && !state.isLoadingTranscript },
                      "refreshed selected detail timed out")
    try expect(state.transcript?.summary.tokens.input == 100 && state.total(\.effectiveTotal).value == 120,
               "catalog refresh reloads selected detail with the newer summary")
    try await Task.sleep(nanoseconds: 350_000_000)
    try expect(state.sessions.first?.tokens.input == 100 && state.transcript?.summary.tokens.input == 100,
               "old same-ID detail cannot write a stale summary into the new catalog")
    try expect(source.calls.cancelledTranscripts == 1, "refresh cancels the pending detail before it can block the catalog scan")
    print("PASS catalog refresh invalidates pending same-session detail and cached statistics")
}

@MainActor func checkFailuresAndFreshSummary() async throws {
    let initial = summary("fresh", tokens: .init(input: 10, output: 2))
    let updated = summary("fresh", tokens: .init(input: 100, cachedInput: 80, output: 4, reasoningOutput: 1))
    let source = FixtureSource(catalogs: [
        .init(delay: 0, result: .success(.init(sessions: [initial]))),
        .init(delay: 0, result: .failure(CheckFailure(message: "模拟目录失败")))],
        transcripts: ["fresh": [
            .init(delay: 0, result: .failure(CheckFailure(message: "模拟内容失败"))),
            .init(delay: 0, result: .success(.init(summary: updated, warnings: ["模拟尾行不完整"])))]] )
    let state = try model(source, name: "recovery")
    try await load(state)
    state.select("fresh")
    try await waitFor({ !state.isLoadingTranscript }, "failure detail timed out")
    try expect(state.transcript == nil && state.transcriptErrorMessage?.contains("模拟内容失败") == true, "detail failure is explicit")
    state.select("fresh", forceReload: true)
    try await waitFor({ !state.isLoadingTranscript && !state.isFiltering }, "retry detail timed out")
    try expect(state.transcriptErrorMessage == nil && state.transcript?.summary.tokens.input == 100, "manual retry recovers with current data")
    try expect(state.sessions.first?.tokens.input == 100 && state.total(\.effectiveTotal).value == 104, "loaded current summary updates list and statistics")
    try expect(state.transcript?.warnings == ["模拟尾行不完整"], "incomplete transcript warning preserved")
    state.refresh()
    try await waitFor({ !state.isLoading }, "failed refresh timed out")
    try expect(state.errorMessage?.contains("模拟目录失败") == true && state.sessions.count == 1, "failed refresh preserves previous successful catalog")
    try expect(state.transcript?.summary.id == "fresh", "failed refresh preserves usable detail")
    print("PASS visible failures, manual recovery and consistent fresh summary")
}

@MainActor func checkFailedRefreshRestartsCancelledDetail() async throws {
    let item = summary("retained")
    let source = FixtureSource(catalogs: [
        .init(delay: 0, result: .success(.init(sessions: [item]))),
        .init(delay: 0.01, result: .failure(CheckFailure(message: "模拟刷新失败")))],
        transcripts: ["retained": [
            .init(delay: 0.25, result: .success(.init(summary: item))),
            .init(delay: 0.01, result: .success(.init(summary: item)))]] )
    let state = try model(source, name: "refresh-cancel-recovery")
    try await load(state)
    state.select("retained")
    try await waitFor({ source.calls.transcripts.count == 1 }, "detail did not start before refresh")
    state.refresh()
    // Finishing the new read does not synchronize the old detached worker's
    // cancellation catch. Observe both generations before checking exact counts.
    try await waitFor({
        let calls = source.calls
        return !state.isLoading && !state.isFiltering && !state.isLoadingTranscript
            && calls.cancelledTranscripts >= 1 && calls.transcripts.count >= 2
    }, "failed refresh detail recovery or cooperative cancellation timed out")
    try expect(source.calls.cancelledTranscripts == 1 && source.calls.transcripts.count == 2,
               "failed refresh resumes the canceled selected-detail read using the preserved catalog")
    try expect(state.selectedSessionID == "retained" && state.transcript?.summary.id == "retained",
               "catalog refresh failure does not strand the selected transcript in a loading or empty state")
    try expect(state.errorMessage?.contains("模拟刷新失败") == true && state.transcriptErrorMessage == nil,
               "refresh error is explicit while user cancellation is not reported as a detail failure")
    print("PASS failed refresh resumes canceled detail from the retained catalog")
}

@MainActor func checkNumericBoundsAndIdentity() async throws {
    let large = summary("large", tokens: .init(total: Int.max))
    let one = summary("one", tokens: .init(input: 1, output: 0, total: 1))
    let none = summary("none")
    let upstreamOverflow = summary("overflowed", tokens: .aggregate([.init(input: Int.max, output: 0, total: Int.max), .init(input: 1, output: 0, total: 1)]))
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: [large, one, none, upstreamOverflow])))],
        transcripts: ["one": [.init(delay: 0, result: .success(.init(summary: none)))]] )
    let state = try model(source, name: "bounds")
    try await load(state)
    try expect(state.total(\.effectiveTotal).isOverflow, "aggregate integer overflow does not trap or show wrong number")
    try expect(state.total(\.effectiveTotal).displayValue == "超出范围", "overflow is visible")
    state.query = "session-one"
    try await filtered(state)
    try expect(state.total(\.output).displayValue == "0" && state.total(\.cachedInput).displayValue == "未记录", "recorded zero differs from missing subset")
    state.select("one")
    try await waitFor({ !state.isLoadingTranscript }, "identity check timed out")
    try expect(state.transcript == nil && state.transcriptErrorMessage != nil, "mismatched transcript identity is rejected")
    state.query = "session-none"
    try await filtered(state)
    try expect(state.total(\.effectiveTotal).value == nil && state.total(\.effectiveTotal).displayValue == "未记录", "unknown-only total remains unknown")
    state.query = "session-overflowed"
    try await filtered(state)
    try expect(state.total(\.effectiveTotal).isOverflow && state.total(\.input).isOverflow,
               "parser or repository aggregation overflow remains visible in desktop totals")
    print("PASS numeric bounds, explicit zero and session identity guards")
}

@MainActor func checkTranscriptIndexesAndPagination() async throws -> SessionDesktopModel {
    let initial = CodexSessionSummary(id: "indexed", sessionID: "session-indexed",
        fileURL: URL(fileURLWithPath: "/fixture/sessions/indexed.jsonl"), title: "模拟索引会话",
        projectPath: "/workspace/mock", messageCount: 4_001, toolCallCount: 1,
        tokens: .init(input: 100, output: 20), searchText: "user-target")
    let longText = String(repeating: "离线模拟用户消息 context ", count: 2_000)
    var messages: [SessionMessage] = []
    for index in 0..<4_003 {
        let kind: SessionMessageKind = index.isMultiple(of: 10) ? .user : .assistant
        messages.append(.init(id: "message-\(index)", kind: kind,
                              text: kind == .user ? longText + " user-target-\(index)" : "模拟回复"))
    }
    messages[20] = .init(id: "message-20", kind: .toolCall, text: "模拟调用", toolName: "mock-tool", callID: "paired-call")
    messages[3_950] = .init(id: "message-3950", kind: .toolResult, text: "模拟结果", callID: "paired-call")
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: [initial])))],
        transcripts: ["indexed": [.init(delay: 0, result: .success(.init(summary: initial, messages: messages)))]] )
    let state = try model(source, name: "transcript-indexes")
    try await load(state)
    state.select("indexed")
    try await waitFor({ !state.isLoadingTranscript && !state.isFiltering }, "indexed transcript timed out")
    guard let index = state.transcriptIndex else { throw CheckFailure(message: "transcript index missing") }
    try expect(index.prompts.count == 399, "prompt directory cached once while transcript is loaded off the main actor")
    try expect(index.index(of: "message-3950") == 3_950, "directory jumps use the recorded message index")
    try expect(index.relatedMessages(for: messages[20]).map(\.id) == ["message-3950"], "distant tool result is cached for cross-page navigation")
    try expect(index.relatedMessages(for: messages[3_950]).map(\.id) == ["message-20"], "tool result links back to its cached call")
    state.query = "user-target-4000"
    try await filtered(state)
    // This query is absent from the summary's bounded search index, so the detail
    // is cleared by the catalog search. Verify full-text hits with a retained scope.
    try expect(state.selectedSessionID == nil, "catalog search still controls which detail is visible")
    state.query = "user-target"
    try await filtered(state)
    state.select("indexed")
    try await waitFor({ !state.isLoadingTranscript && !state.isFiltering }, "indexed search detail timed out")
    try expect(state.matchingUserMessageIDs.count == 399 && state.firstMatchingUserMessageID == "message-0",
               "full user-message hits and the first jump target are published by the background filter")
    for _ in 0..<10_000 {
        _ = state.transcriptIndex?.index(of: "message-3950")
        _ = state.transcriptIndex?.relatedMessages(for: messages[20])
        _ = state.matchingUserMessageIDs.contains("message-4000")
    }
    try expect(source.calls.transcripts.count == 2, "repeated view lookups never reread or rebuild the transcript")
    for count in [0, 1, 99, 100, 101, 250, 4_003, 10_000] {
        var visited: [Int] = []
        for start in stride(from: 0, through: SessionMessagePage.latestStart(messageCount: count), by: SessionMessagePage.size) {
            visited.append(contentsOf: start..<min(count, start + SessionMessagePage.size))
        }
        try expect(visited == Array(0..<count), "earlier/next pages visit every message once for \(count) messages")
        if count > 0 {
            let start = SessionMessagePage.start(containing: count - 1)
            try expect(start == SessionMessagePage.latestStart(messageCount: count), "latest message directory jump selects the final page")
        }
    }
    print("PASS cached 4,003-message directory, full-text hits, distant tool navigation and non-overlapping pagination")
    return state
}

@MainActor func checkBackgroundSearchAndCachedAnalytics() async throws {
    let longText = String(repeating: "模拟日志正文 context token ", count: 3_000)
    let summaries = (0..<100).map { index in
        CodexSessionSummary(id: "large-\(index)", sessionID: "large-session-\(index)",
            fileURL: URL(fileURLWithPath: "/fixture/large/\(index).jsonl"), title: "大目录模拟 \(index)",
            projectPath: index.isMultiple(of: 2) ? "/workspace/alpha" : "/workspace/beta",
            startedAt: Date(timeIntervalSince1970: 1_791_792_000 + Double(index * 86_400)),
            updatedAt: Date(timeIntervalSince1970: 1_791_792_060 + Double(index * 86_400)),
            model: index.isMultiple(of: 2) ? "mock-alpha" : "mock-beta", messageCount: 2,
            tokens: .init(input: 100, cachedInput: 50, output: 20, reasoningOutput: 5),
            searchText: String(longText.prefix(64 * 1_024 - 40)) + "\nsearch-group-\(index.isMultiple(of: 2) ? "alpha" : "beta")")
    }
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: summaries)))])
    let state = try model(source, name: "background-large-search")
    try await load(state)
    try expect(state.filteredSessions.count == 100 && state.total(\.effectiveTotal).value == 12_000,
               "large catalog metadata and totals agree")
    try expect(state.analytics.totalSessionCount == 100 && state.analytics.tokens.effectiveTotal == 12_000,
               "published analytics use the same filtered snapshot")
    state.query = "search-group-alpha"
    try expect(state.isFiltering && state.filteredSessions.count == 100,
               "query setter schedules background filtering without scanning long text inline")
    state.select("large-1")
    try expect(source.calls.transcripts.isEmpty, "pending query cannot select an old-list result")
    var heartbeatCount = 0
    let heartbeat = Task { @MainActor in
        while state.isFiltering {
            heartbeatCount += 1
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    state.query = "search-group-beta"
    try await filtered(state)
    await heartbeat.value
    try expect(heartbeatCount >= 3, "main actor remains responsive while search is pending")
    try expect(state.filteredSessions.count == 50 && state.filteredSessions.allSatisfy { $0.projectPath == "/workspace/beta" },
               "latest debounced query wins over the previous query")
    try expect(state.total(\.effectiveTotal).value == 6_000 && state.total(\.cachedInput).value == 2_500,
               "cached totals are refreshed once with matched sessions and exclude subset double counting")
    try expect(state.analytics.totalSessionCount == 50 && state.analytics.tokens.effectiveTotal == 6_000,
               "filtered chart analytics agree with cached metric totals")
    // Repeated body-like reads are side-effect free and cannot rerun catalog/transcript I/O.
    for _ in 0..<1_000 {
        _ = state.total(\.effectiveTotal); _ = state.total(\.input); _ = state.total(\.output)
        _ = state.projectPaths; _ = state.analytics
    }
    try expect(source.calls.catalog == 1 && source.calls.transcripts.isEmpty,
               "repeated statistic reads never trigger repository work")
    state.query = ""; state.selectProject("/workspace/alpha")
    try await filtered(state)
    try expect(state.filteredSessions.count == 50 && state.total(\.effectiveTotal).value == 6_000,
               "empty-query project filtering uses metadata and refreshes analytics")
    state.query = "search-group-alpha"
    try await filtered(state)
    state.query = "search-group-beta"
    state.selectedProject = nil
    try await filtered(state)
    try expect(state.filteredSessions.count == 50 && state.filteredSessions.allSatisfy { $0.projectPath == "/workspace/beta" },
               "project change while query is pending discards the older filter generation")
    print("PASS 100 × 64K background search, main actor heartbeat, stale-query guards and cached analytics")
}

@MainActor func checkProjectAnalyticsAndUnknownFilter() async throws -> SessionDesktopModel {
    let projects: [String?] = ["/workspace/mock-app", "/workspace/mock-api", "/workspace/mock-tool", nil]
    let models = ["mock-codex", "mock-reasoner", "mock-fast"]
    var summaries: [CodexSessionSummary] = []
    for index in 0..<24 {
        let offset = Double((index % 10) * 86_400)
        let usage = CodexTokenUsage(input: (index + 1) * 100, cachedInput: (index + 1) * 50,
                                   output: (index + 1) * 20, reasoningOutput: (index + 1) * 5)
        let item = CodexSessionSummary(id: "project-\(index)", sessionID: "mock-project-session-\(index)",
            fileURL: URL(fileURLWithPath: "/fixture/projects/\(index).jsonl"),
            title: "模拟项目任务 \(index + 1)", projectPath: projects[index % projects.count],
            startedAt: Date(timeIntervalSince1970: 1_791_792_000 - offset),
            updatedAt: Date(timeIntervalSince1970: 1_791_792_060 - offset),
            model: models[index % 3], messageCount: 3, toolCallCount: index % 5, tokens: usage,
            isArchived: index == 23, searchText: "模拟项目任务，不读取真实日志")
        summaries.append(item)
    }
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: summaries)))])
    let state = try model(source, name: "projects-and-charts")
    try await load(state)
    try expect(state.analytics.totalSessionCount == 23 && state.total(\.effectiveTotal).value == 33_120,
               "project chart totals respect hidden archived sessions")
    try expect(state.projectPaths.contains(SessionProjectSummary.unknownID),
               "unknown projects are a selectable picker option")
    state.selectProject("/workspace/mock-app")
    try await filtered(state)
    try expect(state.filteredSessions.count == 6 && state.total(\.effectiveTotal).value == 7_920,
               "clicking a project filters its exact sessions and recorded totals")
    state.selectProject(SessionProjectSummary.unknownID)
    try await filtered(state)
    try expect(state.filteredSessions.count == 5 && state.filteredSessions.allSatisfy { $0.projectPath == nil },
               "unknown project card selects missing-path sessions without selecting all")
    state.includeArchived = true
    try await filtered(state)
    try expect(state.filteredSessions.count == 6, "unknown project respects archive setting")
    state.selectProject(nil)
    try await filtered(state)
    try expect(state.analytics.totalSessionCount == 24 && state.total(\.effectiveTotal).value == 36_000,
               "clearing project selection updates charts and metrics together")
    print("PASS project drill-down, unknown project group, archive-aware chart totals")
    return state
}

@MainActor func checkLargeWarningPresentation() async throws -> SessionDesktopModel {
    let item = CodexSessionSummary(id: "warnings", sessionID: "mock-warning-session",
        fileURL: URL(fileURLWithPath: "/fixture/sessions/warnings.jsonl"), title: "模拟大量读取提示",
        projectPath: "/workspace/mock", messageCount: 250, tokens: .init(input: 100, output: 20))
    let catalogWarnings = (1...104).map { "模拟索引提示 \($0)：部分本地记录尚未写入完整内容；提示全文仍可在此滚动查看。" }
    let transcriptWarnings = (1...64).map { "模拟会话提示 \($0)：这是用于验证分页与警告区域布局的离线夹具，完整提示未被删除或截断。" }
    let messages = (0..<250).map { index in
        SessionMessage(id: "warning-message-\(index)", kind: index.isMultiple(of: 2) ? .user : .assistant,
                       text: "模拟消息 \(index + 1)：大量警告展开后仍可浏览会话和切换消息页。")
    }
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: [item], warnings: catalogWarnings)))],
        transcripts: ["warnings": [.init(delay: 0, result: .success(.init(summary: item, messages: messages, warnings: transcriptWarnings)))]] )
    let state = try model(source, name: "large-warning-presentation")
    try await load(state)
    state.select("warnings")
    try await waitFor({ !state.isLoadingTranscript && !state.isFiltering }, "warning fixture detail timed out")
    try expect(state.catalogWarnings == catalogWarnings && state.catalogWarnings.count == 104, "all catalog warnings remain available without truncation")
    try expect(state.transcript?.warnings == transcriptWarnings && state.transcript?.warnings.count == 64, "all transcript warnings remain available without truncation")
    try expect(state.transcript?.messages.count == 250 && SessionMessagePage.latestStart(messageCount: 250) == 200,
               "large warning sets preserve the selected transcript and the final message page")
    print("PASS 104 catalog warnings and 64 transcript warnings retained with a paginated transcript")
    return state
}

@MainActor func checkLongErrorPresentation() async throws -> SessionDesktopModel {
    let item = summary("long-errors")
    let detail = (1...20).map { "模拟错误第 \($0) 行：完整错误信息仍可滚动阅读或选中复制，控件外的重试操作保持可用。" }.joined(separator: "\n")
    let source = FixtureSource(catalogs: [
        .init(delay: 0, result: .success(.init(sessions: [item]))),
        .init(delay: 0, result: .failure(CheckFailure(message: detail)))],
        transcripts: ["long-errors": [.init(delay: 0, result: .failure(CheckFailure(message: detail)))]] )
    let state = try model(source, name: "long-error-presentation")
    try await load(state)
    state.select("long-errors")
    try await waitFor({ !state.isLoadingTranscript }, "long error detail timed out")
    state.refresh()
    try await waitFor({ !state.isLoading && !state.isFiltering && !state.isLoadingTranscript }, "long error refresh timed out")
    try expect(state.errorMessage?.contains(detail) == true, "multi-line catalog error remains complete")
    try expect(state.transcriptErrorMessage?.contains(detail) == true, "multi-line transcript error remains complete")
    try expect(state.sessions.count == 1 && state.selectedSessionID == "long-errors", "long errors retain the selected session for manual recovery")
    print("PASS complete multi-line catalog and transcript errors with retained manual recovery")
    return state
}

@MainActor func checkRepositoryIntegration() async throws -> SessionDesktopModel {
    let root = try fixtureRoot("repository")
    let directory = root.appendingPathComponent("sessions/2026/10/12", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("mock-session.jsonl")
    let records: [[String: Any]] = [
        ["type": "session_meta", "timestamp": "2026-10-12T10:00:00Z", "payload": ["id": "mock-session", "cwd": "/workspace/mock-project", "timestamp": "2026-10-12T10:00:00Z"]],
        ["type": "turn_context", "payload": ["model": "mock-codex-model", "cwd": "/workspace/mock-project"]],
        ["type": "response_item", "timestamp": "2026-10-12T10:00:01Z", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "请检查日志里的测试结果。这里是离线模拟会话。"]]]],
        ["type": "response_item", "timestamp": "2026-10-12T10:00:02Z", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "我会读取模拟日志，并核对工具输出。所有操作都是测试夹具。"]]]],
        ["type": "response_item", "timestamp": "2026-10-12T10:00:03Z", "payload": ["type": "function_call", "name": "exec_command", "call_id": "mock-call", "arguments": "{\"cmd\":\"swift test --filter SessionTests\"}"]],
        ["type": "response_item", "timestamp": "2026-10-12T10:00:04Z", "payload": ["type": "function_call_output", "call_id": "mock-call", "output": "SessionTests: 12 tests passed.\n这是模拟工具结果，没有执行真实命令。"]],
        ["type": "response_item", "timestamp": "2026-10-12T10:00:05Z", "payload": ["type": "reasoning", "summary": [["type": "summary_text", "text": "模拟可见思考摘要：用量来自日志累计字段。"]]]],
        ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 1200, "cached_input_tokens": 800, "output_tokens": 240, "reasoning_output_tokens": 40, "total_tokens": 1440]]]]
    ]
    let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    let original = try Data(contentsOf: url)
    let state = SessionDesktopModel(rootURL: root)
    try await load(state)
    try expect(state.sessions.count == 1, "production repository indexes isolated fixture")
    state.query = "日志"
    try await filtered(state)
    guard let selected = state.filteredSessions.first else { throw CheckFailure(message: "fixture search failed") }
    state.select(selected.id)
    try await waitFor({ !state.isLoadingTranscript && !state.isFiltering }, "fixture transcript timed out")
    try expect(state.transcript?.messages.filter { $0.kind == .user }.count == 1, "user message available to production view")
    try expect(state.transcript?.messages.filter { $0.callID == "mock-call" }.count == 2, "tool call and result share their recorded ID")
    try expect(state.total(\.effectiveTotal).value == 1440 && state.total(\.cachedInput).value == 800, "production statistics use recorded cumulative fields")
    let after = try Data(contentsOf: url)
    try expect(after == original, "catalog and transcript reads never rewrite source JSONL")
    print("PASS production repository → desktop model integration with immutable temporary JSONL")
    return state
}

@MainActor func checkPersistentRepositoryReopen() async throws {
    let root = try fixtureRoot("persistent-model")
    let index = try fixtureRoot("persistent-model-index")
    let directory = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let alpha = directory.appendingPathComponent("alpha.jsonl")
    let beta = directory.appendingPathComponent("beta.jsonl")
    let gamma = directory.appendingPathComponent("gamma.jsonl")

    func writeRollout(_ url: URL, id: String, prompt: String, total: Int) throws {
        let records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": "2026-10-12T10:00:00Z",
             "payload": ["id": id, "cwd": "/workspace/persistent-fixture"]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": prompt]],
            ["type": "event_msg", "payload": ["type": "agent_message", "message": "离线模拟回复"]],
            ["type": "event_msg", "payload": ["type": "token_count",
             "info": ["total_token_usage": ["total_tokens": total]]]]
        ]
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    try writeRollout(alpha, id: "persistent-alpha", prompt: "old-marker 原始问题", total: 123)
    try writeRollout(beta, id: "persistent-beta", prompt: "将被删除的模拟会话", total: 456)
    let originalAlpha = try Data(contentsOf: alpha)
    let initial = SessionDesktopModel(rootURL: root, indexDirectoryURL: index)
    try await load(initial)
    try expect(initial.sessions.count == 2 && initial.total(\.effectiveTotal).value == 579,
               "production indexed model loads the initial fixture and statistics")
    let indexFiles = FileManager.default.enumerator(at: index, includingPropertiesForKeys: [.isRegularFileKey])?
        .allObjects.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
    try expect(!indexFiles.isEmpty, "production model creates a real isolated persistent index")

    let reopened = SessionDesktopModel(rootURL: root, indexDirectoryURL: index)
    try await load(reopened)
    try expect(reopened.sessions == initial.sessions && reopened.total(\.effectiveTotal).value == 579,
               "a new desktop model reopens the persisted catalog with correct statistics")
    reopened.query = "old-marker"
    try await filtered(reopened)
    guard let alphaID = reopened.filteredSessions.first?.id else { throw CheckFailure(message: "persistent search missing") }
    try expect(reopened.filteredSessions.count == 1, "search is immediately usable after reopening")
    reopened.select(alphaID)
    try await waitFor({ !reopened.isLoadingTranscript && !reopened.isFiltering }, "persistent detail timed out")
    try expect(reopened.transcript?.messages.first?.text == "old-marker 原始问题",
               "persisted summary still reads the current transcript from source")

    let titleRecord: [String: Any] = ["id": "persistent-alpha", "thread_name": "仅更新的会话标题"]
    let titleData = try JSONSerialization.data(withJSONObject: titleRecord)
    try (String(decoding: titleData, as: UTF8.self) + "\n").write(
        to: root.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
    reopened.refresh()
    try await waitFor({ !reopened.isLoading && !reopened.isFiltering && !reopened.isLoadingTranscript },
                      "persistent title refresh timed out")
    try expect(reopened.sessions.first { $0.id == alphaID }?.title == "仅更新的会话标题",
               "title-only changes update an existing persisted summary")
    let unchangedAlpha = try Data(contentsOf: alpha)
    try expect(unchangedAlpha == originalAlpha, "index creation and title refresh never rewrite the source log")

    try writeRollout(alpha, id: "persistent-alpha", prompt: "new-marker 更新后的问题", total: 900)
    try FileManager.default.removeItem(at: beta)
    try writeRollout(gamma, id: "persistent-gamma", prompt: "新加入的模拟会话", total: 100)
    reopened.query = ""
    try await filtered(reopened)
    reopened.refresh()
    try await waitFor({ !reopened.isLoading && !reopened.isFiltering && !reopened.isLoadingTranscript },
                      "persistent source update timed out")
    try expect(Set(reopened.sessions.map(\.sessionID)) == ["persistent-alpha", "persistent-gamma"],
               "refresh replaces changed source, removes missing source and includes new source")
    try expect(reopened.total(\.effectiveTotal).value == 1000,
               "statistics update from current sources instead of old persisted totals")
    try expect(reopened.transcript?.messages.first?.text == "new-marker 更新后的问题",
               "selected detail reloads changed source without reintroducing old summary")

    let updatedReopen = SessionDesktopModel(rootURL: root, indexDirectoryURL: index)
    try await load(updatedReopen)
    try expect(updatedReopen.sessions == reopened.sessions, "a later instance reopens updated persisted summaries")
    updatedReopen.query = "old-marker"
    try await filtered(updatedReopen)
    try expect(updatedReopen.filteredSessions.isEmpty, "search after reopening drops removed source text")
    updatedReopen.query = "new-marker"
    try await filtered(updatedReopen)
    try expect(updatedReopen.filteredSessions.map(\.sessionID) == ["persistent-alpha"],
               "search after reopening includes updated source text")

    let backup = root.deletingLastPathComponent().appendingPathComponent("persistent-model-backup", isDirectory: true)
    let retainedSessions = reopened.sessions
    let retainedTranscript = reopened.transcript
    try FileManager.default.moveItem(at: root, to: backup)
    do {
        try Data("模拟无法读取的根目录".utf8).write(to: root)
        reopened.refresh()
        try await waitFor({ !reopened.isLoading && !reopened.isFiltering }, "persistent failed refresh timed out")
        try expect(reopened.errorMessage != nil && reopened.sessions == retainedSessions,
                   "failed refresh retains the last visible catalog without replacing it with stale persisted data")
        try expect(reopened.transcript == retainedTranscript, "failed refresh preserves the completed selected transcript")
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: backup, to: root)
    } catch {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.moveItem(at: backup, to: root)
        throw error
    }
    reopened.refresh()
    try await waitFor({ !reopened.isLoading && !reopened.isFiltering && !reopened.isLoadingTranscript },
                      "persistent recovery timed out")
    try expect(reopened.errorMessage == nil && reopened.sessions == retainedSessions,
               "manual refresh recovers after source access returns")
    print("PASS persistent desktop reopening, title/source updates, deleted/new sources, search, detail and failed refresh recovery")
}

@MainActor func checkChunkPoolBoundaries() throws {
    let root = try fixtureRoot("chunk-pool-boundaries")
    let directory = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("chunk-session.jsonl")
    let prompt = String(repeating: "跨块🙂", count: 8_000)
    let title = String(repeating: "标题🙂", count: 8_000)
    let records: [[String: Any]] = [
        ["type": "session_meta", "payload": ["id": "chunk-session", "cwd": "/fixture/chunks"]],
        ["type": "event_msg", "payload": ["type": "user_message", "message": prompt]],
        ["type": "event_msg", "payload": ["type": "agent_message", "message": "完整的跨块回复"]],
        ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 321]]]]
    ]
    let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
    let original = Data(lines.joined(separator: "\n").utf8) // Also exercise final record without newline.
    try original.write(to: url)
    let titleData = try JSONSerialization.data(withJSONObject: ["id": "chunk-session", "thread_name": title])
    try titleData.write(to: root.appendingPathComponent("session_index.jsonl"))
    try expect(original.count > 64 * 1_024 && titleData.count > 64 * 1_024,
               "multi-byte rollout and title fixture span FileHandle chunk boundaries")
    let budget = 20 * 1_024
    let repository = CodexSessionRepository(rootURL: root, limits: .init(maximumCatalogReadBytes: budget))
    var catalog = SessionCatalog()
    var refreshCount = 0
    for _ in 0..<10 {
        catalog = try repository.loadCatalog()
        refreshCount += 1
        try expect(repository.lastReadMetrics.rolloutBytesRead <= budget + 1,
                   "pool boundaries preserve per-refresh byte budget and EOF probe")
        if catalog.sessions.first?.tokens.total == 321 { break }
    }
    guard let summary = catalog.sessions.first else { throw CheckFailure(message: "chunk catalog missing") }
    try expect(refreshCount > 1 && summary.searchText.contains(prompt),
               "continuation retains complete multi-byte prompt across chunk pools and catalog refreshes")
    try expect(summary.title == String(title.prefix(140)) && summary.tokens.total == 321,
               "title index and final token record survive drained Foundation pools")
    let transcript = try repository.loadTranscript(for: summary)
    try expect(transcript.messages.map(\.text) == [prompt, "完整的跨块回复"],
               "detail load retains full Swift-owned message strings across chunk pools")
    try expect(transcript.summary.title == summary.title && transcript.summary.tokens == summary.tokens,
               "catalog and detail agree after bounded continuation completes")
    let after = try Data(contentsOf: url)
    try expect(after == original, "chunk pool reads leave source file untouched")
    print("PASS >64KiB multi-byte JSONL/title chunks, 20KiB continuation, final record and owned strings")
}

@MainActor func managedModel(_ source: FixtureSource, root: URL, directory: URL) -> SessionDesktopModel {
    SessionDesktopModel(rootURL: root, catalogLoader: { try source.catalog() },
        transcriptLoader: { try source.transcript($0) }, managementDirectoryURL: directory)
}

@MainActor func managementIdle(_ state: SessionDesktopModel) async throws {
    try await waitFor({ !state.management.isSaving && !state.management.isLoading && !state.isFiltering },
                      "management operation timed out")
}

@MainActor func checkManagementPersistenceAndFiltering() async throws -> SessionDesktopModel {
    let root = try fixtureRoot("management-source")
    let directory = try fixtureRoot("management-data")
    let a = summary("managed-a", project: "/workspace/first/demo", tokens: .init(total: 10), metadataSessionID: "stable-a")
    let b = summary("managed-b", project: "/workspace/second/demo", tokens: .init(total: 20), metadataSessionID: "stable-b")
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: [a, b])))])
    let state = managedModel(source, root: root, directory: directory)
    try await load(state)
    try expect(!FileManager.default.fileExists(atPath: directory.path), "empty metadata load creates no files")
    state.toggleSessionFavorite(b)
    try expect(state.management.isSaving, "favorite write is marked pending synchronously for quit handling")
    try await managementIdle(state)
    try expect(state.isFavorite(b) && !state.isFavorite(a), "favorite is tied to the intended recorded session")
    try expect(state.filteredSessions.map(\.id) == [b.id, a.id], "favorite sessions appear first with stable source ordering")
    let saved = await state.saveSessionMetadata(b, title: "  本地排错记录  ", note: "线索：数据库连接池\n等待复查")
    try expect(saved, "local rename and notes commit together")
    try await managementIdle(state)
    try expect(state.displayTitle(for: b) == "本地排错记录" && state.note(for: b).contains("连接池"),
               "committed local details are immediately visible")
    try expect(state.sessions == [a, b] && state.sessions.last?.title == "模拟会话 managed-b",
               "management does not change original summaries or prompt indexes")
    state.query = "本地 连接池 SECOND"
    try await filtered(state)
    try expect(state.filteredSessions.map(\.id) == [b.id], "AND search terms match across original project, local name and note")
    state.query = "不会匹配"
    state.query = "等待复查"
    try await filtered(state)
    try expect(state.filteredSessions.map(\.id) == [b.id], "latest debounced metadata search wins")
    let changedNote = await state.saveSessionMetadata(b, title: "本地排错记录", note: "已处理")
    try expect(changedNote, "metadata edit under an active query succeeds")
    try await managementIdle(state)
    try expect(state.filteredSessions.isEmpty, "metadata changes invalidate old positive search matches")
    let restoredNote = await state.saveSessionMetadata(b, title: "本地排错记录", note: "线索：数据库连接池\n等待复查")
    try expect(restoredNote, "search fixture note can be restored")
    try await managementIdle(state)
    try expect(state.filteredSessions.map(\.id) == [b.id], "metadata changes invalidate old negative search matches")
    state.query = ""
    try await filtered(state)
    state.select(a.id)
    try await waitFor({ !state.isLoadingTranscript && !state.isFiltering }, "management selection timed out")
    state.onlyFavoriteSessions = true
    try await filtered(state)
    try expect(state.filteredSessions.map(\.id) == [b.id] && state.selectedSessionID == nil && state.transcript == nil,
               "favorite-only filtering clears hidden detail")
    try expect(state.total(\.effectiveTotal).value == 20 && state.analytics.totalSessionCount == 1,
               "favorite session filtering uses known counters from visible sessions only")
    state.onlyFavoriteSessions = false
    try await filtered(state)
    state.toggleProjectFavorite(b.projectPath!)
    try await managementIdle(state)
    try expect(state.isFavoriteProject(b.projectPath!) && !state.isFavoriteProject(a.projectPath!),
               "projects with the same basename keep separate bookmarks")
    try expect(state.projectPaths == [b.projectPath!, a.projectPath!], "project picker keeps all choices with favorites first")
    state.onlyFavoriteProjects = true
    try expect(state.displayedProjects.map(\.id) == [b.projectPath!] && state.analytics.projects.count == 2,
               "favorite projects filter only the project list, retaining complete analytics")
    try expect(state.filteredSessions.count == 2 && state.projectPaths.count == 2,
               "project-only bookmarks do not implicitly hide sessions or invalidate picker choices")
    let reopened = managedModel(source, root: root, directory: directory)
    try await load(reopened)
    try expect(reopened.isFavorite(b) && reopened.isFavoriteProject(b.projectPath!), "bookmarks persist across model recreation")
    try expect(reopened.displayTitle(for: b) == "本地排错记录" && reopened.note(for: b).contains("等待复查"),
               "local names and notes persist across model recreation")
    let reset = await reopened.saveSessionMetadata(b, title: "", note: "")
    try expect(reset, "empty local details reset to source title without deleting the bookmark")
    try await managementIdle(reopened)
    try expect(reopened.displayTitle(for: b) == b.title && reopened.note(for: b).isEmpty && reopened.isFavorite(b),
               "reset restores source display while retaining unrelated favorite state")
    state.refresh()
    try await waitFor({ !state.isLoading && !state.isFiltering && !state.management.isLoading }, "metadata refresh timed out")
    try expect(state.displayTitle(for: b) == b.title && state.note(for: b).isEmpty,
               "explicit refresh picks up metadata written by another model")
    let retainedManagementTasks = Mirror(reflecting: state.management).children.filter {
        ($0.label == "loadTask" || $0.label == "mutationTask") && !Mirror(reflecting: $0.value).children.isEmpty
    }
    try expect(retainedManagementTasks.isEmpty, "completed management tasks release their snapshot results")
    #if RENDER_SESSIONS
    let previewDetails = await state.saveSessionMetadata(b, title: "数据库连接池排查", note: "已找到重试入口，等待验证后关闭。")
    try expect(previewDetails, "isolated management preview details saved")
    try await managementIdle(state)
    #endif
    print("PASS persisted management, local details, cross-field debounced search, bookmarks, project-only filtering and reset")
    return state
}

@MainActor func checkManagementFailureAndRetry() async throws {
    let root = try fixtureRoot("management-failure-source")
    let directory = try fixtureRoot("management-failure-data")
    let item = summary("managed-failure", metadataSessionID: "stable-failure")
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: [item])))])
    let state = managedModel(source, root: root, directory: directory)
    try await load(state)
    let store = try SessionManagementStore(directoryURL: directory, sourceRootURL: root)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    let malformed = Data("{ malformed fixture }".utf8)
    try malformed.write(to: store.fileURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
    let failed = await state.saveSessionMetadata(item, title: "不应显示", note: "不应存储")
    try expect(!failed && state.management.hasPendingRetry && state.management.errorMessage != nil,
               "failed save exposes error and retry without pretending the editor succeeded")
    try expect(state.displayTitle(for: item) == item.title && state.note(for: item).isEmpty,
               "failed save leaves previous committed values visible")
    let corruptedAfter = try Data(contentsOf: store.fileURL)
    try expect(corruptedAfter == malformed, "corrupt management bytes are preserved")
    try FileManager.default.removeItem(at: store.fileURL)
    let repairedRead = await state.management.reload()
    try await managementIdle(state)
    try expect(repairedRead, "repaired private fixture directory can be read successfully")
    try expect(state.management.hasPendingRetry && state.management.errorMessage != nil,
               "rereading a repaired store does not hide the unsaved operation's retry status")
    state.management.retryLastMutation()
    try await managementIdle(state)
    try expect(state.displayTitle(for: item) == "不应显示" && state.note(for: item) == "不应存储",
               "explicit retry saves the retained failed operation after the underlying issue is repaired")
    try expect(!state.management.hasPendingRetry && state.management.errorMessage == nil,
               "successful retry clears only the reported failed operation")
    let excessive = await state.saveSessionMetadata(item, title: String(repeating: "长", count: 121), note: "新备注")
    try expect(!excessive && state.displayTitle(for: item) == "不应显示" && state.note(for: item) == "不应存储",
               "validation rejects name and note together without a partial update")
    let unsafe = managedModel(source, root: root, directory: root.appendingPathComponent("must-not-write"))
    unsafe.loadIfNeeded()
    try await waitFor({ !unsafe.isLoading && !unsafe.isFiltering && !unsafe.management.isLoading }, "unsafe metadata load timed out")
    try expect(!unsafe.management.hasLoaded && unsafe.management.errorMessage != nil,
               "unsafe store initialization remains a visible load failure")
    let unsafeSave = await unsafe.saveSessionMetadata(item, title: "无权限", note: "")
    try expect(!unsafeSave && !FileManager.default.fileExists(atPath: root.path),
               "unsafe initialization does not silently fall back to in-memory or write the source tree")
    print("PASS corrupt-store preservation, failed-save draft values, retry, atomic validation and unsafe-initialization rejection")
}

@MainActor func checkManagementIdentityAndPendingQuit() async throws {
    let root = try fixtureRoot("management-identity-source")
    let directory = try fixtureRoot("management-identity-data")
    let original = summary("managed-original", metadataSessionID: "stable-move")
    let moved = CodexSessionSummary(id: "managed-archived", sessionID: original.sessionID,
        fileURL: URL(fileURLWithPath: "/fixture/archived_sessions/moved.jsonl"), title: original.title,
        projectPath: original.projectPath, isArchived: true, metadataSessionID: "stable-move")
    let unknownA = summary("unknown-a")
    let unknownB = CodexSessionSummary(id: "unknown-b", sessionID: unknownA.sessionID,
        fileURL: URL(fileURLWithPath: "/fixture/another/unknown-a.jsonl"), title: unknownA.title)
    let source = FixtureSource(catalogs: [
        .init(delay: 0, result: .success(.init(sessions: [original, unknownA, unknownB]))),
        .init(delay: 0, result: .success(.init(sessions: [moved, unknownA, unknownB])))
    ])
    let state = managedModel(source, root: root, directory: directory)
    try await load(state)
    state.toggleSessionFavorite(original)
    await state.management.waitForPendingMutations()
    try expect(state.isFavorite(original) && !state.management.isSaving,
               "pending quit wait observes the bookmark requested in the same main-actor turn")
    try await managementIdle(state)
    let saved = await state.saveSessionMetadata(original, title: "跨归档保留", note: "stable identity")
    try expect(saved, "recorded identity details saved")
    try await managementIdle(state)
    state.toggleSessionFavorite(unknownA)
    try await managementIdle(state)
    try expect(state.isFavorite(unknownA) && !state.isFavorite(unknownB), "unknown-session filename collisions use full paths")
    state.includeArchived = true
    state.refresh()
    try await waitFor({ !state.isLoading && !state.isFiltering }, "archive refresh timed out")
    try expect(state.isFavorite(moved) && state.displayTitle(for: moved) == "跨归档保留", "real session IDs retain details across archive moves")
    let staleSave = await state.saveSessionMetadata(original, title: "过期编辑", note: "")
    try expect(!staleSave && state.management.errorMessage?.contains("来源已变化") == true,
               "a frozen editor cannot write through an obsolete catalog target")
    try expect(state.displayTitle(for: moved) == "跨归档保留", "stale editor rejection preserves the current committed value")
    let otherRoot = try fixtureRoot("management-another-source")
    let isolated = managedModel(FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: [moved])))]),
                                root: otherRoot, directory: directory)
    isolated.includeArchived = true
    try await load(isolated)
    try expect(!isolated.isFavorite(moved) && isolated.displayTitle(for: moved) == moved.title,
               "the same ID in a different source root never borrows another root's metadata")
    print("PASS stable archive identity, full-path fallbacks, stale-target protection, source-root isolation and pending-quit wait")
}

@MainActor func checkManagementEditorBaselineConflicts() async throws {
    let root = try fixtureRoot("management-editor-source")
    let directory = try fixtureRoot("management-editor-data")
    let item = summary("managed-editor", metadataSessionID: "stable-editor")
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: [item])))])
    let first = managedModel(source, root: root, directory: directory)
    try await load(first)
    let initial = await first.saveSessionMetadata(item, title: "初始名称", note: "初始备注")
    try expect(initial, "editor baseline fixture saved")
    try await managementIdle(first)
    let second = managedModel(source, root: root, directory: directory)
    try await load(second)
    guard let firstBaseline = first.management.index.entry(for: item),
          let secondBaseline = second.management.index.entry(for: item) else {
        throw CheckFailure(message: "editor baseline fixture missing")
    }
    let externalNote = await second.saveSessionMetadata(item, title: "初始名称", note: "另一实例的新备注", baseline: secondBaseline)
    try expect(externalNote, "other instance updates its dirty note field")
    try await managementIdle(second)
    first.toggleSessionFavorite(item)
    try await managementIdle(first)
    let localTitle = await first.saveSessionMetadata(item, title: "本地新名称", note: "初始备注", baseline: firstBaseline)
    try expect(localTitle, "a stale editor changing only title can save independently of a changed note")
    try await managementIdle(first)
    try expect(first.displayTitle(for: item) == "本地新名称" && first.note(for: item) == "另一实例的新备注" && first.isFavorite(item),
               "title-only save preserves newer external notes and current favorite state")
    guard let frozen = first.management.index.entry(for: item) else { throw CheckFailure(message: "updated editor baseline missing") }
    let secondLoaded = await second.management.reload()
    try expect(secondLoaded, "explicit editor reread reports its actual success")
    try await managementIdle(second)
    guard let freshSecond = second.management.index.entry(for: item) else { throw CheckFailure(message: "refreshed baseline missing") }
    let externalTitle = await second.saveSessionMetadata(item, title: "另一实例的新名称", note: "另一实例的新备注", baseline: freshSecond)
    try expect(externalTitle, "another editor changes the same title field")
    try await managementIdle(second)
    let conflicted = await first.saveSessionMetadata(item, title: "尚未保存的草稿", note: "另一实例的新备注", baseline: frozen)
    try expect(!conflicted && first.management.errorMessage?.contains("其他操作更新") == true && first.management.hasPendingRetry,
               "same-field baseline conflicts return failure and preserve the unsaved draft operation")
    try expect(first.displayTitle(for: item) == "本地新名称" && first.note(for: item) == "另一实例的新备注",
               "conflict keeps the last successfully committed UI values")
    let store = try SessionManagementStore(directoryURL: directory, sourceRootURL: root)
    let onDisk = try store.load().entry(kind: .session, itemID: item.managementID)
    try expect(onDisk?.displayName == "另一实例的新名称" && onDisk?.note == "另一实例的新备注" && onDisk?.isFavorite == true,
               "conflict does not overwrite the external edit or unrelated bookmark")
    let reread = await first.management.reload()
    try expect(reread && first.displayTitle(for: item) == "另一实例的新名称", "a successful explicit reread provides the latest baseline")
    try await managementIdle(first)
    guard let freshFirst = first.management.index.entry(for: item) else { throw CheckFailure(message: "new editor baseline missing") }
    let retriedDraft = await first.saveSessionMetadata(item, title: "尚未保存的草稿", note: "另一实例的新备注", baseline: freshFirst)
    try expect(retriedDraft, "a user can save the retained dirty draft after explicitly rebasing to the latest entry")
    try await managementIdle(first)
    try expect(first.displayTitle(for: item) == "尚未保存的草稿" && first.note(for: item) == "另一实例的新备注"
        && first.management.errorMessage == nil && !first.management.hasPendingRetry,
               "confirmed rebase saves the intended field and clears the old conflict")
    let identicalResult = await second.saveSessionMetadata(item, title: "尚未保存的草稿", note: "另一实例的新备注", baseline: freshSecond)
    try expect(identicalResult, "a concurrent field already equal to the intended value is an idempotent success")
    try await managementIdle(second)
    guard let whitespaceBaseline = second.management.index.entry(for: item) else { throw CheckFailure(message: "whitespace baseline missing") }
    let newestTitle = await first.saveSessionMetadata(item, title: "更新后的外部名称", note: "另一实例的新备注")
    try expect(newestTitle, "external whitespace fixture update succeeds")
    try await managementIdle(first)
    let whitespaceOnly = await second.saveSessionMetadata(item, title: "  尚未保存的草稿  ", note: "另一实例的新备注", baseline: whitespaceBaseline)
    try expect(whitespaceOnly && second.displayTitle(for: item) == "更新后的外部名称",
               "semantically unchanged whitespace in a stale name does not overwrite or conflict with the new external name")
    let malformed = Data("broken fixture".utf8)
    try malformed.write(to: store.fileURL)
    let failedRead = await first.management.reload()
    try expect(!failedRead && first.management.hasLoaded && first.displayTitle(for: item) == "更新后的外部名称",
               "reload reports real failure while preserving an earlier successful load and committed display")
    print("PASS dirty-field baseline save, concurrent note preservation, same-field conflict, explicit rebase, idempotence and reload failure")
}

@MainActor func checkManagementDiscardFailedDraft() async throws {
    let root = try fixtureRoot("management-discard-source")
    let directory = try fixtureRoot("management-discard-data")
    let a = summary("discard-a", metadataSessionID: "stable-discard-a")
    let b = summary("discard-b", metadataSessionID: "stable-discard-b")
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: [a, b])))])
    let state = managedModel(source, root: root, directory: directory)
    try await load(state)
    let seeded = await state.saveSessionMetadata(a, title: "已保存的名称", note: "已保存的备注")
    try expect(seeded, "discard fixture has committed values")
    try await managementIdle(state)
    let store = try SessionManagementStore(directoryURL: directory, sourceRootURL: root)
    var goodBytes = try Data(contentsOf: store.fileURL)
    let malformed = Data("malformed discard fixture".utf8)
    try malformed.write(to: store.fileURL)
    let failedA = await state.saveSessionMetadata(a, title: "应该丢弃的草稿", note: "未保存的备注")
    try expect(!failedA && state.management.hasPendingRetry, "failed details remain available while the editor is open")
    state.discardFailedSessionMetadata(a)
    try expect(!state.management.hasPendingRetry && state.management.errorMessage == nil,
               "cancelling the matching failed editor clears only its queued details and save error")
    let afterDiscard = try Data(contentsOf: store.fileURL)
    try expect(afterDiscard == malformed && state.displayTitle(for: a) == "已保存的名称" && state.note(for: a) == "已保存的备注",
               "discarding a draft neither writes storage nor changes committed display values")
    try goodBytes.write(to: store.fileURL)
    state.management.retryLastMutation()
    try await managementIdle(state)
    let afterNoop = try store.load().entry(kind: .session, itemID: a.managementID)
    try expect(afterNoop?.displayName == "已保存的名称" && afterNoop?.note == "已保存的备注",
               "a later retry cannot revive cancelled details")

    try malformed.write(to: store.fileURL)
    let failedB = await state.saveSessionMetadata(b, title: "另一个会话的草稿", note: "还要重试")
    try expect(!failedB, "other-session failure fixture created")
    let otherError = state.management.errorMessage
    state.discardFailedSessionMetadata(a)
    try expect(state.management.hasPendingRetry && state.management.errorMessage == otherError,
               "cancelling one session does not discard another session's failed details")
    try goodBytes.write(to: store.fileURL)
    state.management.retryLastMutation()
    try await managementIdle(state)
    try expect(state.displayTitle(for: b) == "另一个会话的草稿" && state.note(for: b) == "还要重试",
               "the other session can still retry its retained failed details")
    goodBytes = try Data(contentsOf: store.fileURL)

    try malformed.write(to: store.fileURL)
    state.toggleSessionFavorite(a)
    try await managementIdle(state)
    let favoriteError = state.management.errorMessage
    state.discardFailedSessionMetadata(a)
    try expect(state.management.hasPendingRetry && state.management.errorMessage == favoriteError && !state.isFavorite(a),
               "cancelling details never discards a favorite failure for the same session")
    try goodBytes.write(to: store.fileURL)
    state.management.retryLastMutation()
    try await managementIdle(state)
    try expect(state.isFavorite(a) && state.displayTitle(for: a) == "已保存的名称",
               "favorite retry remains usable and preserves existing details")
    goodBytes = try Data(contentsOf: store.fileURL)

    try malformed.write(to: store.fileURL)
    let beforeReadFailure = await state.saveSessionMetadata(a, title: "取消后的读取失败", note: "")
    try expect(!beforeReadFailure, "details failure exists before a later read failure")
    let failedReload = await state.management.reload()
    try expect(!failedReload && state.management.errorMessage?.hasPrefix("读取收藏与备注失败") == true,
               "a later unrelated load failure has its own visible error")
    let readError = state.management.errorMessage
    state.discardFailedSessionMetadata(a)
    try expect(!state.management.hasPendingRetry && state.management.errorMessage == readError,
               "discarding matching failed details retains the unrelated read error")
    try goodBytes.write(to: store.fileURL)
    state.management.retryLastMutation()
    try await managementIdle(state)
    let afterReadDiscard = try store.load().entry(kind: .session, itemID: a.managementID)
    try expect(afterReadDiscard?.displayName == "已保存的名称" && afterReadDiscard?.isFavorite == true,
               "a discarded operation stays absent after repairing storage")
    let reloaded = await state.management.reload()
    try expect(reloaded && state.management.errorMessage == nil, "explicit successful load clears the repaired read error")
    print("PASS editor-cancelled details never retry, committed values preserved, unrelated session/favorite retry and load error retained")
}

@MainActor func projectBaseline(_ state: SessionDesktopModel, _ path: String) -> SessionManagementEntry {
    state.management.index.entryForProject(path)
        ?? .init(kind: .project, itemID: SessionManagementIndex.projectID(path))
}

@MainActor func checkProjectTagFilteringAndPersistence() async throws -> SessionDesktopModel {
    let root = try fixtureRoot("project-tags-source")
    let directory = try fixtureRoot("project-tags-data")
    let a = summary("tag-a", project: "/workspace/alpha/demo", tokens: .init(total: 10), metadataSessionID: "tag-a")
    let b = summary("tag-b", project: "/workspace/beta/demo", tokens: .init(total: 20), metadataSessionID: "tag-b")
    let unknown = summary("tag-unknown", project: "", tokens: .init(total: 30), metadataSessionID: "tag-unknown")
    let archived = summary("tag-archived", project: a.projectPath!, archived: true, tokens: .init(total: 40), metadataSessionID: "tag-archived")
    let catalog = SessionCatalog(sessions: [a, b, unknown, archived])
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(catalog))])
    let state = managedModel(source, root: root, directory: directory)
    try await load(state)
    let savedA = await state.saveProjectTags(a.projectPath!, tags: [" Work ", "work", "Bug"], baseline: projectBaseline(state, a.projectPath!))
    try expect(savedA, "project tags save using a frozen project baseline")
    try await managementIdle(state)
    let savedB = await state.saveProjectTags(b.projectPath!, tags: ["Personal"], baseline: projectBaseline(state, b.projectPath!))
    try expect(savedB, "a same-basename project keeps its own tags")
    try await managementIdle(state)
    let savedUnknown = await state.saveProjectTags(SessionProjectSummary.unknownID, tags: ["待确认"],
                                                  baseline: projectBaseline(state, SessionProjectSummary.unknownID))
    try expect(savedUnknown, "unknown project tags use the reserved management grouping key")
    try await managementIdle(state)
    try expect(state.projectTags(a.projectPath!).count == 2 && state.projectTags(b.projectPath!) == ["Personal"],
               "trimmed case variants deduplicate without merging same-basename projects")
    try expect(state.availableProjectTags.count == 4, "tag choices combine current catalog projects with casefold deduplication")
    let detailSaved = await state.saveSessionMetadata(a, title: "项目排错", note: "数据库连接池")
    try expect(detailSaved, "tag search fixture includes local session details")
    try await managementIdle(state)
    state.toggleProjectFavorite(a.projectPath!)
    try await managementIdle(state)
    state.selectedProjectTag = "wOrK"
    try await filtered(state)
    try expect(state.filteredSessions.map(\.id) == [a.id] && state.analytics.projects.map(\.id) == [a.projectPath!]
        && state.total(\.effectiveTotal).value == 10,
               "casefold tag filter applies globally to session lists, projects, statistics and known totals")
    try expect(state.availableProjectTags.contains("wOrK"), "tag picker includes the exact selected display variant")
    state.includeArchived = true
    try await filtered(state)
    try expect(state.filteredSessions.count == 2 && state.total(\.effectiveTotal).value == 50,
               "tag filter AND archive inclusion preserves recorded counters")
    state.onlyFavoriteSessions = true
    try await filtered(state)
    try expect(state.filteredSessions.isEmpty, "tag and favorite-session filters combine with AND")
    state.toggleSessionFavorite(a)
    try await managementIdle(state)
    try expect(state.filteredSessions.map(\.id) == [a.id] && state.total(\.effectiveTotal).value == 10,
               "bookmark changes invalidate filtered tag results")
    state.onlyFavoriteSessions = false
    state.selectedProject = b.projectPath
    try await filtered(state)
    try expect(state.filteredSessions.isEmpty, "tag and exact project filters combine without matching sibling basenames")
    state.selectedProject = nil
    state.query = "WORK 连接池 second"
    try await filtered(state)
    try expect(state.filteredSessions.map(\.id) == [a.id], "query AND terms can span project tags, local notes and source prompts")
    state.query = "不匹配"
    state.query = "bug SECOND"
    try await filtered(state)
    try expect(state.filteredSessions.map(\.id) == [a.id, archived.id], "latest debounced tag-search generation wins")
    state.query = ""
    try await filtered(state)
    let changedCase = await state.saveProjectTags(a.projectPath!, tags: ["work", "Bug"], baseline: projectBaseline(state, a.projectPath!))
    try expect(changedCase, "tag display case can be changed without changing its filter identity")
    try await managementIdle(state)
    try expect(state.availableProjectTags.contains("wOrK") && state.filteredSessions.count == 2,
               "case-only external metadata display changes keep a valid exact picker choice")
    let removed = await state.saveProjectTags(a.projectPath!, tags: [], baseline: projectBaseline(state, a.projectPath!))
    try expect(removed, "last project instance of a selected tag can be removed")
    try await managementIdle(state)
    try expect(state.selectedProjectTag == "wOrK" && state.availableProjectTags.contains("wOrK") && state.filteredSessions.isEmpty,
               "removing the selected tag retains explicit empty filtering instead of silently broadening results")
    state.selectedProjectTag = nil
    try await filtered(state)
    try expect(state.filteredSessions.count == 4 && state.total(\.effectiveTotal).value == 100,
               "clearing an unavailable tag restores the intended archive/query scope")
    state.selectedProjectTag = "待确认"
    try await filtered(state)
    try expect(state.filteredSessions.map(\.id) == [unknown.id] && state.analytics.projects.first?.id == SessionProjectSummary.unknownID,
               "unknown-project labels filter only the unknown grouping")
    state.selectedProjectTag = nil
    try await filtered(state)
    let previewTags = ["A" + String(repeating: "长", count: 19), "B" + String(repeating: "宽", count: 19), "工作", "后端", "待验证"]
    let previewSaved = await state.saveProjectTags(a.projectPath!, tags: previewTags, baseline: projectBaseline(state, a.projectPath!))
    try expect(previewSaved, "project tag preview fixture saved")
    try await managementIdle(state)
    let reopened = managedModel(source, root: root, directory: directory)
    try await load(reopened)
    try expect(reopened.projectTags(a.projectPath!) == state.projectTags(a.projectPath!)
        && reopened.projectTags(b.projectPath!) == ["Personal"] && reopened.projectTags(SessionProjectSummary.unknownID) == ["待确认"],
               "project tags persist across a desktop model restart")
    try expect(reopened.isFavoriteProject(a.projectPath!) && reopened.displayTitle(for: a) == "项目排错",
               "project tags preserve existing bookmarks and session details")
    try expect(state.sessions == catalog.sessions, "project tagging never changes source summaries or token counters")
    let inMemory = try model(source, name: "project-tags-memory")
    try await load(inMemory)
    let memorySaved = await inMemory.saveProjectTags(a.projectPath!, tags: ["内存夹具"], baseline: projectBaseline(inMemory, a.projectPath!))
    try expect(memorySaved, "isolated in-memory backend accepts project tags")
    try await managementIdle(inMemory)
    let memoryReloaded = await inMemory.management.reload()
    try expect(memoryReloaded && inMemory.projectTags(a.projectPath!) == ["内存夹具"],
               "nonempty tags retain an otherwise empty in-memory management entry")
    print("PASS project tag persistence, fixed-locale casefold, global AND filters/totals/search, missing picker choices, unknown groups and memory retention")
    return state
}

@MainActor func checkProjectTagConflictFailureAndCancel() async throws {
    let root = try fixtureRoot("project-tags-conflict-source")
    let directory = try fixtureRoot("project-tags-conflict-data")
    let a = summary("tag-conflict-a", project: "/workspace/tag-first", metadataSessionID: "tag-conflict-a")
    let b = summary("tag-conflict-b", project: "/workspace/tag-second", metadataSessionID: "tag-conflict-b")
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: [a, b])))])
    let first = managedModel(source, root: root, directory: directory)
    try await load(first)
    let initial = await first.saveProjectTags(a.projectPath!, tags: ["原标签"], baseline: projectBaseline(first, a.projectPath!))
    try expect(initial, "tag conflict baseline fixture saved")
    try await managementIdle(first)
    first.toggleProjectFavorite(a.projectPath!)
    try await managementIdle(first)
    let stale = projectBaseline(first, a.projectPath!)
    let second = managedModel(source, root: root, directory: directory)
    try await load(second)
    let external = await second.saveProjectTags(a.projectPath!, tags: ["外部标签"], baseline: projectBaseline(second, a.projectPath!))
    try expect(external, "second instance tag update saved")
    try await managementIdle(second)
    let unchanged = await first.saveProjectTags(a.projectPath!, tags: ["原标签"], baseline: stale)
    try expect(unchanged && first.projectTags(a.projectPath!) == ["外部标签"] && first.isFavoriteProject(a.projectPath!),
               "a stale unchanged tag draft does not overwrite newer tags or bookmarks")
    try await managementIdle(first)
    let conflictBaseline = projectBaseline(first, a.projectPath!)
    let externalAgain = await second.saveProjectTags(a.projectPath!, tags: ["更新的外部标签"], baseline: projectBaseline(second, a.projectPath!))
    try expect(externalAgain, "second instance advances the same tag field again")
    try await managementIdle(second)
    let conflict = await first.saveProjectTags(a.projectPath!, tags: ["本地草稿"], baseline: conflictBaseline)
    try expect(!conflict && first.management.hasPendingRetry && first.projectTags(a.projectPath!) == ["外部标签"],
               "changed-tag conflicts fail and preserve the previously committed UI value")
    let store = try SessionManagementStore(directoryURL: directory, sourceRootURL: root)
    let diskAfterConflict = try store.load().entry(kind: .project, itemID: a.projectPath!)
    try expect(diskAfterConflict?.tags == ["更新的外部标签"] && diskAfterConflict?.isFavorite == true,
               "a conflicting tag draft cannot overwrite external tags or unrelated bookmark state")
    first.discardFailedProjectTags(b.projectPath!)
    try expect(first.management.hasPendingRetry, "cancelling a different project's editor preserves the tag retry")
    first.discardFailedProjectTags(a.projectPath!)
    try expect(!first.management.hasPendingRetry && first.management.errorMessage == nil, "cancelling the matching tags editor clears its failed draft")
    first.management.retryLastMutation()
    try await managementIdle(first)
    let afterCancel = try store.load().entry(kind: .project, itemID: a.projectPath!)
    try expect(afterCancel?.tags == ["更新的外部标签"], "a later retry cannot revive cancelled project tags")
    let reloaded = await first.management.reload()
    try expect(reloaded, "tag editor can explicitly load a fresh baseline")
    try await managementIdle(first)
    let confirmed = await first.saveProjectTags(a.projectPath!, tags: ["确认后的草稿"], baseline: projectBaseline(first, a.projectPath!))
    try expect(confirmed && first.projectTags(a.projectPath!) == ["确认后的草稿"], "explicit refreshed-baseline save commits a retained user draft")
    try await managementIdle(first)
    let invalid = await first.saveProjectTags(a.projectPath!, tags: [String(repeating: "长", count: 21)], baseline: projectBaseline(first, a.projectPath!))
    try expect(!invalid && first.management.hasPendingRetry && first.projectTags(a.projectPath!) == ["确认后的草稿"],
               "invalid tags preserve the saved value and expose an owned retryable failure")
    first.discardFailedProjectTags(a.projectPath!)
    try expect(!first.management.hasPendingRetry, "invalid cancelled tags are removed from retry state")
    var goodBytes = try Data(contentsOf: store.fileURL)
    let malformed = Data("broken project tag fixture".utf8)
    try malformed.write(to: store.fileURL)
    first.toggleProjectFavorite(a.projectPath!)
    try await managementIdle(first)
    first.discardFailedProjectTags(a.projectPath!)
    try expect(first.management.hasPendingRetry, "tag-editor cancellation preserves a same-project favorite failure")
    try goodBytes.write(to: store.fileURL)
    first.management.retryLastMutation()
    try await managementIdle(first)
    try expect(!first.isFavoriteProject(a.projectPath!) && first.projectTags(a.projectPath!) == ["确认后的草稿"],
               "the unaffected favorite operation can still retry without erasing tags")
    goodBytes = try Data(contentsOf: store.fileURL)
    try malformed.write(to: store.fileURL)
    let failedDetails = await first.saveSessionMetadata(a, title: "会话详情待重试", note: "")
    try expect(!failedDetails, "unrelated session-details failure fixture created")
    first.discardFailedProjectTags(a.projectPath!)
    try expect(first.management.hasPendingRetry, "tag cancellation preserves unrelated failed session details")
    try goodBytes.write(to: store.fileURL)
    first.management.retryLastMutation()
    try await managementIdle(first)
    try expect(first.displayTitle(for: a) == "会话详情待重试", "unrelated session details still save through their retry")
    goodBytes = try Data(contentsOf: store.fileURL)
    try malformed.write(to: store.fileURL)
    let failedUnchanged = await first.saveProjectTags(a.projectPath!, tags: first.projectTags(a.projectPath!), baseline: projectBaseline(first, a.projectPath!))
    try expect(!failedUnchanged, "an unchanged tag draft still reports an unreadable store")
    let readFailed = await first.management.reload()
    try expect(!readFailed, "tag cancellation fixture has a later load failure")
    let readError = first.management.errorMessage
    first.discardFailedProjectTags(a.projectPath!)
    try expect(!first.management.hasPendingRetry && first.management.errorMessage == readError,
               "cancelling even an unchanged failed tag operation preserves a later load error")
    try goodBytes.write(to: store.fileURL)
    let repaired = await first.management.reload()
    try expect(repaired, "repaired tag fixture is readable")
    let stalePath = "/workspace/no-longer-in-catalog"
    let staleSave = await first.saveProjectTags(stalePath, tags: ["不得写入"], baseline: .init(kind: .project, itemID: stalePath))
    try expect(!staleSave && first.management.errorMessage?.contains("来源已变化") == true,
               "tag editor rejects projects absent from its current catalog")
    first.discardFailedProjectTags(stalePath)
    try expect(first.management.errorMessage == nil && !first.management.hasPendingRetry,
               "cancelling stale project tags clears only their target-specific error")
    print("PASS tag baseline conflict, unchanged-field preservation, explicit rebase, validation, narrow cancellation, unrelated retries/load errors and stale targets")
}

#if RENDER_SESSIONS
@MainActor func render(_ state: SessionDesktopModel, projects: SessionDesktopModel, indexed: SessionDesktopModel,
                       managed: SessionDesktopModel, tagged: SessionDesktopModel,
                       warnings: SessionDesktopModel, errors: SessionDesktopModel, to path: String) async throws {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    if let transcript = state.transcript {
        let draft = SessionHandoff.draft(transcript: transcript)
        let handoff = AnyView(SessionHandoffEditor(initialText: draft))
        let search = AnyView(SessionFullTextSearchSheet(model: state, onOpen: { _ in }))
        for (name, content, width, height) in [("desktop-handoff-preview.png", handoff, CGFloat(680), CGFloat(520)),
                                              ("desktop-fulltext-preview.png", search, CGFloat(760), CGFloat(580))] {
            let host = NSHostingView(rootView: content.background(MemoryStyle.surface))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 70_000_000)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CheckFailure(message: "reuse render bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure(message: "reuse render PNG") }
            try png.write(to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(name))
            window.close()
            print("RENDER \(name)")
        }
    }
    let expanded = Set(state.transcript?.messages.filter { $0.callID != nil }.map(\.id) ?? [])
    let output = URL(fileURLWithPath: path)
    let expandedOutput = output.deletingPathExtension().appendingPathExtension("expanded.png")
    // 888-point width approximates the default app's content area after sidebar.
    // The taller second capture also exposes expanded tool cards for visual QA.
    let projectsOutput = output.deletingLastPathComponent().appendingPathComponent("desktop-projects-preview.png")
    let statisticsOutput = output.deletingLastPathComponent().appendingPathComponent("desktop-statistics-preview.png")
    let paginationOutput = output.deletingLastPathComponent().appendingPathComponent("desktop-pagination-preview.png")
    let warningsOutput = output.deletingLastPathComponent().appendingPathComponent("desktop-warnings-preview.png")
    let errorsOutput = output.deletingLastPathComponent().appendingPathComponent("desktop-errors-preview.png")
    let managementOutput = output.deletingLastPathComponent().appendingPathComponent("desktop-management-preview.png")
    let tagProjectsOutput = output.deletingLastPathComponent().appendingPathComponent("desktop-project-tags-preview.png")
    let tagProjectsNarrowOutput = output.deletingLastPathComponent().appendingPathComponent("desktop-project-tags-narrow-preview.png")
    for (destination, height, section, previewModel) in [(output, CGFloat(620), SessionWorkspaceSection.sessions, state),
        (expandedOutput, CGFloat(1000), SessionWorkspaceSection.sessions, state),
        (projectsOutput, CGFloat(620), SessionWorkspaceSection.projects, projects),
        (statisticsOutput, CGFloat(880), SessionWorkspaceSection.statistics, projects),
        (paginationOutput, CGFloat(620), SessionWorkspaceSection.sessions, indexed),
        (warningsOutput, CGFloat(620), SessionWorkspaceSection.sessions, warnings),
        (errorsOutput, CGFloat(620), SessionWorkspaceSection.sessions, errors),
        (managementOutput, CGFloat(620), SessionWorkspaceSection.sessions, managed),
        (tagProjectsOutput, CGFloat(620), SessionWorkspaceSection.projects, tagged),
        (tagProjectsNarrowOutput, CGFloat(620), SessionWorkspaceSection.projects, tagged)] {
        let width: CGFloat = destination == tagProjectsNarrowOutput ? 744 : 888
        let content = VStack(alignment: .leading, spacing: 14) {
            Text(section == .sessions ? "Codex 会话 · 模拟数据预览" : "Codex 项目与统计 · 模拟数据预览")
                .font(.system(size: 22, weight: .semibold))
            Text("生产界面 + 临时 JSONL；没有读取真实会话、没有发送模型请求。")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            SessionsContent(model: previewModel,
                initiallyExpandedMessageIDs: expanded, initialSection: section,
                initiallyExpandedWarnings: destination == warningsOutput)
        }.padding(18).frame(width: width, height: height, alignment: .topLeading)
            .background(MemoryStyle.background).foregroundStyle(MemoryStyle.text).tint(MemoryStyle.accent)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 70_000_000)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CheckFailure(message: "could not create offscreen session image")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(message: "could not encode session preview PNG")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destination)
        print("RENDER \(destination.lastPathComponent)")
    }
    guard let editedSummary = managed.filteredSessions.first else { throw CheckFailure(message: "management editor preview fixture missing") }
    let editorOutput = output.deletingLastPathComponent().appendingPathComponent("desktop-management-editor-preview.png")
    let editorContent = SessionMetadataEditor(model: managed, summary: editedSummary)
        .frame(width: 588, height: 650).background(MemoryStyle.background)
        .foregroundStyle(MemoryStyle.text).tint(MemoryStyle.accent)
    let editorHosting = NSHostingView(rootView: editorContent)
    let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 588, height: 650),
                                styleMask: .borderless, backing: .buffered, defer: false)
    editorWindow.isReleasedWhenClosed = false
    editorWindow.contentView = editorHosting
    editorHosting.frame = NSRect(x: 0, y: 0, width: 588, height: 650)
    defer { editorWindow.close() }
    editorHosting.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 70_000_000)
    editorHosting.layoutSubtreeIfNeeded()
    guard let editorBitmap = editorHosting.bitmapImageRepForCachingDisplay(in: editorHosting.bounds) else {
        throw CheckFailure(message: "could not create offscreen management editor image")
    }
    editorHosting.cacheDisplay(in: editorHosting.bounds, to: editorBitmap)
    guard let editorPNG = editorBitmap.representation(using: .png, properties: [:]) else {
        throw CheckFailure(message: "could not encode management editor preview PNG")
    }
    try editorPNG.write(to: editorOutput)
    print("RENDER \(editorOutput.lastPathComponent)")
    guard let editedProject = tagged.analytics.projects.first(where: { tagged.projectTags($0.id).count > 2 }) else {
        throw CheckFailure(message: "project tags editor preview fixture missing")
    }
    let tagsEditorOutput = output.deletingLastPathComponent().appendingPathComponent("desktop-project-tags-editor-preview.png")
    let tagsEditorContent = ProjectTagsEditor(model: tagged, project: editedProject)
        .frame(width: 540, height: 580).background(MemoryStyle.background)
        .foregroundStyle(MemoryStyle.text).tint(MemoryStyle.accent)
    let tagsEditorHosting = NSHostingView(rootView: tagsEditorContent)
    let tagsEditorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 580),
                                    styleMask: .borderless, backing: .buffered, defer: false)
    tagsEditorWindow.isReleasedWhenClosed = false
    tagsEditorWindow.contentView = tagsEditorHosting
    tagsEditorHosting.frame = NSRect(x: 0, y: 0, width: 540, height: 580)
    defer { tagsEditorWindow.close() }
    tagsEditorHosting.layoutSubtreeIfNeeded()
    try await Task.sleep(nanoseconds: 70_000_000)
    tagsEditorHosting.layoutSubtreeIfNeeded()
    guard let tagsBitmap = tagsEditorHosting.bitmapImageRepForCachingDisplay(in: tagsEditorHosting.bounds) else {
        throw CheckFailure(message: "could not create offscreen project tags editor image")
    }
    tagsEditorHosting.cacheDisplay(in: tagsEditorHosting.bounds, to: tagsBitmap)
    guard let tagsPNG = tagsBitmap.representation(using: .png, properties: [:]) else {
        throw CheckFailure(message: "could not encode project tags editor preview PNG")
    }
    try tagsPNG.write(to: tagsEditorOutput)
    print("RENDER \(tagsEditorOutput.lastPathComponent)")
}
#endif

@MainActor func checkFullTextSearchLifecycle() async throws {
    let a = summary("reuse-a"), b = summary("reuse-b", archived: true)
    let source = FixtureSource(catalogs: [.init(delay: 0, result: .success(.init(sessions: [a,b])))],
        transcripts: [a.id: [.init(delay: 0.03, result: .success(.init(summary: a,
            messages: [.init(id: "answer", kind: .assistant, text: "timeout failed")])))]])
    let state = try model(source, name: "fulltext")
    state.loadIfNeeded()
    try await waitFor({ state.hasLoaded && !state.isFiltering }, "catalog ready")
    state.searchFullText(query: "timeout", scope: .assistant, project: nil, archived: false)
    try expect(state.isSearchingFullText, "search publishes progress")
    try await waitFor({ !state.isSearchingFullText }, "fulltext completes")
    try expect(state.fullTextResult?.hits.first?.messageID == "answer", "assistant text found")
    try expect(state.fullTextResult?.totalSessions == 1, "archive filter applied")
    state.searchFullText(query: "timeout", scope: .all, project: nil, archived: true)
    state.cancelFullTextSearch()
    try await Task.sleep(nanoseconds: 60_000_000)
    try expect(!state.isSearchingFullText && state.fullTextResult == nil, "cancelled search cannot publish")
    state.searchFullText(query: "absent", scope: .all, project: nil, archived: true)
    try await waitFor({ !state.isSearchingFullText }, "new query completes")
    try expect(state.fullTextResult?.hits.isEmpty == true, "new query replaces stale matches")
    try expect(state.fullTextResult?.totalSessions == 2, "archived search included")
}

@MainActor func runChecks() async throws {
    try await checkLazyLoadAndFiltering()
    try await checkTaskResultOwnership()
    try await checkRefreshGenerations()
    try await checkTranscriptGenerations()
    try await checkRefreshDuringPendingTranscript()
    try await checkFailuresAndFreshSummary()
    try await checkFailedRefreshRestartsCancelledDetail()
    try await checkNumericBoundsAndIdentity()
    try await checkBackgroundSearchAndCachedAnalytics()
    let indexed = try await checkTranscriptIndexesAndPagination()
    let projects = try await checkProjectAnalyticsAndUnknownFilter()
    let warnings = try await checkLargeWarningPresentation()
    let errors = try await checkLongErrorPresentation()
    let state = try await checkRepositoryIntegration()
    try await checkPersistentRepositoryReopen()
    try checkChunkPoolBoundaries()
    try await checkFullTextSearchLifecycle()
    let managed = try await checkManagementPersistenceAndFiltering()
    try await checkManagementFailureAndRetry()
    try await checkManagementIdentityAndPendingQuit()
    try await checkManagementEditorBaselineConflicts()
    try await checkManagementDiscardFailedDraft()
    let tagged = try await checkProjectTagFilteringAndPersistence()
    try await checkProjectTagConflictFailureAndCancel()
    print("DESKTOP SESSION CHECKS PASSED: 24 workflows, \(assertionCount) assertions; isolated fixtures only")
    #if RENDER_SESSIONS
    if let output = ProcessInfo.processInfo.environment["GPT_DESKTOP_SESSION_RENDER_PATH"] {
        try await render(state, projects: projects, indexed: indexed, managed: managed, tagged: tagged,
                         warnings: warnings, errors: errors, to: output)
    }
    #endif
}

Task { @MainActor in
    do { try await runChecks(); exit(0) }
    catch { fputs("DESKTOP SESSION CHECK FAILED: \(error)\n", stderr); exit(1) }
}
RunLoop.main.run()
'''


def release_inputs(project: Path, render: bool) -> tuple[Path, list[Path]]:
    release = project / ".build" / "release"
    modules = release / "Modules"
    objects: list[Path] = []
    missing: list[str] = []
    stale: list[str] = []
    targets = ["GPTSessionKit"] + (["GPTMemoryCore", "GPTAnalysisKit"] if render else [])
    for target in targets:
        if not (modules / f"{target}.swiftmodule").is_file():
            missing.append(f"{target}.swiftmodule")
        for source in sorted((project / "Sources" / target).glob("*.swift")):
            artifact = release / f"{target}.build" / f"{source.name}.o"
            if not artifact.is_file():
                missing.append(artifact.name)
            elif artifact.stat().st_mtime_ns < source.stat().st_mtime_ns:
                stale.append(source.name)
            objects.append(artifact)
    if render:
        native = release / "CNative.build" / "native.c.o"
        if not native.is_file():
            missing.append(native.name)
        objects.append(native)
    if missing or stale:
        detail = "缺少产物：" + ", ".join(missing) if missing else "Release 产物早于源码：" + ", ".join(stale)
        raise RuntimeError(f"{detail}。请先构建 Release；本脚本不会自行构建项目。")
    return release, objects


def main() -> int:
    parser = argparse.ArgumentParser(description="使用临时夹具验证生产 Codex 会话桌面状态机，并可离屏渲染真实界面。")
    parser.add_argument("--render", nargs="?", const="reports/desktop-sessions-preview.png", metavar="PNG")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    output = Path(args.render).expanduser().resolve() if args.render else None
    release, objects = release_inputs(project, bool(output))
    architecture = platform.machine()
    if architecture not in {"arm64", "x86_64"}:
        raise RuntimeError(f"不支持的 macOS 架构：{architecture}")
    with tempfile.TemporaryDirectory(prefix="gpt-desktop-session-checks-") as temporary:
        directory = Path(temporary)
        main_swift = directory / "main.swift"
        main_swift.write_text(SWIFT_CHECKS, encoding="utf-8")
        executable = directory / "session-checks"
        desktop = project / "Sources" / "GPTMemoryDesktop"
        sources = [desktop / "SessionManagementModel.swift", desktop / "SessionDesktopModel.swift"]
        if output:
            sources += [desktop / "SessionViews.swift", desktop / "SessionProjectViews.swift", desktop / "SessionManagementViews.swift", desktop / "Style.swift"]
        command = ["swiftc", "-swift-version", "5", "-target", f"{architecture}-apple-macosx14.0",
                   "-module-cache-path", str(directory / "module-cache"), "-I", str(release / "Modules"),
                   "-I", str(release / "CNative.build"), "-o", str(executable)]
        if output:
            command += ["-D", "RENDER_SESSIONS"]
        command += [str(source) for source in sources] + [str(main_swift)] + [str(obj) for obj in objects]
        if output:
            command += ["-lproc", "-lsqlite3"]
        print("编译 Codex 会话桌面检查（仅使用临时夹具）", flush=True)
        subprocess.run(command, cwd=project, check=True, timeout=60)
        environment = os.environ.copy()
        environment["GPT_DESKTOP_SESSION_CHECK_DIR"] = str(directory / "fixtures")
        if output:
            environment["GPT_DESKTOP_SESSION_RENDER_PATH"] = str(output)
        subprocess.run([str(executable)], cwd=project, env=environment, check=True, timeout=20)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Codex 会话桌面检查未通过：{error}", file=sys.stderr)
        raise SystemExit(1)
