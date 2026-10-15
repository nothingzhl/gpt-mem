import Foundation
import Darwin
import XCTest
@testable import GPTAnalysisKit

final class CodexMemoryEditingTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("original-memory-test-" + UUID().uuidString) }
    func testStreamingParserKeepsExactRangesContinuationAndFinalLine() throws {
        let text = "# Rules\r\n- first\r\n  ```swift\r\n  - nested\r\n  ```\r\n\r\n# Second\n* last 👋"
        let items = CodexMemoryItem.parse(text)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].text, "- first\r\n  ```swift\r\n  - nested\r\n  ```\r\n\r\n")
        XCTAssertEqual(items[1].text, "* last 👋")
        XCTAssertEqual(items[1].context, "# Second")
        for item in items {
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: item.offset, length: item.length)), item.text)
            XCTAssertEqual(item.label, String((item.context + " · " + item.text).prefix(100)))
        }
        XCTAssertEqual(try items[1].replacing(in: text, with: "- 最后条目"), text.replacingOccurrences(of: "* last 👋", with: "- 最后条目"))
        XCTAssertEqual(try items[1].replacing(in: text, with: nil), (text as NSString).substring(to: items[1].offset))
        let forged = CodexMemoryItem(offset: items[1].offset, length: 1, text: "*", context: "# Second")
        XCTAssertThrowsError(try forged.replacing(in: text, with: "- 无效"))
    }
    func testParserPreservesUnicodeCRLFAndSkipsFencedCode() throws {
        let text = "# 项目\r\n\r\n- 中文👋\r\n  续行\r\n\r\n- 第二条\r\n\r\n```\r\n- 代码不是记忆\r\n```\r\n## 结束\r\n"
        let items = CodexMemoryItem.parse(text)
        XCTAssertEqual(items.count, 2)
        let nestedFence = "````markdown\n```\n- Not a memory\n```\n````\n- Real rule\n"
        XCTAssertEqual(CodexMemoryItem.parse(nestedFence).count, 1)
        XCTAssertTrue(CodexMemoryItem.parse(nestedFence)[0].text.contains("Real rule"))
        let replaced = try items[0].replacing(in: text, with: "- 新规则\r\n  保留缩进\r\n\r\n")
        XCTAssertTrue(replaced.contains("- 第二条\r\n\r\n```\r\n- 代码不是记忆\r\n```"))
        XCTAssertTrue(replaced.hasPrefix("# 项目\r\n\r\n- 新规则"))
        let deleted = try items[0].replacing(in: text, with: nil)
        XCTAssertFalse(deleted.contains("中文👋")); XCTAssertTrue(deleted.contains("- 第二条")); XCTAssertTrue(deleted.contains("## 结束"))
        XCTAssertThrowsError(try items[0].replacing(in: text, with: "- A\n- B\n"))
        XCTAssertThrowsError(try items[0].replacing(in: text, with: "- A\n# 新标题\n"))
        XCTAssertThrowsError(try items[0].replacing(in: text + "changed", with: "paragraph"))
    }
    func testOriginalEditDeleteAndRollbackBackUpWholeFile() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("memories"), backups = directory.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("MEMORY.md"), original = "# Rules\n- 中文\n\n- Keep\n"
        try Data(original.utf8).write(to: file)
        let editor = CodexMemoryEditor(backupDirectory: backups), item = CodexMemoryItem.parse(original)[0]
        let after = try item.replacing(in: original, with: nil)
        let backup = try editor.apply(root: source, original: original, replacement: after, action: "删除条目")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), after)
        XCTAssertEqual(backup.before, original)
        XCTAssertEqual(try editor.backups(), [backup])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backups.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backups.appendingPathComponent(backup.id + ".json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        _ = try editor.restore(backup, root: source)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
        XCTAssertEqual(try editor.backups().count, 2)
        XCTAssertThrowsError(try editor.restore(backup, root: source))
        try editor.removeBackup(backup)
        XCTAssertEqual(try editor.backups().count, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    }
    func testCodexUpdatesRejectBothSaveAndRollbackWithoutOverwrite() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("MEMORY.md"), editor = CodexMemoryEditor(backupDirectory: directory.appendingPathComponent("backups"))
        try Data("- Latest\n".utf8).write(to: file)
        XCTAssertThrowsError(try editor.apply(root: directory, original: "- Old\n", replacement: "- Edit\n", action: "编辑"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "- Latest\n")
        XCTAssertTrue(try editor.backups().isEmpty)
        let backup = try editor.apply(root: directory, original: "- Latest\n", replacement: "- Edit\n", action: "编辑")
        try Data("- Codex regenerated\n".utf8).write(to: file)
        XCTAssertThrowsError(try editor.restore(backup, root: directory))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "- Codex regenerated\n")
        XCTAssertThrowsError(try editor.restore(backup, root: directory.appendingPathComponent("elsewhere")))
    }
    func testLastEntryDeletionCanRestoreEmptyFileAndBackupLimitNeverDropsHistory() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("MEMORY.md"), editor = CodexMemoryEditor(backupDirectory: directory.appendingPathComponent("backups"))
        let original = "- Only rule\n"
        try Data(original.utf8).write(to: file)
        let deleted = try editor.apply(root: directory, original: original, replacement: "", action: "删除")
        XCTAssertEqual(try Data(contentsOf: file).count, 0)
        _ = try editor.restore(deleted, root: directory)
        var current = original
        for index in 3...20 {
            let next = "- Rule \(index)\n"
            _ = try editor.apply(root: directory, original: current, replacement: next, action: "编辑")
            current = next
        }
        XCTAssertEqual(try editor.backups().count, 20)
        XCTAssertThrowsError(try editor.apply(root: directory, original: current, replacement: "- Beyond\n", action: "编辑"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), current)
        try editor.removeBackup(deleted)
        _ = try editor.apply(root: directory, original: current, replacement: "- After cleanup\n", action: "编辑")
        XCTAssertEqual(try editor.backups().count, 20)
    }
    func testUnsafeSourcesAndBackupLinksAreRejected() throws {
        let directory = root(), outside = root(); defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("- Outside\n".utf8).write(to: outside)
        let file = directory.appendingPathComponent("MEMORY.md"), backupRoot = directory.appendingPathComponent("backups")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        let editor = CodexMemoryEditor(backupDirectory: backupRoot)
        XCTAssertThrowsError(try editor.apply(root: directory, original: "- Outside\n", replacement: "- Changed\n", action: "编辑"))
        try FileManager.default.removeItem(at: file); try FileManager.default.linkItem(at: outside, to: file)
        XCTAssertThrowsError(try editor.apply(root: directory, original: "- Outside\n", replacement: "- Changed\n", action: "编辑"))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "- Outside\n")
        try FileManager.default.removeItem(at: file); try Data("- Original\n".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: backupRoot, withDestinationURL: directory)
        XCTAssertThrowsError(try editor.apply(root: directory, original: "- Original\n", replacement: "- Changed\n", action: "编辑"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "- Original\n")
    }
}
