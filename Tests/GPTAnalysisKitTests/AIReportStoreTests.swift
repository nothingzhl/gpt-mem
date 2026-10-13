import Foundation
import XCTest
@testable import GPTAnalysisKit

final class AIReportStoreTests: XCTestCase {
    private let providerID = UUID(uuidString: "01020304-0506-0708-090a-0b0c0d0e0f10")!
    private let start = Date(timeIntervalSinceReferenceDate: 812_345_678.1234567)

    private func report(generationOffset: TimeInterval = 70, cached: Bool = false, summary: String = "存在内存增长，需要进一步核对。",
                        context: String = "打开了匿名会话。", labels: [String: String] = ["p1": "GPU · PID 424242 · 启动本机身份"],
                        reference: String = "memory.change", subject: String? = "p1") -> AISavedReport {
        let input = AIAnalysisInput(moduleID: "memory", moduleTitle: "内存分析", promptVersion: "1",
                                    guidance: "只引用冻结证据，不把假设当作事实。", windowStart: start,
                                    windowEnd: start.addingTimeInterval(60.000001),
                                    facts: [.init(id: "memory.change", title: "匿名内存变化", data: .object([
                                        "bytes": .number(123456), "anonymousSubject": .string("p1")]))],
                                    subjects: [.init(id: "p1", label: "GPU p1", canInspect: true)], context: context)
        let result = AIAnalysisResult(summary: summary,
                                      observations: [.init(text: "已测占用上升。", evidenceIDs: [reference])],
                                      hypotheses: [.init(title: "绘制活动", explanation: "可能与绘制有关，尚不能确认。",
                                                         evidenceIDs: [reference], missingEvidence: ["活动前后的对照"])],
                                      nextSteps: [.init(subjectID: subject, action: "检查匿名实例", purpose: "验证增长是否持续")],
                                      limitations: ["不能据此证明对象泄漏。"])
        let record = AIAnalysisRecord(moduleID: input.moduleID, moduleTitle: input.moduleTitle, providerID: providerID,
                                      providerName: "fixture-provider", model: "fixture-model", inputFingerprint: String(repeating: "a", count: 64),
                                      windowStart: input.windowStart, windowEnd: input.windowEnd,
                                      generatedAt: start.addingTimeInterval(generationOffset), result: result, wasCached: cached)
        return AISavedReport(record: record, input: input, subjectLabels: labels, windowSelectionSeconds: 300)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ai-report-checks-\(UUID().uuidString)", isDirectory: true)
    }

    private func fileURL(_ report: AISavedReport, in directory: URL) -> URL {
        directory.appendingPathComponent(report.id.uuidString.lowercased() + ".json")
    }

    func testEmptyLibraryDoesNotCreateDirectoriesAndReopeningRestoresAllEvidence() throws {
        let parent = temporaryDirectory(), directory = parent.appendingPathComponent("reports")
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = AIReportStore(directoryURL: directory)
        XCTAssertTrue(try store.loadCatalog().reports.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        let original = report()
        XCTAssertEqual(try store.save(original), original)
        let reopened = try AIReportStore(directoryURL: directory).loadCatalog()
        XCTAssertEqual(reopened.reports, [original])
        XCTAssertTrue(reopened.warnings.isEmpty)
        XCTAssertEqual(reopened.reports.first?.record.generatedAt, original.record.generatedAt)
        XCTAssertEqual(reopened.reports.first?.input.windowStart, original.input.windowStart)
        XCTAssertEqual(reopened.reports.first?.input.windowEnd, original.input.windowEnd)
        XCTAssertEqual(reopened.reports.first?.subjectLabels, original.subjectLabels)
        XCTAssertEqual(reopened.reports.first?.input.facts, original.input.facts)
        XCTAssertEqual(reopened.reports.first?.input.context, original.input.context)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: fileURL(original, in: directory).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        XCTAssertEqual(fileMode?.intValue, 0o600)
        let data = try String(contentsOf: fileURL(original, in: directory), encoding: .utf8)
        XCTAssertFalse(data.contains("apiKey"))
        XCTAssertFalse(data.contains("baseURL"))
    }

    func testCachedResultHasStableIdentityAndCannotOverwriteEvidence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIReportStore(directoryURL: directory), original = report(), cached = report(cached: true)
        XCTAssertEqual(original.id, cached.id)
        _ = try store.save(original)
        let bytes = try Data(contentsOf: fileURL(original, in: directory))
        XCTAssertEqual(try store.save(cached), original)
        let changedSelection = AISavedReport(record: cached.record, input: cached.input, subjectLabels: cached.subjectLabels,
                                            windowSelectionSeconds: 600)
        XCTAssertEqual(changedSelection.id, original.id)
        XCTAssertEqual(try store.save(changedSelection), original)
        XCTAssertEqual(try store.loadCatalog().reports.first?.windowSelectionSeconds, 300)
        XCTAssertEqual(try store.loadCatalog().reports.count, 1)
        XCTAssertEqual(try Data(contentsOf: fileURL(original, in: directory)), bytes)
        XCTAssertThrowsError(try store.save(report(summary: "相同编号但不同结论。")))
        XCTAssertThrowsError(try store.save(report(labels: ["p1": "被更改的本机身份"])))
        XCTAssertEqual(try Data(contentsOf: fileURL(original, in: directory)), bytes)
        let fresh = report(generationOffset: 70.0000002)
        XCTAssertNotEqual(fresh.id, original.id)
        _ = try store.save(fresh)
        XCTAssertEqual(try store.loadCatalog().reports, [fresh, original])
    }

