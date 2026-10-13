import Foundation
import Darwin
import XCTest
@testable import GPTSessionKit

final class SessionManagementStoreTests: XCTestCase {
    func testAbsentReadDoesNotCreateStorage() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store()
        XCTAssertEqual(try store.load(), SessionManagementSnapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
    }

    func testRoundTripDetailsFavoriteAndKindIdentityWithoutModifyingLogs() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store(), identity = "session:stable-identity"
        _ = try store.patch(kind: .session, itemID: identity, change: .setFavorite(true))
        let saved = try store.patch(kind: .session, itemID: identity,
                                   change: .setDetails(displayName: "  本地名称  ", note: "第一行\n第二行 "))
        _ = try store.patch(kind: .project, itemID: identity, change: .setFavorite(true))
        let restarted = try fixture.store().load()
        XCTAssertEqual(saved.revision, 2)
        XCTAssertEqual(restarted.revision, 3)
        XCTAssertEqual(restarted.entries.count, 2)
        XCTAssertEqual(restarted.entry(kind: .session, itemID: identity),
                       SessionManagementEntry(kind: .session, itemID: identity, isFavorite: true,
                                              displayName: "本地名称", note: "第一行\n第二行 "))
        XCTAssertTrue(try XCTUnwrap(restarted.entry(kind: .project, itemID: identity)).isFavorite)
        XCTAssertEqual(try permissions(store.directoryURL), 0o700)
        XCTAssertEqual(try permissions(store.fileURL), 0o600)
        XCTAssertEqual(try permissions(store.fileURL.deletingPathExtension().appendingPathExtension("lock")), 0o600)
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
        XCTAssertFalse(try String(contentsOf: store.fileURL, encoding: .utf8).contains("only-original-body"))
    }

    func testWhitespaceResetRemovesEmptyEntryAndNoOpKeepsRevision() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try store.patch(kind: .session, itemID: "one", change: .setDetails(displayName: "名称", note: "备注"))
        let same = try store.patch(kind: .session, itemID: "one", change: .setDetails(displayName: "名称", note: "备注"))
        XCTAssertEqual(first, same)
        _ = try store.patch(kind: .session, itemID: "one", change: .setDisplayName("\n  "))
        let removed = try store.patch(kind: .session, itemID: "one", change: .setNote("\t\n "))
        XCTAssertTrue(removed.entries.isEmpty)
        XCTAssertEqual(removed.revision, 3)
        XCTAssertEqual(try store.load(), removed)
        _ = try store.patch(kind: .project, itemID: "/full/project", change: .setFavorite(true))
        let cleared = try store.patch(kind: .project, itemID: "/full/project", change: .clear)
        XCTAssertTrue(cleared.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
    }

    func testVersionOneLoadsWithoutRewriteAndFirstChangeMigratesWithoutLosingDetails() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let initial = try store.patch(kind: .session, itemID: "existing-session",
                                      change: .update(isFavorite: true, displayName: .set("原名称"), note: .set("旧备注\n保留")))
        _ = try store.patch(kind: .project, itemID: "/old-project", change: .setFavorite(true))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        document["version"] = 1
        document["entries"] = try XCTUnwrap(document["entries"] as? [[String: Any]]).map { value in
            var value = value; value.removeValue(forKey: "tags"); return value
        }
        let legacyBytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try legacyBytes.write(to: store.fileURL)
        let legacy = try fixture.store().load()
        XCTAssertEqual(legacy.revision, 2)
        XCTAssertEqual(legacy.entries.count, 2)
        XCTAssertEqual(legacy.entry(kind: .session, itemID: "existing-session"), initial.entries.first)
        XCTAssertTrue(legacy.entries.allSatisfy { $0.tags.isEmpty })
        XCTAssertEqual(try Data(contentsOf: store.fileURL), legacyBytes)
        _ = try store.patch(kind: .project, itemID: "/old-project", change: .setFavorite(true))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), legacyBytes)
        let migrated = try store.patch(kind: .project, itemID: "/old-project", change: .setTags(["进行中"]))
        XCTAssertEqual(migrated.revision, 3)
        XCTAssertEqual(migrated.entry(kind: .session, itemID: "existing-session"), initial.entries.first)
        XCTAssertEqual(migrated.entry(kind: .project, itemID: "/old-project")?.isFavorite, true)
        XCTAssertEqual(migrated.entry(kind: .project, itemID: "/old-project")?.tags, ["进行中"])
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(written["version"] as? Int, 2)
        XCTAssertTrue(try XCTUnwrap(written["entries"] as? [[String: Any]]).allSatisfy { $0["tags"] is [String] })
        XCTAssertEqual(try fixture.store().load(), migrated)
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
    }

    func testTagNormalizationUsesCanonicalUnicodeFixedCaseMatchingAndFirstSpelling() throws {
        XCTAssertEqual(SessionManagementStore.maximumTags, 8)
        XCTAssertEqual(SessionManagementStore.maximumTagCharacters, 20)
        XCTAssertEqual(SessionManagementStore.maximumTagBytes, 256)
        XCTAssertEqual(try SessionManagementStore.normalizedTags(["zeta", " AI ", "ai", "研发", "开发", "", " É ", "E\u{0301}"]),
                       ["AI", "zeta", "É", "开发", "研发"])
        let canonical = try SessionManagementStore.normalizedTags(["e\u{0301}"])
        XCTAssertEqual(canonical.first?.utf8.map { $0 }, Array("é".utf8))
        XCTAssertEqual(SessionManagementStore.tagKey("É"), SessionManagementStore.tagKey("e\u{0301}"))
        XCTAssertEqual(SessionManagementStore.tagKey("I"), "i")
        XCTAssertNotEqual(SessionManagementStore.tagKey("résumé"), SessionManagementStore.tagKey("resume"))
        let eight = (0..<8).map { "Tag\($0)" }
        XCTAssertEqual(try SessionManagementStore.normalizedTags(eight + eight.map { $0.lowercased() }), eight)
        XCTAssertEqual(try SessionManagementStore.normalizedTags(["   ", "", "　"]), [])
        XCTAssertEqual(try SessionManagementStore.normalizedTags([String(repeating: "中", count: 20)]), [String(repeating: "中", count: 20)])
    }

    func testInvalidTagInputsDoNotCreateStorageAndRejectAtomically() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let invalid = [[String(repeating: "a", count: 21)],
                       [String(repeating: "👨‍👩‍👧‍👦", count: 11)],
                       (0..<9).map { "Tag\($0)" },
                       Array(repeating: "", count: 129),
                       [String(repeating: " ", count: 4_097)],
                       ["a,b"], ["a，b"], ["a\nb"], ["\ta"], ["a\0b"],
                       ["a\u{2028}b"], ["a\u{2029}b"], ["a\u{0085}b"]]
        for input in invalid {
            XCTAssertThrowsError(try SessionManagementStore.normalizedTags(input))
            XCTAssertThrowsError(try store.patch(kind: .project, itemID: "/a", change: .setTags(input)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        }
        _ = try store.patch(kind: .project, itemID: "/a", change: .setTags(["原标签"]))
        let original = try Data(contentsOf: store.fileURL)
        for input in invalid {
            XCTAssertThrowsError(try store.patch(kind: .project, itemID: "/a",
                                                 change: .update(isFavorite: true, note: .set("本次备注"), tags: input)))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        }
        XCTAssertEqual(try store.load().entry(kind: .project, itemID: "/a")?.isFavorite, false)
        XCTAssertEqual(try store.load().entry(kind: .project, itemID: "/a")?.note, nil)
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
    }

    func testTagsOnlyEntryPersistsUntilTagsAreClearedAndClearRemovesAllFields() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try store.patch(kind: .project, itemID: "/tags-only", change: .setTags(["Beta", "alpha", " ALPHA "]))
        XCTAssertEqual(first.entries.first, SessionManagementEntry(kind: .project, itemID: "/tags-only", tags: ["alpha", "Beta"]))
        XCTAssertEqual(try fixture.store().load(), first)
        XCTAssertEqual(try store.patch(kind: .project, itemID: "/tags-only", change: .setDetails(displayName: nil, note: nil)), first)
        XCTAssertEqual(try store.patch(kind: .project, itemID: "/tags-only", change: .setTags(["alpha", "Beta"])), first)
        let empty = try store.patch(kind: .project, itemID: "/tags-only", change: .update(isFavorite: nil, tags: []))
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.revision, 2)
        let restored = try store.patch(kind: .project, itemID: "/tags-only",
                                       change: .update(isFavorite: true, displayName: .set("名字"), note: .set("备注"), tags: ["tag"]))
        XCTAssertEqual(restored.entries.count, 1)
        let cleared = try store.patch(kind: .project, itemID: "/tags-only", change: .clear,
                                     expectedEntry: restored.entries.first)
        XCTAssertTrue(cleared.entries.isEmpty)
        XCTAssertEqual(try fixture.store().load(), cleared)
    }

    func testTagPatchesPreserveConcurrentFieldsAndTagConflictsAreIdempotentOnlyAtDesiredValue() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let first = try fixture.store(), second = try fixture.store()
        let initial = try first.patch(kind: .project, itemID: "/a",
                                      change: .update(isFavorite: true, displayName: .set("原名称"), note: .set("旧备注"), tags: ["Base"]))
        let baseline = try XCTUnwrap(initial.entries.first)
        _ = try second.patch(kind: .project, itemID: "/a", change: .update(isFavorite: false, note: .set("另一窗口备注")))
        let merged = try first.patch(kind: .project, itemID: "/a", change: .update(isFavorite: nil, tags: ["Mine"]), expectedEntry: baseline)
        let latest = try XCTUnwrap(merged.entries.first)
        XCTAssertEqual(latest.tags, ["Mine"])
        XCTAssertEqual(latest.isFavorite, false)
        XCTAssertEqual(latest.note, "另一窗口备注")
        XCTAssertEqual(latest.displayName, "原名称")
        _ = try second.patch(kind: .project, itemID: "/a", change: .setTags(["Other"]))
        let before = try Data(contentsOf: first.fileURL)
        XCTAssertThrowsError(try first.patch(kind: .project, itemID: "/a", change: .setTags(["My conflict"]), expectedEntry: latest))
        XCTAssertEqual(try Data(contentsOf: first.fileURL), before)
        let idempotent = try first.patch(kind: .project, itemID: "/a", change: .setTags([" Other "]), expectedEntry: latest)
        XCTAssertEqual(idempotent.entry(kind: .project, itemID: "/a")?.tags, ["Other"])
        XCTAssertEqual(try Data(contentsOf: first.fileURL), before)
        let savedName = try first.patch(kind: .project, itemID: "/a",
                                        change: .update(isFavorite: nil, displayName: .set("新名称")), expectedEntry: latest)
        XCTAssertEqual(savedName.entry(kind: .project, itemID: "/a")?.tags, ["Other"])
        XCTAssertEqual(savedName.entry(kind: .project, itemID: "/a")?.note, "另一窗口备注")
        let memory = try SessionManagementStore.applying(change: .setTags([" Other "]),
                                                         to: try XCTUnwrap(idempotent.entries.first), expectedEntry: latest)
        XCTAssertEqual(memory, idempotent.entries.first)
        XCTAssertThrowsError(try SessionManagementStore.applying(change: .clear, to: memory, expectedEntry: latest))
    }

    func testNonCanonicalOrMalformedStoredTagsNeverOverwriteOriginalMetadata() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try store.patch(kind: .project, itemID: "/a", change: .setTags(["Original"]))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let originalEntry = try XCTUnwrap(document["entries"] as? [[String: Any]])[0]
        let corruptTags: [Any] = [[""], [" spaced "], ["b", "a"], ["AI", "ai"], ["e\u{0301}"],
                                  ["line\nbreak"], ["a,b"], [String(repeating: "a", count: 21)],
                                  (0..<9).map { "tag\($0)" }, NSNull(), "a", [1]]
        for tags in corruptTags {
            var broken = document, entry = originalEntry
            entry["tags"] = tags; broken["entries"] = [entry]
            let bytes = try JSONSerialization.data(withJSONObject: broken)
            try bytes.write(to: store.fileURL)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.patch(kind: .project, itemID: "/a", change: .setTags(["Replacement"])))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
            XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
        }
    }

    func testCrossInstancePatchesMergeLatestStateAndExplicitRevisionConflictPreservesFile() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let first = try fixture.store(), second = try fixture.store()
        let empty = try second.load()
        _ = try first.patch(kind: .session, itemID: "a", change: .setDetails(displayName: "A", note: "已保存"))
        let merged = try second.patch(kind: .project, itemID: "b", change: .setFavorite(true))
        XCTAssertEqual(merged.entries.count, 2)
        XCTAssertEqual(merged.entry(kind: .session, itemID: "a")?.note, "已保存")
        let original = try Data(contentsOf: first.fileURL)
        XCTAssertThrowsError(try second.patch(kind: .session, itemID: "a", change: .setNote("过期覆盖"), expectedRevision: empty.revision))
        XCTAssertEqual(try Data(contentsOf: first.fileURL), original)
        let latest = try first.patch(kind: .session, itemID: "a", change: .setFavorite(true), expectedRevision: merged.revision)
        XCTAssertEqual(latest.entry(kind: .session, itemID: "a")?.note, "已保存")
        XCTAssertEqual(latest.entry(kind: .session, itemID: "a")?.displayName, "A")
        XCTAssertEqual(latest.entry(kind: .project, itemID: "b")?.isFavorite, true)
    }

    func testConcurrentIndependentStoresKeepEveryItem() throws {
        // Every round races the first lock-file creation, not just patches to
        // an already initialized store; repeat to exercise competing creators.
        for _ in 0..<4 {
            let fixture = try ManagementFixture(); defer { fixture.remove() }
            let outcome = ManagementOutcome(), group = DispatchGroup()
            for index in 0..<16 {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    do {
                        let store = try fixture.store()
                        _ = try store.patch(kind: .session, itemID: "session-\(index)", change: .setFavorite(true))
                    } catch { outcome.record(error) }
                }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
            if !outcome.messages.isEmpty { print("Concurrent management patch errors: \(outcome.messages)") }
            XCTAssertEqual(outcome.errorCount, 0)
            let loaded = try fixture.store().load()
            XCTAssertEqual(loaded.revision, 16)
            XCTAssertEqual(loaded.entries.count, 16)
            XCTAssertTrue(loaded.entries.allSatisfy(\.isFavorite))
        }
    }

    func testOldEditorChangingNameKeepsOtherInstancesNoteAndFavorite() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let first = try fixture.store(), second = try fixture.store()
        let initial = try first.patch(kind: .session, itemID: "a", change: .setDetails(displayName: "旧名称", note: "旧备注"))
        let baseline = try XCTUnwrap(initial.entry(kind: .session, itemID: "a"))
        _ = try second.patch(kind: .session, itemID: "a", change: .setNote("另一窗口的新备注"))
        _ = try second.patch(kind: .session, itemID: "a", change: .setFavorite(true))
        let saved = try first.patch(kind: .session, itemID: "a",
                                    change: .update(isFavorite: nil, displayName: .set("新名称"), note: .unchanged),
                                    expectedEntry: baseline)
        XCTAssertEqual(saved.entry(kind: .session, itemID: "a")?.displayName, "新名称")
        XCTAssertEqual(saved.entry(kind: .session, itemID: "a")?.note, "另一窗口的新备注")
        XCTAssertEqual(saved.entry(kind: .session, itemID: "a")?.isFavorite, true)
        let reverseBaseline = try XCTUnwrap(saved.entry(kind: .session, itemID: "a"))
        _ = try second.patch(kind: .session, itemID: "a", change: .setDisplayName("第三个名称"))
        let reverse = try first.patch(kind: .session, itemID: "a",
                                      change: .update(isFavorite: nil, displayName: .unchanged, note: .set("我修改的备注")),
                                      expectedEntry: reverseBaseline)
        XCTAssertEqual(reverse.entry(kind: .session, itemID: "a")?.displayName, "第三个名称")
        XCTAssertEqual(reverse.entry(kind: .session, itemID: "a")?.note, "我修改的备注")
    }

    func testSameFieldEditorConflictPreservesAllFieldsAndMatchingDesiredValueIsIdempotent() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let first = try fixture.store(), second = try fixture.store()
        let initial = try first.patch(kind: .session, itemID: "a", change: .setDetails(displayName: "原名称", note: "原备注"))
        let baseline = try XCTUnwrap(initial.entry(kind: .session, itemID: "a"))
        _ = try second.patch(kind: .session, itemID: "a", change: .setDisplayName("别人改名"))
        let before = try Data(contentsOf: first.fileURL)
        XCTAssertThrowsError(try first.patch(kind: .session, itemID: "a",
                                             change: .setDetails(displayName: "我的改名", note: "我的新备注"), expectedEntry: baseline))
        XCTAssertEqual(try Data(contentsOf: first.fileURL), before)
        let current = try XCTUnwrap(second.load().entry(kind: .session, itemID: "a"))
        XCTAssertEqual(current.note, "原备注")
        XCTAssertThrowsError(try SessionManagementStore.applying(change: .setDisplayName("我的改名"), to: current, expectedEntry: baseline))
        let idempotent = try first.patch(kind: .session, itemID: "a", change: .setDisplayName("别人改名"), expectedEntry: baseline)
        XCTAssertEqual(idempotent.entry(kind: .session, itemID: "a")?.displayName, "别人改名")
        XCTAssertEqual(try Data(contentsOf: first.fileURL), before)
        XCTAssertThrowsError(try first.patch(kind: .session, itemID: "a", change: .clear, expectedEntry: baseline))
        XCTAssertEqual(try Data(contentsOf: first.fileURL), before)
        XCTAssertThrowsError(try first.patch(kind: .session, itemID: "a", change: .setNote("备注"),
                                             expectedEntry: SessionManagementEntry(kind: .project, itemID: "a")))
        XCTAssertEqual(try Data(contentsOf: first.fileURL), before)
        let absent = SessionManagementEntry(kind: .project, itemID: "new")
        _ = try first.patch(kind: .project, itemID: "new", change: .setFavorite(true), expectedEntry: absent)
        let merged = try second.patch(kind: .project, itemID: "new", change: .setNote("新增备注"), expectedEntry: absent)
        XCTAssertEqual(merged.entry(kind: .project, itemID: "new")?.isFavorite, true)
        XCTAssertEqual(merged.entry(kind: .project, itemID: "new")?.note, "新增备注")
    }

    func testRootPhysicalAliasesShareNamespaceAndDifferentRootsStayIsolated() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let original = try fixture.store()
        _ = try original.patch(kind: .session, itemID: "stable-id", change: .setNote("跨路径保留"))
        let alias = fixture.base.appendingPathComponent("source-alias", isDirectory: true)
        XCTAssertEqual(symlink(fixture.root.path, alias.path), 0)
        let physicalPointer = try XCTUnwrap(fixture.root.path.withCString { realpath($0, nil) })
        let physical = URL(fileURLWithPath: String(cString: physicalPointer), isDirectory: true)
        free(physicalPointer)
        for root in [fixture.root, physical, alias] {
            let store = try SessionManagementStore(directoryURL: fixture.directory, sourceRootURL: root)
            XCTAssertEqual(store.fileURL, original.fileURL)
            XCTAssertEqual(try store.load().entry(kind: .session, itemID: "stable-id")?.note, "跨路径保留")
        }
        let anotherRoot = fixture.base.appendingPathComponent("another-source", isDirectory: true)
        try FileManager.default.createDirectory(at: anotherRoot, withIntermediateDirectories: true)
        let other = try SessionManagementStore(directoryURL: fixture.directory, sourceRootURL: anotherRoot)
        XCTAssertNotEqual(other.fileURL, original.fileURL)
        XCTAssertTrue(try other.load().entries.isEmpty)
        try FileManager.default.copyItem(at: original.fileURL, to: other.fileURL)
        let copied = try Data(contentsOf: other.fileURL)
        XCTAssertThrowsError(try other.load())
        XCTAssertThrowsError(try other.patch(kind: .session, itemID: "new", change: .setFavorite(true)))
        XCTAssertEqual(try Data(contentsOf: other.fileURL), copied)
    }

    func testManagementDirectoriesWithinSourcesCannotBeCreatedOrModified() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let alias = fixture.base.appendingPathComponent("root-alias", isDirectory: true)
        XCTAssertEqual(symlink(fixture.root.path, alias.path), 0)
        for source in [fixture.root, alias] {
            for location in [fixture.root, fixture.root.appendingPathComponent("management"),
                             fixture.root.appendingPathComponent("sessions/management"),
                             alias.appendingPathComponent("archived_sessions/management")] {
                XCTAssertThrowsError(try SessionManagementStore(directoryURL: location, sourceRootURL: source))
            }
        }
        let absentRoot = fixture.base.appendingPathComponent("future-source", isDirectory: true)
        XCTAssertThrowsError(try SessionManagementStore(directoryURL: absentRoot.appendingPathComponent("metadata"), sourceRootURL: absentRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("management").path))
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
    }

    func testInvalidDetailsAreAtomicAndHaveCharacterAndByteLimits() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try store.patch(kind: .session, itemID: "one", change: .setDetails(displayName: "原名称", note: "原备注"))
        let original = try Data(contentsOf: store.fileURL)
        for change in [SessionManagementChange.setDetails(displayName: "新名称", note: String(repeating: "a", count: 4_001)),
                       .setDisplayName(String(repeating: "a", count: 121)),
                       .setDisplayName(String(repeating: "👨‍👩‍👧‍👦", count: 60)),
                       .setDisplayName("多行\n名称"),
                       .setNote(String(repeating: "👨‍👩‍👧‍👦", count: 1_000)),
                       .setNote("无效\0备注")] {
            XCTAssertThrowsError(try store.patch(kind: .session, itemID: "one", change: change))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        }
        for identity in ["", "bad\0id", "bad\nidentity", String(repeating: "a", count: 8_193)] {
            XCTAssertThrowsError(try store.patch(kind: .session, itemID: identity, change: .setFavorite(true)))
        }
        let boundary = try store.patch(kind: .session, itemID: String(repeating: "a", count: 8_192),
                                       change: .setDetails(displayName: String(repeating: "中", count: 120),
                                                           note: String(repeating: "中", count: 4_000)))
        XCTAssertEqual(boundary.entries.count, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
    }

    func testInvalidInitialInputDoesNotCreateStorageAndSharedValidationMatchesDisk() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store()
        XCTAssertThrowsError(try store.patch(kind: .session, itemID: "valid", change: .setDetails(displayName: "名称", note: String(repeating: "a", count: 4_001))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        let input = SessionManagementEntry(kind: .project, itemID: "same-id", isFavorite: true)
        let change = SessionManagementChange.update(isFavorite: nil, displayName: .set("  本地名称  "), note: .set("  保留空格  "))
        let validated = try SessionManagementStore.applying(change: change, to: input)
        _ = try store.patch(kind: .project, itemID: "same-id", change: .setFavorite(true))
        let persisted = try store.patch(kind: .project, itemID: "same-id", change: change)
        XCTAssertEqual(persisted.entry(kind: .project, itemID: "same-id"), validated)
        let joinedEmoji = try store.patch(kind: .project, itemID: "same-id", change: .setDisplayName("👨‍👩‍👧‍👦 项目"))
        XCTAssertEqual(joinedEmoji.entry(kind: .project, itemID: "same-id")?.displayName, "👨‍👩‍👧‍👦 项目")
    }

    func testEntryAndTotalByteCapacityRejectWithoutDiscardingMetadata() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let single = try fixture.store(limits: .init(maximumEntries: 1))
        _ = try single.patch(kind: .session, itemID: "a", change: .setFavorite(true))
        let original = try Data(contentsOf: single.fileURL)
        XCTAssertThrowsError(try single.patch(kind: .project, itemID: "b", change: .setFavorite(true)))
        XCTAssertEqual(try Data(contentsOf: single.fileURL), original)
        let small = try fixture.store(limits: .init(maximumBytes: original.count + 1))
        XCTAssertThrowsError(try small.patch(kind: .session, itemID: "a", change: .setNote(String(repeating: "x", count: 100))))
        XCTAssertEqual(try Data(contentsOf: single.fileURL), original)
        _ = try single.patch(kind: .session, itemID: "a", change: .clear)
        let replacement = try single.patch(kind: .project, itemID: "b", change: .setFavorite(true))
        XCTAssertEqual(replacement.entries.count, 1)
        XCTAssertEqual(replacement.entries.first?.itemID, "b")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.hasSuffix(".tmp") })
    }

    func testCorruptionUnsupportedVersionAndInvalidEntriesAlwaysPreserveOriginalFile() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try store.patch(kind: .session, itemID: "a", change: .setFavorite(true))
        let original = try Data(contentsOf: store.fileURL)
        let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var wrongVersion = dictionary; wrongVersion["version"] = 999
        var wrongRoot = dictionary; wrongRoot["rootPath"] = "/another-source"
        var duplicate = dictionary
        let entries = try XCTUnwrap(dictionary["entries"] as? [[String: Any]])
        duplicate["entries"] = entries + entries
        var invalid = dictionary, emptyEntry = entries[0]
        emptyEntry["isFavorite"] = false; invalid["entries"] = [emptyEntry]
        var hugeCount = dictionary; hugeCount["entries"] = Array(repeating: entries[0], count: 2_001)
        let invalidFiles = [Data(), Data("not-json".utf8), Data(original.dropLast()),
                            try JSONSerialization.data(withJSONObject: wrongVersion),
                            try JSONSerialization.data(withJSONObject: wrongRoot),
                            try JSONSerialization.data(withJSONObject: duplicate),
                            try JSONSerialization.data(withJSONObject: invalid),
                            try JSONSerialization.data(withJSONObject: hugeCount),
                            Data(repeating: 65, count: 512 * 1_024 + 1)]
        for broken in invalidFiles {
            try broken.write(to: store.fileURL)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.patch(kind: .project, itemID: "new", change: .setFavorite(true)))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), broken)
            XCTAssertEqual(try Data(contentsOf: fixture.originalLog), fixture.originalBytes)
        }
    }

    func testSymlinkHardLinkAndBroadPermissionsAreNeverFollowedOrOverwritten() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let outside = fixture.base.appendingPathComponent("outside.json")
        let bytes = Data("outside-private-data".utf8)
        try bytes.write(to: outside); XCTAssertEqual(chmod(outside.path, 0o600), 0)
        XCTAssertEqual(symlink(outside.path, store.fileURL.path), 0)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.patch(kind: .session, itemID: "a", change: .setFavorite(true)))
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertEqual(unlink(store.fileURL.path), 0)
        XCTAssertEqual(link(outside.path, store.fileURL.path), 0)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.patch(kind: .session, itemID: "a", change: .setFavorite(true)))
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertEqual(unlink(store.fileURL.path), 0)
        _ = try store.patch(kind: .session, itemID: "a", change: .setFavorite(true))
        let original = try Data(contentsOf: store.fileURL)
        XCTAssertEqual(chmod(store.fileURL.path, 0o644), 0)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.patch(kind: .session, itemID: "a", change: .setNote("覆盖")))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(chmod(store.fileURL.path, 0o600), 0)
        XCTAssertEqual(chmod(fixture.directory.path, 0o755), 0)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.patch(kind: .session, itemID: "a", change: .clear))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testUnsafeLockAndDirectoryReplacementCannotRedirectWrites() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let store = try fixture.store()
        XCTAssertEqual(symlink(outside.path, fixture.directory.path), 0)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.patch(kind: .session, itemID: "a", change: .setFavorite(true)))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertEqual(unlink(fixture.directory.path), 0)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let outsideFile = outside.appendingPathComponent("private")
        try Data("private".utf8).write(to: outsideFile); XCTAssertEqual(chmod(outsideFile.path, 0o600), 0)
        let lock = store.fileURL.deletingPathExtension().appendingPathExtension("lock")
        XCTAssertEqual(symlink(outsideFile.path, lock.path), 0)
        XCTAssertThrowsError(try store.patch(kind: .session, itemID: "a", change: .setFavorite(true)))
        XCTAssertEqual(unlink(lock.path), 0)
        XCTAssertEqual(link(outsideFile.path, lock.path), 0)
        XCTAssertThrowsError(try store.patch(kind: .session, itemID: "a", change: .setFavorite(true)))
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "private")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let parent = fixture.base.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let nested = try SessionManagementStore(directoryURL: parent.appendingPathComponent("metadata"), sourceRootURL: fixture.root)
        try FileManager.default.removeItem(at: parent)
        XCTAssertEqual(symlink(outside.path, parent.path), 0)
        XCTAssertThrowsError(try nested.load())
        XCTAssertThrowsError(try nested.patch(kind: .session, itemID: "a", change: .setFavorite(true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("metadata").path))
    }

    func testCancelledReadAndPatchDoNotCreateFilesAndWaitingFileLockIsCancellable() throws {
        let fixture = try ManagementFixture(); defer { fixture.remove() }
        let store = try fixture.store()
        for operation in 0..<2 {
            let outcome = ManagementOutcome(), finished = DispatchSemaphore(value: 0)
            let task = Task.detached {
                while !Task.isCancelled { await Task.yield() }
                do {
                    if operation == 0 { _ = try store.load() }
                    else { _ = try store.patch(kind: .session, itemID: "a", change: .setFavorite(true)) }
                } catch { outcome.record(error) }
                finished.signal()
            }
            task.cancel()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(outcome.cancellationCount, 1)
            XCTAssertEqual(outcome.errorCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        }
        _ = try store.patch(kind: .session, itemID: "a", change: .setFavorite(true))
        let original = try Data(contentsOf: store.fileURL)
        let fileLock = Darwin.open(store.fileURL.deletingPathExtension().appendingPathExtension("lock").path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fileLock, 0)
        guard fileLock >= 0 else { return }
        defer { _ = flock(fileLock, LOCK_UN); Darwin.close(fileLock) }
        XCTAssertEqual(flock(fileLock, LOCK_EX | LOCK_NB), 0)
        let outcome = ManagementOutcome(), started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let task = Task.detached {
            started.signal()
            do { _ = try store.patch(kind: .session, itemID: "a", change: .setNote("不会保存")) }
            catch { outcome.record(error) }
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        task.cancel()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(outcome.cancellationCount, 1)
        XCTAssertEqual(outcome.errorCount, 0)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).contains { $0.hasSuffix(".tmp") })
    }

    private func permissions(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NSError(domain: "ManagementFixture", code: Int(errno)) }
        return info.st_mode & 0o777
    }
    private final class ManagementOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var errors = 0, cancellations = 0
        private var errorMessages: [String] = []
        var errorCount: Int { lock.lock(); defer { lock.unlock() }; return errors }
        var cancellationCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
        var messages: [String] { lock.lock(); defer { lock.unlock() }; return errorMessages }
        func record(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            if error is CancellationError { cancellations += 1 }
            else { errors += 1; errorMessages.append(String(describing: error)) }
        }
    }
    private final class ManagementFixture: @unchecked Sendable {
        let base: URL, root: URL, directory: URL, originalLog: URL
        let originalBytes = Data("only-original-body\n".utf8)
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("session-management-\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("codex", isDirectory: true)
            directory = base.appendingPathComponent("management", isDirectory: true)
            originalLog = root.appendingPathComponent("sessions/original.jsonl")
            try FileManager.default.createDirectory(at: originalLog.deletingLastPathComponent(), withIntermediateDirectories: true)
            try originalBytes.write(to: originalLog)
        }
        func store(limits: SessionManagementLimits = .init()) throws -> SessionManagementStore {
            try .init(directoryURL: directory, sourceRootURL: root, limits: limits)
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
