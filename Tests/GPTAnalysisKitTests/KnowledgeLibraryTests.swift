import Foundation
import Darwin
import XCTest
@testable import GPTAnalysisKit

final class KnowledgeLibraryTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-tests-" + UUID().uuidString) }
    func testEmptyReadDoesNotCreateLibraryAndSaveKeepsPrivateCompleteVersions() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnowledgeStore(directoryURL: directory)
        XCTAssertTrue(try store.load().entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        var draft = KnowledgeDraft(title: "回答偏好", body: "使用中文")
        let first = try store.save(draft, expected: nil).entries[0]
        XCTAssertEqual(first.current.state, .draft)
        let libraryFile = directory.appendingPathComponent("library.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: libraryFile)) as? [String: Any])
        legacy["version"] = 1
        try JSONSerialization.data(withJSONObject: legacy).write(to: libraryFile)
        XCTAssertEqual(try store.load().entries, [first])
        draft.body = "使用中文，先给结果"; draft.state = .active
        let second = try store.save(draft, expected: first).entries[0]
        XCTAssertEqual(second.revision, 2)
        let upgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: libraryFile)) as? [String: Any])
        XCTAssertEqual(upgraded["version"] as? Int, 2)
        XCTAssertEqual(second.versions[0].draft.body, "使用中文")
        XCTAssertEqual(try KnowledgeStore(directoryURL: directory).load().entries, [second])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("library.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testStaleSaveDoesNotOverwriteOrDropUnrelatedEntries() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = KnowledgeStore(directoryURL: directory), b = KnowledgeStore(directoryURL: directory)
        var draft = KnowledgeDraft(title: "A", body: "before")
        let before = try a.save(draft, expected: nil).entries[0]
        _ = try b.save(.init(title: "B", body: "other"), expected: nil)
        draft.body = "after"; let after = try a.save(draft, expected: before)
        XCTAssertEqual(after.entries.count, 2)
        XCTAssertThrowsError(try b.save(before.current, expected: before))
        XCTAssertEqual(try b.load().entries.first { $0.id == draft.id }?.current.body, "after")
    }
    func testMergeIsAtomicAndPreservesBothHistoriesAndArchiveRestore() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnowledgeStore(directoryURL: directory)
        let first = try store.save(.init(title: "A", body: "中文"), expected: nil).entries[0]
        let added = try store.save(.init(title: "B", body: "结果优先"), expected: nil)
        let second = try XCTUnwrap(added.entries.first { $0.id != first.id })
        var draft = first.current; draft.body += "，" + second.current.body
        let merged = try store.merge(draft, target: first, source: second)
        let archived = try XCTUnwrap(merged.entries.first { $0.id == second.id })
        XCTAssertEqual(archived.current.state, .archived)
        XCTAssertEqual(archived.versions.count, 2)
        XCTAssertEqual(merged.entries[0].versions[0].draft.body, "中文")
        XCTAssertThrowsError(try store.merge(draft, target: first, source: second))
        var restore = archived.versions[0].draft; restore.state = .draft
        let restored = try store.save(restore, expected: archived)
        XCTAssertEqual(restored.entries.first { $0.id == second.id }?.revision, 3)
        XCTAssertEqual(restored.entries.first { $0.id == second.id }?.current.body, "结果优先")
    }
    func testScopeReuseExcludesInactiveWrongProjectAndWrongSession() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnowledgeStore(directoryURL: directory)
        _ = try store.save(.init(title: "通用", body: "PERSONAL", state: .active), expected: nil)
        _ = try store.save(.init(title: "项目", body: "PROJECT", scope: .project, projectPath: "/repo/a", state: .active), expected: nil)
        _ = try store.save(.init(title: "会话", body: "SESSION", scope: .session, sessionID: "s", state: .active), expected: nil)
        _ = try store.save(.init(title: "草稿", body: "DRAFT"), expected: nil)
        let catalog = try store.load(), ids = Set(catalog.entries.map(\.id))
        let wrong = catalog.bundle(ids: ids, project: "/repo/ab", session: "other")
        XCTAssertTrue(wrong.contains("PERSONAL")); XCTAssertFalse(wrong.contains("PROJECT")); XCTAssertFalse(wrong.contains("SESSION")); XCTAssertFalse(wrong.contains("DRAFT"))
        let right = catalog.bundle(ids: ids, project: "/repo/a/.", session: "s")
        XCTAssertTrue(right.contains("PROJECT")); XCTAssertTrue(right.contains("SESSION"))
        XCTAssertTrue(catalog.bundle(ids: [], project: "", session: "").isEmpty)
    }
    func testValidationVersionLimitAndCorruptFileAreNonDestructive() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnowledgeStore(directoryURL: directory)
        XCTAssertThrowsError(try store.save(.init(title: "", body: "x"), expected: nil))
        XCTAssertThrowsError(try store.save(.init(title: "x", body: String(repeating: "x", count: 32_769)), expected: nil))
        XCTAssertThrowsError(try store.save(.init(title: "x", body: "x", scope: .project, projectPath: "relative"), expected: nil))
        var entry = try store.save(.init(title: "x", body: "x"), expected: nil).entries[0]
        for index in 2...20 { var draft = entry.current; draft.body = String(index); entry = try store.save(draft, expected: entry).entries[0] }
        XCTAssertThrowsError(try store.save(entry.current, expected: entry))
        XCTAssertEqual(try store.load().entries[0].versions.count, 20)
        let trashedAtLimit = try store.setTrashed(true, expected: entry).entries[0]
        let restoredAtLimit = try store.setTrashed(false, expected: trashedAtLimit).entries[0]
        XCTAssertEqual(restoredAtLimit.versions.count, 20)
        let file = directory.appendingPathComponent("library.json"), corrupt = Data("broken".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(.init(title: "new", body: "new"), expected: nil))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testReaderReadsMarkdownOnlyAndNeverChangesSourcesOrFollowsLinks() throws {
        let directory = root(), outside = root(); defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("OUTSIDE".utf8).write(to: outside)
        let file = directory.appendingPathComponent("MEMORY.md"), data = Data("# 项目知识\n使用中文".utf8)
        try data.write(to: file)
        try Data("IGNORED".utf8).write(to: directory.appendingPathComponent("raw.jsonl"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.md"), withDestinationURL: outside)
        let catalog = try CodexMemoryReader(rootURL: directory).read()
        XCTAssertEqual(catalog.documents.count, 1)
        let document = try XCTUnwrap(catalog.documents.first)
        XCTAssertEqual(document.title, "项目知识")
        XCTAssertEqual(document.importedDraft().state, .draft)
        XCTAssertEqual(document.importedDraft().sources[0].origin, .codex)
        XCTAssertFalse(catalog.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library.json").path))
    }
    func testStoreRejectsSymlinksAndHardlinksWithoutChangingTarget() throws {
        let directory = root(), target = root(); defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = Data("TARGET".utf8); try data.write(to: target); chmod(target.path, 0o600)
        let file = directory.appendingPathComponent("library.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let store = KnowledgeStore(directoryURL: directory)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(.init(title: "x", body: "x"), expected: nil))
        try FileManager.default.removeItem(at: file); try FileManager.default.linkItem(at: target, to: file)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf: target), data)
    }
    func testTrashRestoreAndPermanentDeletePreserveOtherEntriesAndRejectStaleOperations() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = KnowledgeStore(directoryURL: directory)
        let first = try store.save(.init(title: "A", body: "REFERENCE", state: .active), expected: nil).entries[0]
        _ = try store.save(.init(title: "B", body: "OTHER"), expected: nil)
        XCTAssertThrowsError(try store.permanentlyDelete(expected: first))
        let trashed = try store.setTrashed(true, expected: first)
        let entry = try XCTUnwrap(trashed.entries.first { $0.id == first.id })
        XCTAssertEqual(entry.versions, first.versions)
        XCTAssertTrue(trashed.bundle(ids: [first.id], project: "", session: "").isEmpty)
        XCTAssertEqual(try store.load().entries.first { $0.id == first.id }, entry)
        XCTAssertThrowsError(try store.save(first.current, expected: entry))
        XCTAssertThrowsError(try store.setTrashed(false, expected: first))
        let restored = try store.setTrashed(false, expected: entry).entries.first { $0.id == first.id }!
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.current.state, .active)
        XCTAssertThrowsError(try store.permanentlyDelete(expected: entry))
        let again = try store.setTrashed(true, expected: restored).entries.first { $0.id == first.id }!
        XCTAssertThrowsError(try store.permanentlyDelete(expected: entry))
        let deleted = try store.permanentlyDelete(expected: again)
        XCTAssertEqual(deleted.entries.count, 1)
        XCTAssertEqual(deleted.entries[0].current.title, "B")
        XCTAssertEqual(try store.load(), deleted)
        XCTAssertThrowsError(try store.permanentlyDelete(expected: again))
    }
    func testMissingReaderAndDuplicateAdvisoryAreSafe() throws {
        let directory = root()
        let result = try CodexMemoryReader(rootURL: directory).read()
        XCTAssertTrue(result.documents.isEmpty); XCTAssertFalse(result.warnings.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let draft = KnowledgeDraft(title: "x", body: "same")
        let entry = KnowledgeEntry(id: draft.id, versions: [.init(number: 1, savedAt: Date(), reason: "创建", draft: draft)])
        XCTAssertEqual(KnowledgeCatalog(entries: [entry]).duplicates(of: .init(title: "y", body: " same ")).count, 1)
        XCTAssertTrue(KnowledgeCatalog(entries: [entry]).duplicates(of: .init(title: "y", body: "same", scope: .project, projectPath: "/repo")).isEmpty)
    }
}
