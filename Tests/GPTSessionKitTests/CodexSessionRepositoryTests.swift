import Foundation
import XCTest
@testable import GPTSessionKit

final class CodexSessionRepositoryTests: XCTestCase {
    func testMirroredMessagesToolPairingAndLatestCumulativeTokens() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = try fixture.write([
            metadata(),
            record("response_item", ["type":"message", "role":"user", "content":[["type":"input_text", "text":"Question alpha"]]], time: 1),
            record("event_msg", ["type":"user_message", "message":"Question alpha"], time: 1),
            record("response_item", ["type":"function_call", "name":"exec_command", "call_id":"call-1", "arguments":"{\"cmd\":\"synthetic\"}"], time: 2),
            record("response_item", ["type":"function_call_output", "call_id":"call-1", "output":"only-tool-search-marker"], time: 3),
            record("event_msg", ["type":"agent_message", "message":"only-assistant-search-marker"], time: 4),
            record("response_item", ["type":"message", "role":"assistant", "content":[["type":"output_text", "text":"only-assistant-search-marker"]]], time: 4),
            token(["input_tokens":100, "cached_input_tokens":30, "output_tokens":50, "reasoning_output_tokens":40, "total_tokens":150], time: 5),
            token(["input_tokens":200, "cached_input_tokens":80, "output_tokens":70, "reasoning_output_tokens":50, "total_tokens":270], time: 6),
            token(["input_tokens":200, "cached_input_tokens":80, "output_tokens":70, "reasoning_output_tokens":50, "total_tokens":270], time: 7)
        ])
        let repository = CodexSessionRepository(rootURL: fixture.root)
        let catalog = try repository.loadCatalog()
        let summary = try XCTUnwrap(catalog.sessions.first)
        XCTAssertEqual(summary.fileURL, file)
        XCTAssertEqual(summary.title, "Question alpha")
        XCTAssertEqual(summary.messageCount, 2)
        XCTAssertEqual(summary.toolCallCount, 1)
        XCTAssertEqual(summary.tokens.input, 200)
        XCTAssertEqual(summary.tokens.cachedInput, 80)
        XCTAssertEqual(summary.tokens.output, 70)
        XCTAssertEqual(summary.tokens.reasoningOutput, 50)
        XCTAssertEqual(summary.tokens.effectiveTotal, 270)
        XCTAssertTrue(summary.matches(query: "alpha synthetic"))
        XCTAssertFalse(summary.matches(query: "only-assistant-search-marker"))
        XCTAssertFalse(summary.matches(query: "only-tool-search-marker"))
        let transcript = try repository.loadTranscript(for: summary)
        XCTAssertEqual(transcript.messages.count, 4)
        XCTAssertEqual(transcript.messages.map(\.kind), [.user,.toolCall,.toolResult,.assistant])
        XCTAssertEqual(transcript.messages[2].toolName, "exec_command")
        XCTAssertEqual(transcript.messages[2].callID, "call-1")
        XCTAssertTrue(transcript.warnings.isEmpty)
    }

    func testNewCompletedItemsRepeatedPromptsAndPlaintextReasoning() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.write([
            metadata(),
            record("response_item", ["type":"message", "role":"user", "content":[["type":"input_text", "text":"Repeat"]]], time: 1),
            record("event_msg", ["type":"item_completed", "item":["type":"UserMessage", "id":"u1", "content":[["type":"text", "text":"Repeat"]]]], time: 1),
            record("response_item", ["type":"message", "role":"user", "content":[["type":"input_text", "text":"Repeat"]]], time: 2),
            record("event_msg", ["type":"item_completed", "item":["type":"UserMessage", "id":"u2", "content":[["type":"text", "text":"Repeat"]]]], time: 2),
            record("response_item", ["type":"reasoning", "encrypted_content":"SECRET-CIPHERTEXT", "summary":[["type":"summary_text", "text":"Recorded summary"]]], time: 3),
            record("event_msg", ["type":"item_completed", "item":["type":"AgentMessage", "id":"a1", "content":[["type":"Text", "text":"Answer"]]]], time: 4),
            record("turn_context", ["model":"new-model", "cwd":"/synthetic/new-project"])
        ])
        let repository = CodexSessionRepository(rootURL: fixture.root)
        let summary = try XCTUnwrap(repository.loadCatalog().sessions.first)
        let transcript = try repository.loadTranscript(for: summary)
        XCTAssertEqual(transcript.messages.map(\.kind), [.user,.user,.reasoning,.assistant])
        XCTAssertEqual(summary.messageCount, 3)
        XCTAssertEqual(summary.model, "new-model")
        XCTAssertEqual(summary.projectPath, "/synthetic/new-project")
        XCTAssertEqual(transcript.messages[2].text, "Recorded summary")
        XCTAssertFalse(transcript.messages.contains { $0.text.contains("SECRET-CIPHERTEXT") })
        XCTAssertNil(summary.tokens.total)
    }

    func testInjectedInstructionsDoNotBecomeTitleAndRenamesAreReadOnly() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let file = try fixture.write([
            metadata(), record("response_item", ["type":"message", "role":"user", "content":[["type":"input_text", "text":"# AGENTS.md instructions\nSYSTEM-SEARCH-MARKER"]]]),
            record("event_msg", ["type":"user_message", "message":"真人问题\n更多细节"], time: 1)
        ])
        let original = try Data(contentsOf: file)
        let repository = CodexSessionRepository(rootURL: fixture.root)
        let summary = try XCTUnwrap(repository.loadCatalog().sessions.first)
        XCTAssertEqual(summary.title, "真人问题")
        XCTAssertFalse(summary.matches(query: "SYSTEM-SEARCH-MARKER"))
        XCTAssertEqual(try repository.loadTranscript(for: summary).messages.first?.kind, .system)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: record("event_msg", ["type":"thread_name_updated", "thread_name":"已记录的标题"]).data(using: .utf8)! + Data([10]))
        try handle.close()
        XCTAssertEqual(try repository.loadCatalog().sessions.first?.title, "已记录的标题")
    }

    func testTruncatedFinalLineAndMissingMetadataRetainPartialTranscriptAndWarningsOnCacheHit() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let file = try fixture.write([record("event_msg", ["type":"user_message", "message":"Recovered partial"]), "{\"type\":"], trailingNewline: false)
        let repository = CodexSessionRepository(rootURL: fixture.root)
        let first = try repository.loadCatalog()
        XCTAssertEqual(first.sessions.count, 1)
        XCTAssertTrue(first.warnings.contains { $0.contains("末行") })
        XCTAssertTrue(first.warnings.contains { $0.contains("session_meta") })
        XCTAssertEqual(first, try repository.loadCatalog())
        let transcript = try repository.loadTranscript(for: XCTUnwrap(first.sessions.first))
        XCTAssertEqual(transcript.messages.count, 1)
        XCTAssertEqual(transcript.summary.sessionID, file.deletingPathExtension().lastPathComponent)
    }

    func testArchivedAndActiveSourcesSearchAndMissingUsageStayUnknown() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.write([metadata("active"), token(["input_tokens":10,"output_tokens":3,"reasoning_output_tokens":2])])
        _ = try fixture.write([metadata("archived"), record("event_msg", ["type":"user_message","message":"Archived request"])], name:"archived.jsonl", archived:true)
        let catalog = try CodexSessionRepository(rootURL: fixture.root).loadCatalog()
        XCTAssertEqual(catalog.sessions.count, 2)
        XCTAssertEqual(catalog.sessions.filter(\.isArchived).count, 1)
        XCTAssertEqual(catalog.aggregateTokens.effectiveTotal, 13)
        XCTAssertEqual(catalog.sessionsWithRecordedUsage, 1)
        XCTAssertNil(catalog.sessions.first { $0.sessionID == "archived" }?.tokens.input)
    }

    func testIncrementalFallbackDeduplicatesIdentityAndDoesNotInventUnknownTotals() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let usage = ["input_tokens":10,"output_tokens":2,"cached_input_tokens":3,"reasoning_output_tokens":1,"total_tokens":12]
        let increment = record("event_msg", ["type":"token_count", "info":["last_token_usage":usage]], time:1)
        _ = try fixture.write([metadata(),increment,increment,record("event_msg", ["type":"token_count", "info":["last_token_usage":usage]], time:2)])
        let repository = CodexSessionRepository(rootURL: fixture.root)
        let catalog = try repository.loadCatalog()
        XCTAssertEqual(catalog.aggregateTokens.total, 24)
        XCTAssertTrue(catalog.warnings.contains { $0.contains("不能保证完整") })
        _ = try fixture.write([metadata("unknown"), record("event_msg", ["type":"token_count", "info":["last_token_usage":usage]], time:nil)], name:"unknown.jsonl")
        let unknown = try XCTUnwrap(repository.loadCatalog().sessions.first { $0.sessionID == "unknown" })
        XCTAssertNil(unknown.tokens.total)
        XCTAssertNil(unknown.tokens.input)
    }

    func testTokenValidationAndCumulativeResetDoNotDoubleCount() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.write([metadata(),token(["input_tokens":100,"output_tokens":10,"total_tokens":110]),
                               token(["input_tokens":20,"output_tokens":5,"total_tokens":25,"cached_input_tokens":30,"reasoning_output_tokens":8])])
        let catalog = try CodexSessionRepository(rootURL: fixture.root).loadCatalog()
        XCTAssertEqual(catalog.aggregateTokens.total, 25)
        XCTAssertNil(catalog.aggregateTokens.cachedInput)
        XCTAssertNil(catalog.aggregateTokens.reasoningOutput)
        XCTAssertTrue(catalog.warnings.contains { $0.contains("重置") })
        _ = try fixture.write([metadata("invalid"), token(["input_tokens":-1,"output_tokens":2.5,"total_tokens":true])], name:"invalid.jsonl")
        let invalid = try XCTUnwrap(CodexSessionRepository(rootURL: fixture.root).loadCatalog().sessions.first { $0.sessionID == "invalid" })
        XCTAssertNil(invalid.tokens.total)
        XCTAssertNil(invalid.tokens.input)
        XCTAssertNil(invalid.tokens.output)
    }

    func testFileMessageLineAndCatalogBudgetsAreVisibleAndDoNotLoseValidLines() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.write([metadata(), record("event_msg", ["type":"user_message", "message":String(repeating:"x",count:2_000)]),
                               record("event_msg", ["type":"user_message", "message":"Valid after oversized line"]),
                               record("event_msg", ["type":"agent_message", "message":"Second message"]),
                               token(["input_tokens":10,"output_tokens":5,"total_tokens":15])])
        let limits = SessionReadLimits(maximumLineBytes:512, maximumMessages:1)
        let repository = CodexSessionRepository(rootURL: fixture.root,limits:limits)
        let catalog = try repository.loadCatalog()
        let summary = try XCTUnwrap(catalog.sessions.first)
        XCTAssertEqual(summary.title,"Valid after oversized line")
        XCTAssertEqual(summary.messageCount,1)
        XCTAssertEqual(summary.tokens.total,15)
        XCTAssertTrue(catalog.warnings.contains { $0.contains("单行") })
        XCTAssertTrue(catalog.warnings.contains { $0.contains("消息达到") })
        let small = CodexSessionRepository(rootURL:fixture.root,limits:.init(maximumFileBytes:200))
        XCTAssertTrue(try small.loadCatalog().warnings.contains { $0.contains("大小上限") })
        let budget = CodexSessionRepository(rootURL:fixture.root,limits:.init(maximumCatalogReadBytes:200))
        XCTAssertTrue(try budget.loadCatalog().warnings.contains { $0.contains("大小上限") })
    }

    func testSymlinksAndOutsideTranscriptURLsCannotBeRead() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let external = try Fixture(); defer { external.remove() }
        let outside = try external.write([metadata("outside")])
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("sessions"),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("sessions/link.jsonl"),withDestinationURL:outside)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("sessions/folder"),withDestinationURL:outside.deletingLastPathComponent())
        let repository = CodexSessionRepository(rootURL:fixture.root)
        XCTAssertTrue(try repository.loadCatalog().sessions.isEmpty)
        let summary = CodexSessionSummary(id:"outside",sessionID:"outside",fileURL:outside,title:"outside")
        XCTAssertThrowsError(try repository.loadTranscript(for:summary))
        let linked = CodexSessionSummary(id:"linked",sessionID:"linked",fileURL:fixture.root.appendingPathComponent("sessions/link.jsonl"),title:"linked")
        XCTAssertThrowsError(try repository.loadTranscript(for:linked))
    }

    func testCatalogCacheInvalidatesOnAppendAndMissingRootsAreEmpty() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let file = try fixture.write([metadata(),record("event_msg",["type":"user_message","message":"Initial"]),token(["total_tokens":12])])
        let repository = CodexSessionRepository(rootURL:fixture.root)
        let first = try repository.loadCatalog()
        XCTAssertEqual(first,try repository.loadCatalog())
        let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd()
        try handle.write(contentsOf:(token(["total_tokens":24])+"\n").data(using:.utf8)!)
        try handle.close()
        let second = try repository.loadCatalog()
        XCTAssertEqual(second.sessions.first?.id,first.sessions.first?.id)
        XCTAssertEqual(second.aggregateTokens.total,24)
        XCTAssertNotEqual(first.aggregateTokens.total,second.aggregateTokens.total)
        let missing = try CodexSessionRepository(rootURL:fixture.root.appendingPathComponent("missing")).loadCatalog()
        XCTAssertTrue(missing.sessions.isEmpty)
        XCTAssertFalse(missing.warnings.isEmpty)
    }

    func testDuplicateSessionIDAcrossArchiveAndActiveCountsLatestOnce() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let older = try fixture.write([metadata("same-id"),token(["total_tokens":12])])
        let newer = try fixture.write([metadata("same-id"),token(["total_tokens":24])],name:"archived-copy.jsonl",archived:true)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:10)],ofItemAtPath:older.path)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:20)],ofItemAtPath:newer.path)
        let repository = CodexSessionRepository(rootURL:fixture.root)
        let catalog = try repository.loadCatalog()
        XCTAssertEqual(catalog.sessions.count,1)
        XCTAssertEqual(catalog.sessions.first?.fileURL,newer)
        XCTAssertEqual(catalog.aggregateTokens.total,24)
        XCTAssertTrue(catalog.warnings.contains { $0.contains("副本") })
        XCTAssertEqual(catalog,try repository.loadCatalog())
    }

    func testUnpairedIdenticalMessagesAcrossExplicitTurnsAreNotDeduplicated() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.write([metadata(),record("turn_context",["turn_id":"one"]),
                               record("event_msg",["type":"user_message","message":"Repeat"],time:1),
                               record("turn_context",["turn_id":"two"]),
                               record("response_item",["type":"message","role":"user","content":[["type":"input_text","text":"Repeat"]]],time:2)])
        let repository = CodexSessionRepository(rootURL:fixture.root)
        let summary = try XCTUnwrap(repository.loadCatalog().sessions.first)
        XCTAssertEqual(summary.messageCount,2)
        XCTAssertEqual(try repository.loadTranscript(for:summary).messages.count,2)
    }

    func testMessageLimitsCountGraphemesRatherThanUTF8Bytes() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let short = String(repeating: "👩‍💻", count: 17000)
        let long = String(repeating: "e\u{301}", count: 65537)
        _ = try fixture.write([metadata(), record("event_msg", ["type": "agent_message", "message": short]), record("event_msg", ["type": "agent_message", "message": long], time: 1)])
        let repository = CodexSessionRepository(rootURL: fixture.root)
        let summary = try XCTUnwrap(repository.loadCatalog().sessions.first)
        let transcript = try repository.loadTranscript(for: summary)
        XCTAssertEqual(transcript.messages.count, 2)
        XCTAssertEqual(transcript.messages[0].text, short)
        XCTAssertEqual(transcript.messages[1].text.count, 65536)
        XCTAssertEqual(transcript.messages[1].text, String(long.prefix(65536)))
        XCTAssertTrue(transcript.warnings.contains { $0.contains("截断展示") })
    }

    func testLongPromptSearchUsesFullGlobalBudgetAndWarnsOnTruncation() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.write([metadata(),record("event_msg",["type":"user_message","message":String(repeating:"a",count:4_200)+"needle"])])
        let full = try CodexSessionRepository(rootURL:fixture.root).loadCatalog()
        XCTAssertTrue(try XCTUnwrap(full.sessions.first).matches(query:"needle"))
        XCTAssertTrue(full.warnings.isEmpty)
        let limited = try CodexSessionRepository(rootURL:fixture.root,limits:.init(maximumSearchCharacters:4_096)).loadCatalog()
        let summary = try XCTUnwrap(limited.sessions.first)
        XCTAssertFalse(summary.matches(query:"needle"))
        XCTAssertEqual(summary.searchText.count,4_096)
        XCTAssertTrue(limited.warnings.contains { $0.contains("搜索索引") })
    }

    func testNativeWebSearchIsVisibleAndCountedAsTool() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.write([metadata(),record("response_item",["type":"web_search_call","id":"ws1","action":["type":"search","query":"swift session viewer"]])])
        let repository = CodexSessionRepository(rootURL:fixture.root)
        let summary = try XCTUnwrap(repository.loadCatalog().sessions.first)
        let transcript = try repository.loadTranscript(for:summary)
        XCTAssertEqual(summary.toolCallCount,1)
        XCTAssertEqual(transcript.messages.first?.kind,.toolCall)
        XCTAssertEqual(transcript.messages.first?.toolName,"web_search")
        XCTAssertEqual(transcript.messages.first?.callID,"ws1")
        XCTAssertTrue(try XCTUnwrap(transcript.messages.first?.text).contains("swift session viewer"))
        XCTAssertFalse(summary.matches(query:"swift session viewer"))
    }

    func testTitleIndexOverridesInlineRenameAndRefreshesCachedSummaryWithoutRolloutChanges() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let file = try fixture.write([metadata("s1"),record("event_msg",["type":"user_message","message":"hi"]),
                                      record("event_msg",["type":"thread_name_updated","thread_name":"内联标题"])])
        let original = try Data(contentsOf:file)
        let repository = CodexSessionRepository(rootURL:fixture.root)
        let base = try XCTUnwrap(repository.loadCatalog().sessions.first)
        XCTAssertEqual(base.title,"内联标题")
        let index = fixture.root.appendingPathComponent("session_index.jsonl")
        try Data((titleRecord("s1","重构支付服务")+"\n").utf8).write(to:index)
        let first = try XCTUnwrap(repository.loadCatalog().sessions.first)
        XCTAssertEqual(first.title,"重构支付服务")
        XCTAssertTrue(first.matches(query:"重构支付"))
        XCTAssertGreaterThan(repository.lastReadMetrics.titleIndexBytesRead,0)
        XCTAssertEqual(try repository.loadCatalog().sessions.first?.title,"重构支付服务")
        XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead,0)
        XCTAssertEqual(repository.lastReadMetrics.titleIndexBytesRead,0)
        XCTAssertEqual(try repository.loadTranscript(for:first).summary.title,"重构支付服务")
        XCTAssertEqual(repository.lastReadMetrics.titleIndexBytesRead,0)
        let handle = try FileHandle(forWritingTo:index); try handle.seekToEnd()
        try handle.write(contentsOf:Data((titleRecord("s1","二次命名")+"\n").utf8)); try handle.close()
        let refreshed = try XCTUnwrap(repository.loadCatalog().sessions.first)
        XCTAssertEqual(refreshed.title,"二次命名")
        XCTAssertGreaterThan(repository.lastReadMetrics.titleIndexBytesRead,0)
        XCTAssertEqual(try repository.loadTranscript(for:first).summary.title,"二次命名")
        XCTAssertEqual(refreshed.id,base.id)
        XCTAssertEqual(try Data(contentsOf:file),original)
        try FileManager.default.removeItem(at:index)
        XCTAssertEqual(try repository.loadCatalog().sessions.first?.title,"内联标题")
        XCTAssertEqual(try repository.loadTranscript(for:refreshed).summary.title,"内联标题")
    }

    func testTitleIndexSymlinkIsIgnoredAndCannotBePassedAsTranscript() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let external = try Fixture(); defer { external.remove() }
        _ = try fixture.write([metadata("s1"),record("event_msg",["type":"user_message","message":"Local fallback"])])
        let outside = external.root.appendingPathComponent("session_index.jsonl")
        try Data((titleRecord("s1","EXTERNAL-TITLE-MARKER")+"\n").utf8).write(to:outside)
        let index = fixture.root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createSymbolicLink(at:index,withDestinationURL:outside)
        let repository = CodexSessionRepository(rootURL:fixture.root)
        let catalog = try repository.loadCatalog()
        let summary = try XCTUnwrap(catalog.sessions.first)
        XCTAssertEqual(summary.title,"Local fallback")
        XCTAssertFalse(summary.matches(query:"EXTERNAL-TITLE-MARKER"))
        XCTAssertTrue(catalog.warnings.contains { $0.contains("标题索引") && $0.contains("符号链接") })
        XCTAssertEqual(try repository.loadTranscript(for:summary).summary.title,"Local fallback")
        let invalid = CodexSessionSummary(id:"index",sessionID:"s1",fileURL:index,title:"index")
        XCTAssertThrowsError(try repository.loadTranscript(for:invalid))
    }

    func testTitleIndexBudgetsOversizedRecordsAndUnfinishedFinalLineRemainVisible() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.write([metadata("s1"),record("event_msg",["type":"user_message","message":"Fallback"])])
        let index = fixture.root.appendingPathComponent("session_index.jsonl")
        try Data((titleRecord("s1","Known title")+"\n"+titleRecord("unrelated",String(repeating:"x",count:2_000))+"\n").utf8).write(to:index)
        let bounded = try CodexSessionRepository(rootURL:fixture.root,limits:.init(maximumFileBytes:1_024)).loadCatalog()
        XCTAssertEqual(bounded.sessions.first?.title,"Known title")
        XCTAssertTrue(bounded.warnings.contains { $0.contains("标题索引读取达到大小上限") })
        try Data((titleRecord("s1","First")+"\n"+titleRecord("unrelated",String(repeating:"x",count:2_000))+"\n"+titleRecord("s1","Last")+"\n").utf8).write(to:index)
        let oversized = try CodexSessionRepository(rootURL:fixture.root,limits:.init(maximumLineBytes:256)).loadCatalog()
        XCTAssertEqual(oversized.sessions.first?.title,"Last")
        XCTAssertTrue(oversized.warnings.contains { $0.contains("标题索引单行") })
        try Data((titleRecord("s1","Complete title")+"\n{").utf8).write(to:index)
        let incomplete = try CodexSessionRepository(rootURL:fixture.root).loadCatalog()
        XCTAssertEqual(incomplete.sessions.first?.title,"Complete title")
        XCTAssertTrue(incomplete.warnings.contains { $0.contains("标题索引末行") })
    }

    func testSummaryOnlyParsingMatchesDetailsAcrossPairingWindowAndBudgets() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var lines = [metadata()]
        for index in 0..<40 {
            lines.append(record("turn_context", ["turn_id":"turn-\(index)"]))
            lines.append(record("response_item", ["type":"message", "role":"user", "id":"u-\(index)",
                                                   "content":[["type":"input_text", "text":"问题\(index) 👩‍💻" + String(repeating:"中",count:80)]]],time:1))
            lines.append(record("event_msg", ["type":"user_message", "id":"u-\(index)",
                                               "message":"配对后问题\(index) 👩‍💻" + String(repeating:"文",count:80)],time:1))
            lines.append(record("response_item", ["type":"function_call", "name":"fixture", "call_id":"c-\(index)", "arguments":["synthetic":true]],time:2))
            lines.append(record("response_item", ["type":"function_call_output", "call_id":"c-\(index)", "output":String(repeating:"Synthetic output ",count:200)],time:3))
            lines.append(record("event_msg", ["type":"agent_message", "message":"Answer \(index)"],time:4))
            lines.append(record("response_item", ["type":"message", "role":"assistant", "content":[["type":"output_text", "text":"Answer \(index)"]]],time:4))
        }
        lines.append(token(["total_tokens":555]))
        _ = try fixture.write(lines)
        for limit in [10, 75, 1_000] {
            let repository = CodexSessionRepository(rootURL:fixture.root,
                limits:.init(maximumMessages:limit,maximumSearchCharacters:650))
            let catalog = try repository.loadCatalog()
            let summary = try XCTUnwrap(catalog.sessions.first)
            let detail = try repository.loadTranscript(for:summary)
            XCTAssertEqual(summary,detail.summary)
            XCTAssertEqual(summary.messageCount,detail.messages.filter { $0.kind == .user || $0.kind == .assistant }.count)
            XCTAssertEqual(summary.toolCallCount,detail.messages.filter { $0.kind == .toolCall }.count)
            XCTAssertTrue(detail.summary.title.hasPrefix("配对后问题0"))
            XCTAssertEqual(summary.tokens.total,555)
            XCTAssertLessThanOrEqual(summary.searchText.count,650)
        }
    }

    func testTranscriptLRUReusesBytesEvictsOldestAndInvalidatesAppends() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var expectedBytes = 0
        for index in 0..<3 {
            let file = try fixture.write([metadata("s\(index)"),record("event_msg",["type":"user_message","message":"Prompt \(index)"]),token(["total_tokens":index+10])],name:"\(index).jsonl")
            expectedBytes += try Data(contentsOf:file).count
        }
        let repository = CodexSessionRepository(rootURL:fixture.root,limits:.init(maximumCachedTranscripts:2))
        let catalog = try repository.loadCatalog()
        XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead,expectedBytes)
        XCTAssertEqual(repository.lastReadMetrics.parsedRolloutFiles,3)
        XCTAssertEqual(catalog,try repository.loadCatalog())
        XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead,0)
        XCTAssertEqual(repository.lastReadMetrics.cachedRolloutFiles,3)
        let summaries = catalog.sessions.sorted { $0.sessionID < $1.sessionID }
        let first = try repository.loadTranscript(for:summaries[0])
        XCTAssertGreaterThan(repository.lastReadMetrics.rolloutBytesRead,0)
        XCTAssertEqual(first,try repository.loadTranscript(for:summaries[0]))
        XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead,0)
        XCTAssertEqual(repository.lastReadMetrics.cachedRolloutFiles,1)
        _ = try repository.loadTranscript(for:summaries[1])
        _ = try repository.loadTranscript(for:summaries[0]) // Touch s0; s1 becomes least recent.
        _ = try repository.loadTranscript(for:summaries[2])
        _ = try repository.loadTranscript(for:summaries[0])
        XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead,0)
        _ = try repository.loadTranscript(for:summaries[1])
        XCTAssertGreaterThan(repository.lastReadMetrics.rolloutBytesRead,0)
        let handle = try FileHandle(forWritingTo:summaries[1].fileURL); try handle.seekToEnd()
        try handle.write(contentsOf:Data((token(["total_tokens":100])+"\n").utf8)); try handle.close()
        XCTAssertEqual(try repository.loadTranscript(for:summaries[1]).summary.tokens.total,100)
        XCTAssertGreaterThan(repository.lastReadMetrics.rolloutBytesRead,0)
        XCTAssertEqual(try repository.loadCatalog().sessions.first { $0.sessionID == "s1" }?.tokens.total,100)
    }

    func testOversizedDetailIsNotCachedAndCachedParentSymlinkIsRejected() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let file = try fixture.write([metadata(),record("event_msg",["type":"user_message","message":String(repeating:"large",count:500)])])
        let bounded = CodexSessionRepository(rootURL:fixture.root,limits:.init(maximumCachedTranscriptBytes:256))
        let summary = try XCTUnwrap(bounded.loadCatalog().sessions.first)
        _ = try bounded.loadTranscript(for:summary)
        _ = try bounded.loadTranscript(for:summary)
        XCTAssertGreaterThan(bounded.lastReadMetrics.rolloutBytesRead,0)
        let repository = CodexSessionRepository(rootURL:fixture.root)
        _ = try repository.loadTranscript(for:summary)
        _ = try repository.loadTranscript(for:summary)
        XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead,0)
        let parent = file.deletingLastPathComponent()
        let renamed = parent.deletingLastPathComponent().appendingPathComponent("moved")
        try FileManager.default.moveItem(at:parent,to:renamed)
        try FileManager.default.createSymbolicLink(at:parent,withDestinationURL:renamed)
        XCTAssertThrowsError(try repository.loadTranscript(for:summary))
        XCTAssertTrue(try repository.loadCatalog().sessions.isEmpty)
    }

    func testSearchReadsPreserveDetailLRUWithoutRetainingScannedTranscripts() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        for index in 0..<3 {
            _ = try fixture.write([metadata("s\(index)"),
                record("event_msg", ["type":"user_message", "message":"Prompt \(index)"])],
                name: "\(index).jsonl")
        }
        let repository = CodexSessionRepository(rootURL: fixture.root,
            limits: .init(maximumCachedTranscripts: 2))
        let summaries = try repository.loadCatalog().sessions.sorted { $0.sessionID < $1.sessionID }
        let first = try repository.loadTranscript(for: summaries[0])
        let second = try repository.loadTranscript(for: summaries[1])
        XCTAssertEqual(try repository.loadTranscriptForSearch(for: summaries[0]), first)
        XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead, 0)
        let scanned = try repository.loadTranscriptForSearch(for: summaries[2])
        XCTAssertGreaterThan(repository.lastReadMetrics.rolloutBytesRead, 0)
        XCTAssertEqual(try repository.loadTranscriptForSearch(for: summaries[2]), scanned)
        XCTAssertGreaterThan(repository.lastReadMetrics.rolloutBytesRead, 0)
        _ = try repository.loadTranscript(for: summaries[2])
        XCTAssertEqual(try repository.loadTranscript(for: summaries[1]), second)
        XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead, 0)
        _ = try repository.loadTranscript(for: summaries[0])
        XCTAssertGreaterThan(repository.lastReadMetrics.rolloutBytesRead, 0)
    }

    func testFastUTCTimestampsKeepFractionalAndOffsetDateSemantics() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let timestamps = ["2024-02-29T23:59:59Z", "2026-10-12T01:02:03.123Z",
                          "2026-10-12T01:02:03.123456789Z", "2026-10-12T01:02:03+02:00"]
        var lines = [metadata()]
        for (index, timestamp) in timestamps.enumerated() {
            let value:[String:Any] = ["type":"event_msg","timestamp":timestamp,
                "payload":["type":"user_message","message":"Date \(index)"]]
            lines.append(String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self))
        }
        _ = try fixture.write(lines)
        let repository = CodexSessionRepository(rootURL:fixture.root)
        let summary = try XCTUnwrap(repository.loadCatalog().sessions.first)
        let detail = try repository.loadTranscript(for:summary)
        XCTAssertEqual(detail.messages.count,timestamps.count)
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for (index,timestamp) in timestamps.enumerated() {
            let expected = try XCTUnwrap(fractional.date(from:timestamp) ?? plain.date(from:timestamp))
            let actual = try XCTUnwrap(detail.messages[index].timestamp)
            // Foundation's formatter rounds beyond milliseconds on some macOS
            // versions; accepting sub-millisecond precision preserves ordering.
            XCTAssertTrue(abs(actual.timeIntervalSince(expected)) < 0.001)
        }
    }

    func testSameSizeAndMtimeReplacementInvalidatesCatalogTranscriptAndTitleCaches() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let first = [metadata("s1"),record("event_msg",["type":"user_message","message":"First"]),token(["total_tokens":11])]
        let replacement = [metadata("s1"),record("event_msg",["type":"user_message","message":"Later"]),token(["total_tokens":22])]
        let file = try fixture.write(first)
        let fixedDate = Date(timeIntervalSince1970:100)
        try FileManager.default.setAttributes([.modificationDate:fixedDate],ofItemAtPath:file.path)
        let repository = CodexSessionRepository(rootURL:fixture.root)
        let summary = try XCTUnwrap(repository.loadCatalog().sessions.first)
        XCTAssertEqual(try repository.loadTranscript(for:summary).summary.tokens.total,11)
        let originalBytes = try Data(contentsOf:file).count
        try Data((replacement.joined(separator:"\n")+"\n").utf8).write(to:file,options:.atomic)
        XCTAssertEqual(try Data(contentsOf:file).count,originalBytes)
        try FileManager.default.setAttributes([.modificationDate:fixedDate],ofItemAtPath:file.path)
        XCTAssertEqual(try repository.loadCatalog().sessions.first?.title,"Later")
        XCTAssertEqual(try repository.loadTranscript(for:summary).summary.tokens.total,22)
        let originalInode = try FileManager.default.attributesOfItem(atPath:file.path)[.systemFileNumber] as? NSNumber
        let handle = try FileHandle(forWritingTo:file)
        try handle.truncate(atOffset:0)
        try handle.write(contentsOf:Data((replacement.joined(separator:"\n")+"\n").replacingOccurrences(of:"Later",with:"Third").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate:fixedDate],ofItemAtPath:file.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:file.path)[.systemFileNumber] as? NSNumber,originalInode)
        XCTAssertEqual(try repository.loadCatalog().sessions.first?.title,"Third")
        XCTAssertEqual(try repository.loadTranscript(for:summary).summary.title,"Third")
        let index = fixture.root.appendingPathComponent("session_index.jsonl")
        try Data((titleRecord("s1","One")+"\n").utf8).write(to:index)
        let indexDate = Date(timeIntervalSince1970:200)
        try FileManager.default.setAttributes([.modificationDate:indexDate],ofItemAtPath:index.path)
        XCTAssertEqual(try repository.loadCatalog().sessions.first?.title,"One")
        try Data((titleRecord("s1","Two")+"\n").utf8).write(to:index,options:.atomic)
        try FileManager.default.setAttributes([.modificationDate:indexDate],ofItemAtPath:index.path)
        XCTAssertEqual(try repository.loadCatalog().sessions.first?.title,"Two")
        XCTAssertEqual(try repository.loadTranscript(for:summary).summary.title,"Two")
    }

    func testSmallCatalogBudgetResumesPartialFileRatherThanRereadingPrefix() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let file = try fixture.write([metadata("large"),record("event_msg",["type":"user_message","message":String(repeating:"合成内容",count:120)]),token(["total_tokens":123])])
        _ = try fixture.write([metadata("small"),token(["total_tokens":7])],name:"small.jsonl")
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:20)],ofItemAtPath:file.path)
        let budget = 256
        let repository = CodexSessionRepository(rootURL:fixture.root,limits:.init(maximumCatalogReadBytes:budget))
        var catalog = SessionCatalog()
        var cumulativeBytes = 0
        var refreshCount = 0
        for _ in 0..<20 {
            refreshCount += 1
            catalog = try repository.loadCatalog()
            cumulativeBytes += repository.lastReadMetrics.rolloutBytesRead
            XCTAssertLessThanOrEqual(repository.lastReadMetrics.rolloutBytesRead,budget+1)
            if catalog.sessions.count == 2, catalog.aggregateTokens.total == 130 { break }
        }
        XCTAssertEqual(catalog.sessions.count,2)
        XCTAssertEqual(catalog.aggregateTokens.total,130)
        XCTAssertFalse(catalog.warnings.contains { $0.contains("大小上限") || $0.contains("session_meta") })
        // EOF probes may reread a single byte; repeated prefixes must never dominate I/O.
        let bytes = try FileManager.default.contentsOfDirectory(at:file.deletingLastPathComponent(),includingPropertiesForKeys:nil)
            .reduce(0) { $0 + (try Data(contentsOf:$1).count) }
        XCTAssertLessThanOrEqual(cumulativeBytes,bytes+20)
        print("SESSION_BUDGET_CHECK refreshes=\(refreshCount) logBytes=\(bytes) bytesRead=\(cumulativeBytes)")
        XCTAssertEqual(catalog,try repository.loadCatalog())
        XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead,0)
    }

    func testChangedFileDiscardsCatalogContinuationRatherThanMixingRevisions() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let file = try fixture.write([metadata("first"),record("event_msg",["type":"user_message","message":String(repeating:"Old fixture ",count:100)]),token(["total_tokens":11])])
        let fixed = Date(timeIntervalSince1970:100)
        try FileManager.default.setAttributes([.modificationDate:fixed],ofItemAtPath:file.path)
        let repository = CodexSessionRepository(rootURL:fixture.root,limits:.init(maximumCatalogReadBytes:256))
        _ = try repository.loadCatalog()
        let original = try String(contentsOf:file,encoding:.utf8)
        let changed = original.replacingOccurrences(of:"first",with:"other")
            .replacingOccurrences(of:"Old fixture",with:"New fixture")
            .replacingOccurrences(of:"total_tokens\":11",with:"total_tokens\":22")
        XCTAssertEqual(original.utf8.count,changed.utf8.count)
        try Data(changed.utf8).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.modificationDate:fixed],ofItemAtPath:file.path)
        var catalog = SessionCatalog()
        for _ in 0..<20 {
            catalog = try repository.loadCatalog()
            if catalog.aggregateTokens.total == 22 { break }
        }
        let final = try XCTUnwrap(catalog.sessions.first)
        XCTAssertEqual(final.sessionID,"other")
        XCTAssertTrue(final.title.hasPrefix("New fixture"))
        XCTAssertFalse(final.searchText.contains("Old fixture"))
        XCTAssertEqual(final.tokens.total,22)
        XCTAssertTrue(catalog.warnings.isEmpty)
        XCTAssertEqual(catalog,try repository.loadCatalog())
        XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead,0)
    }

    func testCancelledCatalogAndTranscriptReadsDoNotPerformIOOrReplaceCaches() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try fixture.write([metadata(),token(["total_tokens":11])])
        let repository = CodexSessionRepository(rootURL:fixture.root)
        let catalog = try repository.loadCatalog()
        let summary = try XCTUnwrap(catalog.sessions.first)
        _ = try repository.loadCatalog()
        for read in [{ try repository.loadCatalog() as Any }, { try repository.loadTranscript(for:summary) as Any }] {
            let finished = DispatchSemaphore(value:0)
            let outcome = CancellationOutcome()
            let task = Task.detached {
                while !Task.isCancelled { await Task.yield() }
                do { _ = try read() }
                catch is CancellationError { outcome.wasCancelled = true }
                catch { outcome.unexpectedError = true }
                finished.signal()
            }
            task.cancel()
            XCTAssertEqual(finished.wait(timeout:.now()+5),.success)
            XCTAssertTrue(outcome.wasCancelled)
            XCTAssertFalse(outcome.unexpectedError)
            XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead,0)
        }
        XCTAssertEqual(catalog,try repository.loadCatalog())
        XCTAssertEqual(repository.lastReadMetrics.rolloutBytesRead,0)
    }

    private final class CancellationOutcome: @unchecked Sendable {
        var wasCancelled = false
        var unexpectedError = false
    }

    private func titleRecord(_ id:String,_ title:String) -> String {
        let value = ["id":id,"thread_name":title,"updated_at":"2026-10-12T00:00:00Z"]
        return String(data:try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)!
    }

    private func metadata(_ id:String = "fixture") -> String {
        record("session_meta",["id":id,"cwd":"/synthetic/project","timestamp":"2026-10-06T00:00:00Z","model":"fixture-model"])
    }
    private func token(_ usage:[String:Any],time:Int? = 1) -> String {
        record("event_msg",["type":"token_count","info":["total_token_usage":usage]],time:time)
    }
    private func record(_ type:String,_ payload:[String:Any],time:Int? = 0) -> String {
        var value:[String:Any] = ["type":type,"payload":payload]
        if let time { value["timestamp"] = String(format:"2026-10-06T00:00:%02dZ",time) }
        return String(data:try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)!
    }
    private struct Fixture {
        let root:URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("gpt-session-test-\(UUID().uuidString)",isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        }
        func remove() { try? FileManager.default.removeItem(at:root) }
        func write(_ lines:[String],name:String = "rollout-fixture.jsonl",archived:Bool = false,trailingNewline:Bool = true) throws -> URL {
            let directory = root.appendingPathComponent(archived ? "archived_sessions" : "sessions/2026/10/06",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let file = directory.appendingPathComponent(name)
            let text = lines.joined(separator:"\n") + (trailingNewline ? "\n" : "")
            try Data(text.utf8).write(to:file)
            return file
        }
    }
}
