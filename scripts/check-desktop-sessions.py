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
             tokens: CodexTokenUsage = .init()) -> CodexSessionSummary {
    CodexSessionSummary(id: id, sessionID: "session-\(id)",
        fileURL: URL(fileURLWithPath: "/fixture/sessions/\(id).jsonl"),
        title: "模拟会话 \(id)", projectPath: project,
        startedAt: Date(timeIntervalSince1970: 1_791_792_000),
        updatedAt: Date(timeIntervalSince1970: 1_791_792_060), model: "mock-codex",
        messageCount: 2, toolCallCount: 1, tokens: tokens, isArchived: archived,
        searchText: "模拟用户日志\nsecond prompt \(id)")
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
    try await waitFor({ !model.isLoading && !model.isFiltering }, "catalog loader timed out")
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
    try await waitFor({ !state.isLoading && !state.isFiltering && !state.isLoadingTranscript }, "failed refresh detail recovery timed out")
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
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

#if RENDER_SESSIONS
@MainActor func render(_ state: SessionDesktopModel, projects: SessionDesktopModel, indexed: SessionDesktopModel,
                       warnings: SessionDesktopModel, errors: SessionDesktopModel, to path: String) async throws {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
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
    for (destination, height, section, previewModel) in [(output, CGFloat(620), SessionWorkspaceSection.sessions, state),
        (expandedOutput, CGFloat(1000), SessionWorkspaceSection.sessions, state),
        (projectsOutput, CGFloat(620), SessionWorkspaceSection.projects, projects),
        (statisticsOutput, CGFloat(880), SessionWorkspaceSection.statistics, projects),
        (paginationOutput, CGFloat(620), SessionWorkspaceSection.sessions, indexed),
        (warningsOutput, CGFloat(620), SessionWorkspaceSection.sessions, warnings),
        (errorsOutput, CGFloat(620), SessionWorkspaceSection.sessions, errors)] {
        let content = VStack(alignment: .leading, spacing: 14) {
            Text(section == .sessions ? "Codex 会话 · 模拟数据预览" : "Codex 项目与统计 · 模拟数据预览")
                .font(.system(size: 22, weight: .semibold))
            Text("生产界面 + 临时 JSONL；没有读取真实会话、没有发送模型请求。")
                .font(.system(size: 11)).foregroundStyle(MemoryStyle.secondary)
            SessionsContent(model: previewModel,
                initiallyExpandedMessageIDs: expanded, initialSection: section,
                initiallyExpandedWarnings: destination == warningsOutput)
        }.padding(18).frame(width: 888, height: height, alignment: .topLeading)
            .background(MemoryStyle.background).foregroundStyle(MemoryStyle.text).tint(MemoryStyle.accent)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 888, height: height)
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
}
#endif

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
    try checkChunkPoolBoundaries()
    print("DESKTOP SESSION CHECKS PASSED: 15 workflows, \(assertionCount) assertions; isolated fixtures only")
    #if RENDER_SESSIONS
    if let output = ProcessInfo.processInfo.environment["GPT_DESKTOP_SESSION_RENDER_PATH"] {
        try await render(state, projects: projects, indexed: indexed, warnings: warnings, errors: errors, to: output)
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
        sources = [desktop / "SessionDesktopModel.swift"]
        if output:
            sources += [desktop / "SessionViews.swift", desktop / "SessionProjectViews.swift", desktop / "Style.swift"]
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
