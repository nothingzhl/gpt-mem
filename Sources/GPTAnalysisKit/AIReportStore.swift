import Foundation
import CryptoKit
import Darwin

/// The complete frozen evidence belongs to a report, rather than to mutable UI state.
/// Local subject labels remain private; public exports use the anonymous input labels.
public struct AISavedReport: Codable, Equatable, Identifiable {
    public let id: UUID
    public let schemaVersion: Int
    public let record: AIAnalysisRecord
    public let input: AIAnalysisInput
    public let subjectLabels: [String: String]
    public let windowSelectionSeconds: TimeInterval

    public init(record: AIAnalysisRecord, input: AIAnalysisInput, subjectLabels: [String: String] = [:],
                windowSelectionSeconds: TimeInterval) {
        self.id = Self.identifier(for: record)
        self.schemaVersion = 1
        self.record = record
        self.input = input
        self.subjectLabels = subjectLabels
        self.windowSelectionSeconds = windowSelectionSeconds
    }

    private static func identifier(for record: AIAnalysisRecord) -> UUID {
        // Use separate encoded fields and the exact Date representation. Cache hits
        // change wasCached, but keep the same generation and therefore the same ID.
        let identity = Identity(moduleID: record.moduleID, fingerprint: record.inputFingerprint,
                                providerID: record.providerID, model: record.model, generatedAt: record.generatedAt)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(identity)) ?? Data()
        var hash = Array(SHA256.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x50
        hash[8] = (hash[8] & 0x3f) | 0x80
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    private struct Identity: Encodable {
        let moduleID: String
        let fingerprint: String
        let providerID: UUID
        let model: String
        let generatedAt: Date
    }

    internal func validate() throws {
        func text(_ value: String, limit: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit
        }
        guard schemaVersion == 1, id == Self.identifier(for: record),
              record.moduleID == input.moduleID, record.moduleTitle == input.moduleTitle,
              record.windowStart == input.windowStart, record.windowEnd == input.windowEnd,
              record.generatedAt.timeIntervalSinceReferenceDate.isFinite,
              text(input.moduleID, limit: 100), text(input.moduleTitle, limit: 1_024),
              text(input.promptVersion, limit: 100), text(record.providerName, limit: 1_024),
              text(record.model, limit: 512),
              record.inputFingerprint.utf8.count == 64,
              record.inputFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              windowSelectionSeconds.isFinite, windowSelectionSeconds > 0, windowSelectionSeconds <= 31_536_000,
              input.windowEnd.timeIntervalSince(input.windowStart).isFinite,
              input.facts.allSatisfy({ text($0.title, limit: 2_048) }),
              input.subjects.allSatisfy({ text($0.label, limit: 2_048) }),
              subjectLabels.count <= 50,
              subjectLabels.allSatisfy({ entry in
                  input.subjects.contains(where: { $0.id == entry.key }) && text(entry.value, limit: 4_096)
              }), subjectLabels.values.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
            throw AIReportStoreError.invalidReport("报告身份、时间范围或字段无效。")
        }
        var nodes = 0
        func check(_ value: AIJSONValue, depth: Int) throws {
            nodes += 1
            guard depth <= 24, nodes <= 24_000 else {
                throw AIReportStoreError.invalidReport("报告证据嵌套过深或数量过多。")
            }
            switch value {
            case .object(let values):
                for (key, child) in values {
                    guard key.utf8.count <= 2_048 else { throw AIReportStoreError.invalidReport("证据字段过长。") }
                    try check(child, depth: depth + 1)
                }
            case .array(let values): for child in values { try check(child, depth: depth + 1) }
            case .number(let value):
                guard value.isFinite else { throw AIReportStoreError.invalidReport("证据包含无效数值。") }
            default: break
            }
        }
        for fact in input.facts { try check(fact.data, depth: 0) }
        _ = try input.validated()
        try record.result.validate(against: input)
    }

    /// Cache status alone does not constitute a new report or replace original evidence.
    internal func hasSameContent(as other: AISavedReport) -> Bool {
        var first = record, second = other.record
        first.wasCached = false; second.wasCached = false
        return id == other.id && schemaVersion == other.schemaVersion && first == second && input == other.input
            && subjectLabels == other.subjectLabels
    }
}

public struct AIReportCatalog {
    public let reports: [AISavedReport]
    public let warnings: [String]
    public init(reports: [AISavedReport], warnings: [String] = []) { self.reports = reports; self.warnings = warnings }
}

