import Foundation
import XCTest
@testable import GPTAnalysisKit

final class AIPromptTemplateTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("prompt-tests-" + UUID().uuidString) }
    private func permissions(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }

    func testEmptyLibraryIsReadOnlyAndPresetsHaveReusableScopes() throws {
        let root = directory()
        let store = AIPromptTemplateStore(directoryURL: root)
        let catalog = try store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(catalog.revision, 0)
        XCTAssertTrue(catalog.choices(for: "memory").contains { $0.id == "builtin.concise" })
        XCTAssertFalse(catalog.choices(for: "memory").contains { $0.id == "builtin.handoff.continue" })
        XCTAssertTrue(catalog.choices(for: "future.module").contains { $0.moduleID == nil })
    }

    func testSaveAndDefaultSurviveReopeningWithPrivatePermissions() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AIPromptTemplateStore(directoryURL: root)
        let template = AIPromptTemplate(title: "我的交接", text: "优先列出验收缺口", moduleID: "session.handoff")
        let saved = try store.save(template, expected: nil)
        XCTAssertEqual(saved.templates[0], template)
        let defaulted = try store.setDefault(template.id, for: "session.handoff")
        XCTAssertEqual(defaulted.defaults["session.handoff"], template.id)
        let reopened = try AIPromptTemplateStore(directoryURL: root).load()
        XCTAssertEqual(reopened.templates, [template])
        XCTAssertEqual(reopened.defaults, defaulted.defaults)
        XCTAssertEqual(try permissions(root), 0o700)
        XCTAssertEqual(try permissions(root.appendingPathComponent("library.json")), 0o600)
        XCTAssertThrowsError(try store.setDefault(template.id, for: "memory"))
    }

    func testStaleEditsCannotOverwriteAndUnrelatedChangesAreMerged() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = AIPromptTemplateStore(directoryURL: root), second = AIPromptTemplateStore(directoryURL: root)
        let original = AIPromptTemplate(title: "A", text: "old")
        _ = try first.save(original, expected: nil)
        let unrelated = AIPromptTemplate(title: "B", text: "other")
        _ = try second.save(unrelated, expected: nil)
        var edited = original; edited.text = "new"
        let catalog = try first.save(edited, expected: original)
        XCTAssertEqual(catalog.templates.count, 2)
        XCTAssertEqual(catalog.templates.first { $0.id == original.id }?.revision, 2)
        XCTAssertThrowsError(try second.save(original, expected: original))
        XCTAssertEqual(try first.load().templates.first { $0.id == original.id }?.text, "new")
        XCTAssertThrowsError(try first.save(AIPromptTemplate.builtIns[0], expected: nil))
    }

    func testArchiveRestoreAndScopeChangeKeepDefaultsValid() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AIPromptTemplateStore(directoryURL: root)
        let template = AIPromptTemplate(title: "通用", text: "逐项引用证据")
        _ = try store.save(template, expected: nil)
        _ = try store.setDefault(template.id, for: "memory")
        var changed = template; changed.moduleID = "session.handoff"
        let scoped = try store.save(changed, expected: template)
        XCTAssertNil(scoped.defaults["memory"])
        let original = scoped.templates[0]
        _ = try store.setDefault(template.id, for: "session.handoff")
        var archived = original; archived.isArchived = true
        let removed = try store.save(archived, expected: original)
        XCTAssertNil(removed.defaults["session.handoff"])
        XCTAssertFalse(removed.choices(for: "session.handoff").contains { $0.id == template.id })
        let old = removed.templates[0]
        var restored = old; restored.isArchived = false
        let recovered = try store.save(restored, expected: old)
        XCTAssertEqual(recovered.templates[0].text, template.text)
        XCTAssertTrue(recovered.choices(for: "session.handoff").contains { $0.id == template.id })
    }

    func testCorruptDataAndUnsafeLinksArePreserved() throws {
        let parent = directory(), root = parent.appendingPathComponent("private")
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = AIPromptTemplateStore(directoryURL: root)
        let template = AIPromptTemplate(title: "A", text: "keep")
        _ = try store.save(template, expected: nil)
        let file = root.appendingPathComponent("library.json")
        let broken = Data("{broken".utf8)
        try broken.write(to: file)
        XCTAssertThrowsError(try store.save(template, expected: template))
        XCTAssertEqual(try Data(contentsOf: file), broken)
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try AIPromptTemplateStore(directoryURL: alias).load())
        let original = parent.appendingPathComponent("original")
        try FileManager.default.moveItem(at: file, to: original)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: original), broken)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: original, to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: original), broken)
    }

    func testBoundsAndConcurrentStoresNeverLoseUnrelatedTemplates() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = AIPromptTemplateStore(directoryURL: root)
        _ = try first.setDefault(nil, for: "memory")
        XCTAssertThrowsError(try first.save(.init(title: "", text: "x"), expected: nil))
        XCTAssertThrowsError(try first.save(.init(title: "A", text: String(repeating: "字", count: 4_000)), expected: nil))
        let group = DispatchGroup(), resultLock = NSLock()
        var failures = 0
        for index in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { _ = try AIPromptTemplateStore(directoryURL: root).save(.init(title: "\(index)", text: "same"), expected: nil) }
                catch { resultLock.lock(); failures += 1; resultLock.unlock() }
            }
        }
        group.wait()
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(try first.load().templates.count, 8)
    }

    func testFrozenPromptExportAndBackwardCompatibleDecode() throws {
        let template = AIPromptTemplate(title: "复盘", text: "优先写验收缺口", moduleID: "fixture")
        let start = Date(timeIntervalSince1970: 100)
        let base = AIAnalysisInput(moduleID: "fixture", moduleTitle: "Fixture", promptVersion: "1", guidance: "只引用证据", windowStart: start,
            windowEnd: start.addingTimeInterval(1), facts: [.init(id: "fact", title: "事实", data: .string("事实"))], subjects: [])
        let applied = AIAnalysisPrompt(templateID: template.id, title: template.title, revision: 1, text: template.text + "，给出下一步", isModified: true)
        let input = try base.applying(prompt: applied)
        XCTAssertEqual(input.guidance, base.guidance)
        XCTAssertEqual(input.facts, base.facts)
        XCTAssertNotEqual(try base.validated(), try input.validated())
        let result = AIAnalysisResult(summary: "摘要", observations: [.init(text: "事实", evidenceIDs: ["fact"])], hypotheses: [],
            nextSteps: [.init(subjectID: nil, action: "核对", purpose: "确认")], limitations: ["仅摘录"])
        let record = AIAnalysisRecord(moduleID: "fixture", moduleTitle: "Fixture", providerID: UUID(), providerName: "Mock", model: "Mock",
            inputFingerprint: String(repeating: "a", count: 64), windowStart: start, windowEnd: start.addingTimeInterval(1), result: result)
        let report = AISavedReport(record: record, input: input, windowSelectionSeconds: 1)
        XCTAssertTrue(try AIReportExport.markdown(report).contains("优先写验收缺口，给出下一步"))
        let json = String(decoding: try AIReportExport.json(report), as: UTF8.self)
        XCTAssertTrue(json.contains("优先写验收缺口"))
        XCTAssertFalse(json.contains(template.id))
        let old = try AIAnalysisCodec.decoder().decode(AIAnalysisInput.self, from: AIAnalysisCodec.encoder().encode(base))
        XCTAssertNil(old.prompt)
        XCTAssertThrowsError(try base.applying(prompt: .init(text: String(repeating: "x", count: 9_000))))
    }
}
