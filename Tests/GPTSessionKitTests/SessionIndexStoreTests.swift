import Foundation
import Darwin
import XCTest
@testable import GPTSessionKit

final class SessionIndexStoreTests: XCTestCase {
    func testAbsentLoadAndClearDoNotCreateStorage() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let store = fixture.store()
        XCTAssertTrue(try store.load().entries.isEmpty)
        XCTAssertTrue(try store.load().warnings.isEmpty)
        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    func testRoundTripRestoresWarningsIdentityAndSearchWithoutTouchingLogs() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let active = fixture.entry("active"), archived = fixture.entry("archived", archived: true)
        let store = fixture.store()
        XCTAssertTrue(try store.save(entries: [active, archived]).isEmpty)
        let restarted = fixture.store()
        let loaded = try restarted.load()
        XCTAssertEqual(Set(loaded.entries.map(\.relativePath)), Set([active.relativePath, archived.relativePath]))
        XCTAssertEqual(loaded.entries.first(where: { $0.relativePath == active.relativePath }), active)
        XCTAssertEqual(loaded.entries.first(where: { $0.relativePath == archived.relativePath }), archived)
        XCTAssertTrue(loaded.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
        XCTAssertEqual(try permissions(fixture.cache), 0o700)
        XCTAssertEqual(try permissions(store.fileURL), 0o600)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("fixture-search"))
        XCTAssertFalse(text.contains("only-original-log-body"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).count, 1)
        // Existing loose permissions are corrected when a new atomic generation is installed.
        XCTAssertEqual(chmod(store.fileURL.path, 0o644), 0)
        XCTAssertEqual(chmod(fixture.cache.path, 0o755), 0)
        XCTAssertTrue(try store.load().entries.isEmpty)
        XCTAssertTrue(try store.load().warnings.contains(where: { $0.contains("权限") }))
        _ = try store.save(entries: [active])
        XCTAssertEqual(try permissions(fixture.cache), 0o700)
        XCTAssertEqual(try permissions(store.fileURL), 0o600)
    }

    func testTokenCodablePreservesUnknownTotalAndOverflowAcrossFurtherAggregation() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let unknown = CodexTokenUsage.aggregate([.init(input: 10), .init(output: 5)])
        let overflow = CodexTokenUsage.aggregate([.init(input: Int.max, total: Int.max), .init(input: 1, total: 1)])
        let entries = [fixture.entry("unknown", tokens: unknown), fixture.entry("overflow", tokens: overflow)]
        let store = fixture.store(); _ = try store.save(entries: entries)
        let loaded = try store.load().entries
        let decodedUnknown = try XCTUnwrap(loaded.first(where: { $0.summary.sessionID == "unknown" })).summary.tokens
        let decodedOverflow = try XCTUnwrap(loaded.first(where: { $0.summary.sessionID == "overflow" })).summary.tokens
        XCTAssertEqual(decodedUnknown, unknown)
        XCTAssertEqual(decodedOverflow, overflow)
        XCTAssertNil(decodedUnknown.effectiveTotal)
        XCTAssertTrue(decodedOverflow.hasOverflow(for: \.input))
        XCTAssertTrue(decodedOverflow.hasOverflow(for: \.effectiveTotal))
        let further = CodexTokenUsage.aggregate([decodedOverflow, .init(input: 2, output: 3, total: 5)])
        XCTAssertNil(further.input)
        XCTAssertNil(further.effectiveTotal)
        XCTAssertTrue(further.hasOverflow(for: \.input))
        XCTAssertEqual(further.output, 3)
    }

    func testNamespacesSeparateRootsAndAllReadLimits() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let first = fixture.store(), entry = fixture.entry("one")
        _ = try first.save(entries: [entry])
        let anotherRoot = fixture.base.appendingPathComponent("other-root", isDirectory: true)
        let second = SessionIndexStore(directoryURL: fixture.cache, rootURL: anotherRoot)
        let altered = fixture.store(limits: .init(maximumLineBytes: 512))
        let changedLRU = fixture.store(limits: .init(maximumCachedTranscripts: 0))
        XCTAssertNotEqual(first.fileURL, second.fileURL)
        XCTAssertNotEqual(first.fileURL, altered.fileURL)
        XCTAssertNotEqual(first.fileURL, changedLRU.fileURL)
        XCTAssertTrue(try second.load().entries.isEmpty)
        XCTAssertTrue(try altered.load().entries.isEmpty)
        // Copying a cache under another namespace cannot bypass its embedded identity.
        try FileManager.default.copyItem(at: first.fileURL, to: second.fileURL)
        try FileManager.default.copyItem(at: first.fileURL, to: altered.fileURL)
        XCTAssertTrue(try second.load().entries.isEmpty)
        XCTAssertFalse(try second.load().warnings.isEmpty)
        XCTAssertTrue(try altered.load().entries.isEmpty)
        XCTAssertFalse(try altered.load().warnings.isEmpty)
        XCTAssertEqual(try first.load().entries, [entry])
    }

    func testSchemaMismatchCorruptionAndIncompleteLineInvalidateWholeIndex() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let store = fixture.store(); _ = try store.save(entries: [fixture.entry("one"), fixture.entry("two")])
        let original = try Data(contentsOf: store.fileURL)
        let newline = try XCTUnwrap(original.firstIndex(of: 10))
        var header = try XCTUnwrap(JSONSerialization.jsonObject(with: original.prefix(upTo: newline)) as? [String: Any])
        header["version"] = 999
        var invalidVersion = try JSONSerialization.data(withJSONObject: header)
        invalidVersion.append(10); invalidVersion.append(original.suffix(from: newline + 1))
        for broken in [invalidVersion, Data(original.dropLast()), original + Data("not-json\n".utf8), Data()] {
            try broken.write(to: store.fileURL)
            let loaded = try store.load()
            XCTAssertTrue(loaded.entries.isEmpty)
            XCTAssertFalse(loaded.warnings.isEmpty)
            XCTAssertEqual(try Data(contentsOf: store.fileURL), broken)
            XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
        }
    }

    func testInvalidSavePreservesCompletePreviousGenerationAndRemovesStagingFiles() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let store = fixture.store(), entry = fixture.entry("valid")
        _ = try store.save(entries: [entry])
        let original = try Data(contentsOf: store.fileURL)
        let escape = SessionIndexEntry(relativePath: "sessions/../../elsewhere.jsonl", summary: entry.summary,
                                       revision: entry.revision)
        XCTAssertThrowsError(try store.save(entries: [entry, escape]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertThrowsError(try store.save(entries: [entry, entry]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(try store.load().entries, [entry])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).count, 1)
    }

    func testEntryCountByteAndRecordBudgetsAreBoundedAndReported() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let entries = [fixture.entry("old", updated: 1), fixture.entry("new", updated: 2)]
        let single = fixture.store(cacheLimits: .init(maximumEntries: 1))
        XCTAssertFalse(try single.save(entries: entries).isEmpty)
        XCTAssertEqual(try single.load().entries.map(\.summary.sessionID), ["new"])
        let firstGeneration = try Data(contentsOf: single.fileURL)
        let exactOneBudget = fixture.store(cacheLimits: .init(maximumBytes: firstGeneration.count))
        XCTAssertFalse(try exactOneBudget.save(entries: entries).isEmpty)
        XCTAssertEqual(try exactOneBudget.load().entries.map(\.summary.sessionID), ["new"])
        XCTAssertLessThanOrEqual(try Data(contentsOf: single.fileURL).count, firstGeneration.count)
        let headerLength = try XCTUnwrap(firstGeneration.firstIndex(of: 10))
        let shortRecords = fixture.store(cacheLimits: .init(maximumRecordBytes: headerLength))
        XCTAssertFalse(try shortRecords.save(entries: entries).isEmpty)
        XCTAssertTrue(try shortRecords.load().entries.isEmpty)
        XCTAssertTrue(try shortRecords.load().warnings.isEmpty)
        // A foreign oversized cache is rejected without loading all its contents.
        try Data(repeating: 65, count: 2_048).write(to: single.fileURL)
        let byteLimited = fixture.store(cacheLimits: .init(maximumBytes: 1_024))
        XCTAssertTrue(try byteLimited.load().entries.isEmpty)
        XCTAssertFalse(try byteLimited.load().warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
    }

    func testDuplicatedPathsAndOversizedRecordsInvalidateLoadedCache() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let store = fixture.store(); _ = try store.save(entries: [fixture.entry("one")])
        let original = try Data(contentsOf: store.fileURL)
        let newline = try XCTUnwrap(original.firstIndex(of: 10))
        try (original + original.suffix(from: newline + 1)).write(to: store.fileURL)
        XCTAssertTrue(try store.load().entries.isEmpty)
        XCTAssertFalse(try store.load().warnings.isEmpty)
        let huge = Data(original.prefix(through: newline)) + Data(repeating: 65, count: 262_145) + Data([10])
        try huge.write(to: store.fileURL)
        XCTAssertTrue(try store.load().entries.isEmpty)
        XCTAssertFalse(try store.load().warnings.isEmpty)
    }

    func testLargeMultibyteSearchSummaryIsSkippedWithoutLosingOtherEntries() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let text = String(repeating: "👨‍👩‍👧‍👦", count: 65_536)
        XCTAssertEqual(text.count, 65_536)
        let large = fixture.entry("large", updated: 2, search: text), small = fixture.entry("small", updated: 1)
        let store = fixture.store()
        XCTAssertFalse(try store.save(entries: [large, small]).isEmpty)
        XCTAssertEqual(try store.load().entries, [small])
        XCTAssertTrue(try store.load().warnings.isEmpty)
    }

    func testCacheFileSymlinkAndHardLinkAreNeverReadOverwrittenOrRemoved() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let store = fixture.store(), entry = fixture.entry("one")
        try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: true)
        let outside = fixture.base.appendingPathComponent("outside.jsonl")
        let outsideBytes = Data("outside-private-data".utf8)
        try outsideBytes.write(to: outside)
        XCTAssertEqual(symlink(outside.path, store.fileURL.path), 0)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(entries: [entry]))
        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
        XCTAssertEqual(unlink(store.fileURL.path), 0)
        XCTAssertEqual(link(outside.path, store.fileURL.path), 0)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(entries: [entry]))
        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
    }

    func testDirectorySymlinkAndParentReplacementCannotRedirectWrites() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(outside.path, fixture.cache.path), 0)
        let store = fixture.store()
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(entries: [fixture.entry("one")]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertEqual(unlink(fixture.cache.path), 0)
        let parent = fixture.base.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let nested = SessionIndexStore(directoryURL: parent.appendingPathComponent("cache"), rootURL: fixture.root)
        try FileManager.default.removeItem(at: parent)
        XCTAssertEqual(symlink(outside.path, parent.path), 0)
        XCTAssertThrowsError(try nested.load())
        XCTAssertThrowsError(try nested.save(entries: [fixture.entry("one")]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testClearOnlyRemovesSelectedNamespaceAndNeverOriginalLog() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let first = fixture.store(), second = fixture.store(limits: .init(maximumMessages: 2))
        _ = try first.save(entries: [fixture.entry("one")])
        _ = try second.save(entries: [fixture.entry("two")])
        try first.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertEqual(try second.load().entries.map(\.summary.sessionID), ["two"])
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
    }

    func testCacheLocationsWithinCodexRootCannotModifySourceDirectories() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        for location in [fixture.root, fixture.root.appendingPathComponent("new-cache"),
                         fixture.root.appendingPathComponent("sessions/cache"),
                         fixture.root.appendingPathComponent("archived_sessions/cache")] {
            let store = SessionIndexStore(directoryURL: location, rootURL: fixture.root)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(entries: [fixture.entry("one")]))
            XCTAssertThrowsError(try store.clear())
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("new-cache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("archived_sessions").path))
    }

    func testPhysicalAndSymbolicRootAliasesShareNamespaceAndCannotBypassSourceGuard() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let resolved = try XCTUnwrap(fixture.root.path.withCString({ realpath($0, nil) }))
        let physical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        let alias = fixture.base.appendingPathComponent("source-alias", isDirectory: true)
        XCTAssertEqual(symlink(fixture.root.path, alias.path), 0)
        let outside = fixture.store()
        for source in [fixture.root, physical, alias] {
            let ordinary = SessionIndexStore(directoryURL: fixture.cache, rootURL: source)
            XCTAssertEqual(ordinary.fileURL, outside.fileURL)
            for location in [fixture.root, physical, alias,
                             fixture.root.appendingPathComponent("cache"),
                             physical.appendingPathComponent("sessions/cache"),
                             alias.appendingPathComponent("archived_sessions/cache")] {
                let inside = SessionIndexStore(directoryURL: location, rootURL: source)
                XCTAssertThrowsError(try inside.load())
                XCTAssertThrowsError(try inside.save(entries: [fixture.entry("one")]))
                XCTAssertThrowsError(try inside.clear())
                XCTAssertFalse(FileManager.default.fileExists(atPath: inside.fileURL.path))
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("cache").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("archived_sessions").path))
        let absentRoot = fixture.base.appendingPathComponent("not-yet-created-source", isDirectory: true)
        let invalid = SessionIndexStore(directoryURL: absentRoot.appendingPathComponent("cache"), rootURL: absentRoot)
        XCTAssertThrowsError(try invalid.save(entries: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentRoot.path))
    }

    func testCancelledOperationsDoNotCreateStorageOrReplaceExistingGeneration() throws {
        let fixture = try IndexFixture(); defer { fixture.remove() }
        let store = fixture.store(), entry = fixture.entry("one")
        for operation in [0, 1, 2] {
            let outcome = IndexCancellationOutcome(), finished = DispatchSemaphore(value: 0)
            let task = Task.detached {
                while !Task.isCancelled { await Task.yield() }
                do {
                    if operation == 0 { _ = try store.load() }
                    if operation == 1 { _ = try store.save(entries: [entry]) }
                    if operation == 2 { try store.clear() }
                } catch is CancellationError { outcome.cancelled = true }
                catch { outcome.unexpected = true }
                finished.signal()
            }
            task.cancel()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
            XCTAssertTrue(outcome.cancelled)
            XCTAssertFalse(outcome.unexpected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
        }
        _ = try store.save(entries: [entry])
        let before = try Data(contentsOf: store.fileURL)
        let finished = DispatchSemaphore(value: 0), outcome = IndexCancellationOutcome()
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            do { _ = try store.save(entries: [fixture.entry("replacement")]) }
            catch is CancellationError { outcome.cancelled = true }
            catch { outcome.unexpected = true }
            finished.signal()
        }
        task.cancel()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(outcome.cancelled)
        XCTAssertFalse(outcome.unexpected)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    private func permissions(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NSError(domain: "Fixture", code: Int(errno)) }
        return info.st_mode & 0o777
    }

    private final class IndexCancellationOutcome: @unchecked Sendable {
        var cancelled = false
        var unexpected = false
    }

    private final class IndexFixture: @unchecked Sendable {
        let base: URL, root: URL, cache: URL, originalLog: URL
        let originalBytes = Data("only-original-log-body\n".utf8)
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("session-index-\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("codex", isDirectory: true)
            cache = base.appendingPathComponent("cache", isDirectory: true)
            originalLog = root.appendingPathComponent("sessions/original.jsonl")
            try FileManager.default.createDirectory(at: originalLog.deletingLastPathComponent(), withIntermediateDirectories: true)
            try originalBytes.write(to: originalLog)
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
        func store(limits: SessionReadLimits = .init(), cacheLimits: SessionIndexLimits = .init()) -> SessionIndexStore {
            SessionIndexStore(directoryURL: cache, rootURL: root, limits: limits, cacheLimits: cacheLimits)
        }
        func entry(_ id: String, archived: Bool = false, updated: TimeInterval = 1,
                   tokens: CodexTokenUsage = .init(input: 100, output: 20, total: 120),
                   search: String? = nil) -> SessionIndexEntry {
            let relative = "\(archived ? "archived_sessions" : "sessions")/\(id).jsonl"
            let file = root.resolvingSymlinksInPath().appendingPathComponent(relative)
            let summary = CodexSessionSummary(id: file.path, sessionID: id, fileURL: file,
                title: "Fixture \(id)", projectPath: "/synthetic/project", startedAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: updated), model: "fixture-model", messageCount: 2,
                toolCallCount: 1, tokens: tokens, isArchived: archived, searchText: search ?? "fixture-search \(id)")
            let revision = SessionIndexRevision(device: 1, inode: 2, changedSeconds: 3, changedNanoseconds: 4,
                modifiedSeconds: 5, modifiedNanoseconds: 6, bytes: 7, archived: archived)
            return .init(relativePath: relative, summary: summary, revision: revision, warnings: ["原日志已截断。"])
        }
    }
}