    func testOneCorruptReportIsIsolatedAndCannotBeSilentlyOverwritten() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIReportStore(directoryURL: directory), first = report(), second = report(generationOffset: 80)
        _ = try store.save(first); _ = try store.save(second)
        let corrupt = Data("{broken report".utf8)
        try corrupt.write(to: fileURL(first, in: directory))
        let catalog = try store.loadCatalog()
        XCTAssertEqual(catalog.reports, [second])
        XCTAssertEqual(catalog.warnings.count, 1)
        XCTAssertThrowsError(try store.save(first))
        XCTAssertEqual(try Data(contentsOf: fileURL(first, in: directory)), corrupt)
        XCTAssertThrowsError(try store.remove(first.id))
        XCTAssertEqual(try Data(contentsOf: fileURL(first, in: directory)), corrupt)
    }

    func testRemovedReportsAreRecoverableAndCachedSavesDoNotResurrectThem() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIReportStore(directoryURL: directory), original = report()
        _ = try store.save(original)
        try store.remove(original.id)
        XCTAssertTrue(try store.loadCatalog().reports.isEmpty)
        let trash = directory.appendingPathComponent("trash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(original, in: trash).path))
        let trashMode = try FileManager.default.attributesOfItem(atPath: trash.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(trashMode?.intValue, 0o700)
        XCTAssertEqual(try store.save(report(cached: true)), original)
        XCTAssertTrue(try store.loadCatalog().reports.isEmpty)
        XCTAssertEqual(try AIReportStore(directoryURL: directory).restore(original.id), original)
        XCTAssertEqual(try store.loadCatalog().reports, [original])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(original, in: trash).path))
        XCTAssertThrowsError(try store.restore(original.id))
        XCTAssertThrowsError(try store.remove(UUID()))
        XCTAssertEqual(try store.loadCatalog().reports, [original])
    }

    func testSymlinkedDirectoryFileAndTrashNeverRedirectStorage() throws {
        let parent = temporaryDirectory(), outside = parent.appendingPathComponent("outside"), storage = parent.appendingPathComponent("storage")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: storage, withDestinationURL: outside)
        let linkedStore = AIReportStore(directoryURL: storage)
        XCTAssertThrowsError(try linkedStore.loadCatalog())
        XCTAssertThrowsError(try linkedStore.save(report()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: storage)
        let store = AIReportStore(directoryURL: storage), original = report()
        _ = try store.save(original)
        let protected = outside.appendingPathComponent("protected.json"), sentinel = Data("untouched".utf8)
        try sentinel.write(to: protected)
        try FileManager.default.removeItem(at: fileURL(original, in: storage))
        try FileManager.default.createSymbolicLink(at: fileURL(original, in: storage), withDestinationURL: protected)
        XCTAssertThrowsError(try store.save(original))
        XCTAssertTrue(try store.loadCatalog().reports.isEmpty)
        XCTAssertEqual(try store.loadCatalog().warnings.count, 1)
        XCTAssertThrowsError(try store.remove(original.id))
        XCTAssertEqual(try Data(contentsOf: protected), sentinel)
        try FileManager.default.removeItem(at: fileURL(original, in: storage))
        _ = try store.save(original)
        try FileManager.default.createSymbolicLink(at: storage.appendingPathComponent("trash"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.remove(original.id))
        XCTAssertEqual(try store.loadCatalog().reports, [original])
        XCTAssertEqual(try Data(contentsOf: protected), sentinel)
    }

    func testInventedReferencesWindowMismatchAndUnsafeFieldsCannotBeSaved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIReportStore(directoryURL: directory)
        XCTAssertThrowsError(try store.save(report(reference: "invented")))
        XCTAssertThrowsError(try store.save(report(subject: "other")))
        XCTAssertThrowsError(try store.save(report(labels: ["unavailable": "PID mapping"])))
        XCTAssertThrowsError(try store.save(report(context: String(repeating: "x", count: 8_193))))
        let original = report(), record = original.record
        let changed = AIAnalysisRecord(moduleID: "another-module", moduleTitle: record.moduleTitle, providerID: record.providerID,
                                       providerName: record.providerName, model: record.model, inputFingerprint: record.inputFingerprint,
                                       windowStart: record.windowStart.addingTimeInterval(0.1), windowEnd: record.windowEnd,
                                       generatedAt: record.generatedAt, result: record.result)
        XCTAssertThrowsError(try store.save(AISavedReport(record: changed, input: original.input, windowSelectionSeconds: 300)))
        XCTAssertThrowsError(try store.save(AISavedReport(record: record, input: original.input, windowSelectionSeconds: .infinity)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRequestedSelectionDoesNotRejectAnOlderBaselineAcrossSamplingGap() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = report()
        // The selection is a UI preference. A historical baseline before its lower
        // boundary can make the frozen actual observation longer than this preference.
        let gap = AISavedReport(record: original.record, input: original.input, subjectLabels: original.subjectLabels,
                                windowSelectionSeconds: 30)
        let store = AIReportStore(directoryURL: directory)
        _ = try store.save(gap)
        XCTAssertEqual(try store.loadCatalog().reports, [gap])
        let json = try AIReportExport.json(gap)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["durationSeconds"] as? Double, gap.input.windowEnd.timeIntervalSince(gap.input.windowStart))
        XCTAssertGreaterThan(try XCTUnwrap(object["durationSeconds"] as? Double), gap.windowSelectionSeconds)
    }

    func testOversizedDeepAndWrongVersionFilesAreSkippedWithoutDeletion() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIReportStore(directoryURL: directory), original = report()
        _ = try store.save(original)
        let oversized = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        try Data(repeating: 32, count: 524_289).write(to: oversized)
        let deep = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        try Data((String(repeating: "[", count: 100) + "0" + String(repeating: "]", count: 100)).utf8).write(to: deep)
        let future = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL(original, in: directory))) as? [String: Any])
        object["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: future)
        let catalog = try store.loadCatalog()
        XCTAssertEqual(catalog.reports, [original])
        XCTAssertEqual(catalog.warnings.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oversized.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: deep.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: future.path))
    }

    func testExportIncludesAnonymousFrozenEvidenceAndExcludesInternalMappings() throws {
        let original = report(), json = try AIReportExport.json(original), markdown = try AIReportExport.markdown(original)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        for output in [text, markdown] {
            XCTAssertFalse(output.contains("424242"))
            XCTAssertFalse(output.contains("启动本机身份"))
            XCTAssertFalse(output.contains(original.record.providerID.uuidString))
            XCTAssertFalse(output.contains(original.record.inputFingerprint))
            XCTAssertFalse(output.contains("subjectLabels"))
            XCTAssertFalse(output.contains("providerID"))
            XCTAssertFalse(output.contains("inputFingerprint"))
            XCTAssertTrue(output.contains("fixture-provider") || output.contains("fixture\\-provider"))
            XCTAssertTrue(output.contains("fixture-model") || output.contains("fixture\\-model"))
            XCTAssertTrue(output.contains("memory.change") || output.contains("memory\\.change"))
            XCTAssertTrue(output.contains("GPU p1"))
            XCTAssertTrue(output.contains(original.input.context))
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["windowStart"] as? Double, original.input.windowStart.timeIntervalSince1970)
        XCTAssertEqual(object["windowEnd"] as? Double, original.input.windowEnd.timeIntervalSince1970)
        XCTAssertEqual(object["durationSeconds"] as? Double, original.input.windowEnd.timeIntervalSince(original.input.windowStart))
        XCTAssertNotEqual(object["windowStart"] as? Double, floor(original.input.windowStart.timeIntervalSince1970))
        XCTAssertFalse(object.keys.contains("record"))
        XCTAssertFalse(object.keys.contains("windowSelectionSeconds"))
    }

    func testExportTreatsMarkdownHTMLAndCodeDelimitersAsLiteralText() throws {
        let unsafe = "<script>alert('x')</script>\n# Heading\n[click](javascript:alert(1))\n```\n<img src=x onerror=alert(1)>"
        let saved = report(summary: unsafe, context: unsafe)
        let markdown = try AIReportExport.markdown(saved), data = try AIReportExport.json(saved)
        XCTAssertFalse(markdown.contains("<script>"))
        XCTAssertFalse(markdown.contains("<img"))
        XCTAssertFalse(markdown.contains("\n# Heading"))
        XCTAssertFalse(markdown.contains("[click](javascript:"))
        XCTAssertFalse(markdown.contains("\n```"))
        XCTAssertTrue(markdown.contains("&lt;script&gt;"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("<script>"))
        XCTAssertTrue(json.contains("\\u003cscript\\u003e"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["summary"] as? String, unsafe)
        XCTAssertEqual(object["activityContext"] as? String, unsafe)
        XCTAssertLessThanOrEqual(data.count, 1_048_576)
        XCTAssertLessThanOrEqual(markdown.utf8.count, 1_048_576)
    }

    func testLargeCatalogIsBoundedAndNeverDeletesOlderFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<1_005 {
            try Data("{}".utf8).write(to: directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json"))
        }
        let catalog = try AIReportStore(directoryURL: directory).loadCatalog()
        XCTAssertTrue(catalog.reports.isEmpty)
        XCTAssertTrue(catalog.warnings.contains(where: { $0.contains("1,000") }))
        XCTAssertLessThanOrEqual(catalog.warnings.count, 100)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1_005)
    }

    func testCancelledRefreshAndSaveStopWithoutWarningsOrCreatingStorage() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIReportStore(directoryURL: directory), original = report()
        for save in [false, true] {
            let finished = DispatchSemaphore(value: 0), probe = AIReportCancellationProbe()
            let task = Task.detached {
                while !probe.canStart { await Task.yield() }
                do {
                    if save { _ = try store.save(original) } else { _ = try store.loadCatalog() }
                    probe.finish(false)
                } catch is CancellationError { probe.finish(true) }
                catch { probe.finish(false) }
                finished.signal()
            }
            task.cancel(); probe.permitStart()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
            XCTAssertTrue(probe.wasCancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testLocationDistinguishesActiveRemovedAndMissingWithoutCreatingStorage() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIReportStore(directoryURL: directory), original = report()
        XCTAssertEqual(try store.location(of: original.id), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        _ = try store.save(original)
        XCTAssertEqual(try store.location(of: original.id), .active)
        try store.remove(original.id)
        XCTAssertEqual(try store.location(of: original.id), .removed)
        XCTAssertEqual(try store.location(of: UUID()), .missing)
        _ = try store.restore(original.id)
        XCTAssertEqual(try store.location(of: original.id), .active)
    }

    func testCatalogLimitPrefersRecentlyModifiedFilesInsteadOfUUIDOrder() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldTime = Date(timeIntervalSince1970: 1_500_000_000)
        // Deliberately choose names before the valid report in UUID order. The old
        // lexicographic prefix logic would exclude the newly saved valid report.
        for index in 0..<1_000 {
            let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012x", index)))
            let url = directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: oldTime], ofItemAtPath: url.path)
        }
        let original = report(), store = AIReportStore(directoryURL: directory)
        _ = try store.save(original)
        let catalog = try store.loadCatalog()
        XCTAssertEqual(catalog.reports, [original])
        XCTAssertTrue(catalog.warnings.contains(where: { $0.contains("1,000") && $0.contains("最近修改") }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1_001)
        XCTAssertEqual(try store.location(of: original.id), .active)
        // Presence remains accurate even for a regular file outside catalog limits.
        let excluded = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000003e7"))
        XCTAssertEqual(try store.location(of: excluded), .active)
    }
}

private final class AIReportCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var ready = false
    var canStart: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func permitStart() { lock.lock(); ready = true; lock.unlock() }
    func finish(_ value: Bool) { lock.lock(); cancelled = value; lock.unlock() }
}