/// File location is independent of a bounded catalog's visible subset.
public enum AIReportLocation: Equatable, Sendable {
    case active, removed, missing
}

public enum AIReportStoreError: Error, LocalizedError {
    case invalidReport(String), unsafeLocation, unavailable(Int32), missingReport, conflictingReport, oversizedReport
    public var errorDescription: String? {
        switch self {
        case .invalidReport(let detail): return "AI 报告无效：\(detail)"
        case .unsafeLocation: return "AI 报告位置不安全，请使用本机普通目录；不允许符号链接。"
        case .unavailable(let code): return "无法访问 AI 报告文件（\(code)），已有内容未被覆盖。"
        case .missingReport: return "AI 报告已不存在，请刷新列表。"
        case .conflictingReport: return "同一报告编号已有不同内容，已有报告未被覆盖。"
        case .oversizedReport: return "AI 报告超过 512 KiB，未保存。"
        }
    }
}

/// Each immutable report has its own private file. No configuration or credentials
/// are accepted by this API. Loading an empty library never creates a directory.
public final class AIReportStore: @unchecked Sendable {
    public let directoryURL: URL
    private let safeURL: URL
    private let lock = NSLock()
    private static let maximumFileBytes = 524_288
    private static let maximumCatalogBytes = 33_554_432
    private static let maximumFiles = 1_000
    private static let maximumEntries = 5_000

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
        // Resolve existing parent aliases once (including macOS /var -> /private/var).
        // The storage directory itself and every subsequently opened component still
        // have O_NOFOLLOW protection; later parent-link changes cannot redirect writes.
        self.safeURL = Self.canonicalLocation(directoryURL)
    }

    private static func canonicalLocation(_ url: URL) -> URL {
        var parent = url.deletingLastPathComponent(), missing: [String] = []
        while true {
            if let resolved = parent.path.withCString({ realpath($0, nil) }) {
                var canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                free(resolved)
                for component in missing.reversed() { canonical.appendPathComponent(component, isDirectory: true) }
                return canonical.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            }
            guard parent.path != "/", !parent.lastPathComponent.isEmpty else { return url }
            missing.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
    }

    public func loadCatalog() throws -> AIReportCatalog {
        try Task.checkCancellation()
        try acquireLock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard let directory = try openDirectory(create: false) else { return AIReportCatalog(reports: []) }
        defer { Darwin.close(directory) }
        var warnings: [String] = [], files: [ReportFile] = []
        let iteratorDescriptor = dup(directory)
        guard iteratorDescriptor >= 0, let iterator = fdopendir(iteratorDescriptor) else {
            if iteratorDescriptor >= 0 { Darwin.close(iteratorDescriptor) }
            throw AIReportStoreError.unavailable(errno)
        }
        defer { closedir(iterator) }
        var entries = 0
        while let entry = readdir(iterator) {
            try Task.checkCancellation()
            entries += 1
            guard entries <= Self.maximumEntries else {
                warnings.append("目录项目超过 5,000 条，仅在已扫描文件中优先读取最近修改的报告；这不保证包含全部最新生成的报告，未移除任何文件。")
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(".json") else { continue }
            guard let id = UUID(uuidString: String(name.dropLast(5))), name == fileName(id) else {
                warnings.append("已跳过一个名称不符合规范的报告文件。")
                continue
            }
            var attributes = stat()
            guard fstatat(directory, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0,
                  (attributes.st_mode & S_IFMT) == S_IFREG, attributes.st_nlink == 1 else {
                warnings.append("报告 \(name) 不是可读取的普通文件，已跳过；原文件保留。")
                continue
            }
            files.append(ReportFile(name: name, modifiedSeconds: Int64(attributes.st_mtimespec.tv_sec),
                                    modifiedNanoseconds: Int64(attributes.st_mtimespec.tv_nsec)))
        }
        files.sort {
            if $0.modifiedSeconds != $1.modifiedSeconds { return $0.modifiedSeconds > $1.modifiedSeconds }
            if $0.modifiedNanoseconds != $1.modifiedNanoseconds { return $0.modifiedNanoseconds > $1.modifiedNanoseconds }
            return $0.name < $1.name
        }
        if files.count > Self.maximumFiles {
            warnings.insert("报告超过 1,000 份，优先读取最近修改的文件；这不保证包含全部最新生成的报告，未移除任何文件。", at: 0)
            files = Array(files.prefix(Self.maximumFiles))
        }
        var reports: [AISavedReport] = [], bytes = 0
        for file in files {
            let name = file.name
            try Task.checkCancellation()
            do {
                let data = try read(name, in: directory, remainingBudget: Self.maximumCatalogBytes - bytes)
                bytes += data.count
                let report = try decode(data)
                guard fileName(report.id) == name else { throw AIReportStoreError.invalidReport("文件与报告编号不一致。") }
                reports.append(report)
            } catch BudgetError.exceeded {
                warnings.insert("报告读取达到 32 MiB 上限，优先读取最近修改的文件；这不保证包含全部最新生成的报告，未移除任何文件。", at: 0)
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                warnings.append("报告 \(name) 损坏或无法读取，已跳过；原文件保留。")
            }
        }
        reports.sort {
            if $0.record.generatedAt == $1.record.generatedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.record.generatedAt > $1.record.generatedAt
        }
        return AIReportCatalog(reports: reports, warnings: Array(warnings.prefix(100)))
    }

    /// Tests presence in active storage and recoverable removal independently of
    /// catalog limits. It never creates a directory and does not infer deletion
    /// from a report being absent from a bounded catalog.
    public func location(of id: UUID) throws -> AIReportLocation {
        try Task.checkCancellation()
        try acquireLock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard let directory = try openDirectory(create: false) else { return .missing }
        defer { Darwin.close(directory) }
        let name = fileName(id)
        if try exists(name, in: directory) { return .active }
        if let trash = try openTrash(in: directory, create: false) {
            defer { Darwin.close(trash) }
            if try exists(name, in: trash) { return .removed }
        }
        return .missing
    }

    @discardableResult
    public func save(_ report: AISavedReport) throws -> AISavedReport {
        try Task.checkCancellation()
        try report.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        guard data.count <= Self.maximumFileBytes else { throw AIReportStoreError.oversizedReport }
        try acquireLock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard let directory = try openDirectory(create: true) else { throw AIReportStoreError.unsafeLocation }
        defer { Darwin.close(directory) }
        let name = fileName(report.id)
        if try exists(name, in: directory) {
            let previous = try decode(try read(name, in: directory))
            guard previous.hasSameContent(as: report) else { throw AIReportStoreError.conflictingReport }
            return previous
        }
        // A report removed by the user should not reappear merely because the same
        // successful coordinator response was subsequently obtained from its cache.
        if let trash = try openTrash(in: directory, create: false) {
            defer { Darwin.close(trash) }
            if try exists(name, in: trash) {
                let previous = try decode(try read(name, in: trash))
                guard previous.hasSameContent(as: report) else { throw AIReportStoreError.conflictingReport }
                return previous
            }
        }
        try writeAtomically(data, name: name, directory: directory)
        return report
    }

    /// Removal is recoverable and never permanently destroys the report file.
    public func remove(_ id: UUID) throws {
        try Task.checkCancellation()
        try acquireLock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard let directory = try openDirectory(create: false) else { throw AIReportStoreError.missingReport }
        defer { Darwin.close(directory) }
        let name = fileName(id)
        let report = try decode(try read(name, in: directory))
        guard report.id == id else { throw AIReportStoreError.invalidReport("文件与报告编号不一致。") }
        guard let trash = try openTrash(in: directory, create: true) else { throw AIReportStoreError.unsafeLocation }
        defer { Darwin.close(trash) }
        guard try !exists(name, in: trash) else { throw AIReportStoreError.conflictingReport }
        try move(name, from: directory, to: trash)
    }

    public func restore(_ id: UUID) throws -> AISavedReport {
        try Task.checkCancellation()
        try acquireLock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard let directory = try openDirectory(create: false) else { throw AIReportStoreError.missingReport }
        defer { Darwin.close(directory) }
        guard let trash = try openTrash(in: directory, create: false) else { throw AIReportStoreError.missingReport }
        defer { Darwin.close(trash) }
        let name = fileName(id)
        let report = try decode(try read(name, in: trash))
        guard report.id == id else { throw AIReportStoreError.invalidReport("文件与报告编号不一致。") }
        guard try !exists(name, in: directory) else { throw AIReportStoreError.conflictingReport }
        try move(name, from: trash, to: directory)
        return report
    }

    private func fileName(_ id: UUID) -> String { id.uuidString.lowercased() + ".json" }
    private enum BudgetError: Error { case exceeded }

    private struct ReportFile {
        let name: String
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private func acquireLock() throws {
        while !lock.try() {
            try Task.checkCancellation()
            // The operation is synchronous, but a cancelled background refresh can
            // abandon the queue while another report operation holds the file lock.
            usleep(10_000)
        }
    }

    private func decode(_ data: Data) throws -> AISavedReport {
        try Task.checkCancellation()
        // Bound nested JSON before the recursive Codable decoder sees hostile files.
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 32 else { throw AIReportStoreError.invalidReport("JSON 嵌套过深。") }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
        let report = try JSONDecoder().decode(AISavedReport.self, from: data)
        try report.validate()
        return report
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard directoryURL.isFileURL, safeURL.isFileURL, safeURL.path != "/",
              !safeURL.path.utf8.contains(0) else { throw AIReportStoreError.unsafeLocation }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw AIReportStoreError.unavailable(errno) }
        var transferred = false
        defer { if !transferred { Darwin.close(descriptor) } }
        let components = safeURL.pathComponents.filter { $0 != "/" }
        for (index, component) in components.enumerated() {
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                    throw AIReportStoreError.unavailable(errno)
                }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                if errno == ENOENT, !create { return nil }
                if errno == ELOOP || errno == ENOTDIR { throw AIReportStoreError.unsafeLocation }
                throw AIReportStoreError.unavailable(errno)
            }
            Darwin.close(descriptor); descriptor = next
            if create, index == components.count - 1 {
                guard fchmod(descriptor, 0o700) == 0 else { throw AIReportStoreError.unavailable(errno) }
            }
        }
        transferred = true
        return descriptor
    }

    private func openTrash(in directory: Int32, create: Bool) throws -> Int32? {
        var result = openat(directory, "trash", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if result < 0, errno == ENOENT, create {
            guard mkdirat(directory, "trash", 0o700) == 0 || errno == EEXIST else { throw AIReportStoreError.unavailable(errno) }
            result = openat(directory, "trash", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard result >= 0 else {
            if errno == ENOENT, !create { return nil }
            if errno == ELOOP || errno == ENOTDIR { throw AIReportStoreError.unsafeLocation }
            throw AIReportStoreError.unavailable(errno)
        }
        if create, fchmod(result, 0o700) != 0 {
            let code = errno; Darwin.close(result); throw AIReportStoreError.unavailable(code)
        }
        return result
    }

    private func exists(_ name: String, in directory: Int32) throws -> Bool {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw AIReportStoreError.unsafeLocation }
            return true
        }
        guard errno == ENOENT else { throw AIReportStoreError.unavailable(errno) }
        return false
    }

    private func read(_ name: String, in directory: Int32, remainingBudget: Int = maximumFileBytes) throws -> Data {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw AIReportStoreError.missingReport }
            if errno == ELOOP { throw AIReportStoreError.unsafeLocation }
            throw AIReportStoreError.unavailable(errno)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw AIReportStoreError.unavailable(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw AIReportStoreError.unsafeLocation }
        guard info.st_size >= 0, info.st_size <= Self.maximumFileBytes else { throw AIReportStoreError.oversizedReport }
        guard info.st_size <= remainingBudget else { throw BudgetError.exceeded }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw AIReportStoreError.unavailable(errno) }
            if count == 0 { break }
            guard data.count + count <= Self.maximumFileBytes else { throw AIReportStoreError.oversizedReport }
            guard data.count + count <= remainingBudget else { throw BudgetError.exceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func writeAtomically(_ data: Data, name: String, directory: Int32) throws {
        let staging = ".report-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(directory, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AIReportStoreError.unavailable(errno) }
        defer { Darwin.close(descriptor); unlinkat(directory, staging, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw AIReportStoreError.unavailable(errno) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 { if errno == EINTR { continue }; throw AIReportStoreError.unavailable(errno) }
                guard count > 0 else { throw AIReportStoreError.unavailable(EIO) }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw AIReportStoreError.unavailable(errno) }
        // Exclusive rename installs a complete file without overwriting an existing
        // destination or exposing a transient second hard link after interruption.
        guard renameatx_np(directory, staging, directory, name, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw AIReportStoreError.conflictingReport }
            throw AIReportStoreError.unavailable(errno)
        }
        _ = fsync(directory)
    }

    private func move(_ name: String, from source: Int32, to destination: Int32) throws {
        // Exclusive rename preserves one valid report even when another store instance
        // attempts to remove or restore the same generation concurrently.
        guard renameatx_np(source, name, destination, name, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw AIReportStoreError.conflictingReport }
            throw AIReportStoreError.unavailable(errno)
        }
        _ = fsync(source); _ = fsync(destination)
    }
}
