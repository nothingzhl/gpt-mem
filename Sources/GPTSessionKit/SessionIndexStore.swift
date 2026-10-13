import Foundation
import CryptoKit
import Darwin

/// A cache identity includes nanosecond timestamps because in-place edits may
/// retain the byte count and an explicitly restored modification time.
public struct SessionIndexRevision: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let bytes: Int
    public let archived: Bool

    public init(device: UInt64, inode: UInt64, changedSeconds: Int64, changedNanoseconds: Int64,
                modifiedSeconds: Int64, modifiedNanoseconds: Int64, bytes: Int, archived: Bool) {
        self.device = device; self.inode = inode
        self.changedSeconds = changedSeconds; self.changedNanoseconds = changedNanoseconds
        self.modifiedSeconds = modifiedSeconds; self.modifiedNanoseconds = modifiedNanoseconds
        self.bytes = bytes; self.archived = archived
    }
}

/// Only parser summaries and their original warnings are retained. Transcript
/// bodies, external service settings and credentials are not accepted here.
public struct SessionIndexEntry: Codable, Equatable, Sendable {
    public let relativePath: String
    public let summary: CodexSessionSummary
    public let revision: SessionIndexRevision
    public let warnings: [String]

    public init(relativePath: String, summary: CodexSessionSummary, revision: SessionIndexRevision,
                warnings: [String] = []) {
        self.relativePath = relativePath; self.summary = summary; self.revision = revision
        self.warnings = warnings
    }
}

public struct SessionIndexSnapshot: Sendable {
    public let entries: [SessionIndexEntry]
    public let warnings: [String]
    public init(entries: [SessionIndexEntry] = [], warnings: [String] = []) {
        self.entries = entries; self.warnings = warnings
    }
}

public struct SessionIndexLimits: Sendable {
    public let maximumBytes: Int
    public let maximumEntries: Int
    public let maximumRecordBytes: Int
    public init(maximumBytes: Int = 16 * 1_024 * 1_024, maximumEntries: Int = 2_000,
                maximumRecordBytes: Int = 256 * 1_024) {
        self.maximumBytes = min(16 * 1_024 * 1_024, max(1, maximumBytes))
        self.maximumEntries = min(2_000, max(1, maximumEntries))
        self.maximumRecordBytes = min(256 * 1_024, max(1, maximumRecordBytes))
    }
}

public enum SessionIndexStoreError: Error, LocalizedError {
    case unsafeLocation, unavailable(Int32), invalidEntry
    public var errorDescription: String? {
        switch self {
        case .unsafeLocation: return "会话索引目录不安全；请使用本机普通目录，不允许符号链接或硬链接。"
        case .unavailable(let code): return "无法访问会话索引（\(code)）；原会话日志保持不变。"
        case .invalidEntry: return "会话索引条目无效；已有索引保持不变。"
        }
    }
}

/// Optional, bounded disk cache. Constructing or loading an absent cache never
/// creates files. Each root and read-limit combination has an isolated file.
/// JSONL is encoded and decoded one entry at a time to bound temporary memory.
public final class SessionIndexStore: @unchecked Sendable {
    // Bump whenever rollout parsing/token/search semantics change, even when
    // the JSON cache schema remains compatible. Old summaries must be rescanned.
    private static let parserVersion = 2
    public let directoryURL: URL
    public let fileURL: URL
    private let safeURL: URL
    private let rootURL: URL
    private let physicalRootPath: String
    private let header: Header
    private let readLimits: SessionReadLimits
    private let cacheLimits: SessionIndexLimits
    private let lock = NSLock()

    public init(directoryURL: URL, rootURL: URL, limits: SessionReadLimits = .init(),
                cacheLimits: SessionIndexLimits = .init()) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.safeURL = Self.canonicalLocation(directoryURL)
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.physicalRootPath = Self.physicalRootPath(rootURL)
        self.readLimits = limits; self.cacheLimits = cacheLimits
        self.header = Header(version: 1, parserVersion: Self.parserVersion,
                             rootPath: self.physicalRootPath, limits: LimitSignature(limits))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(self.header)) ?? Data()
        let name = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ".jsonl"
        self.fileURL = self.directoryURL.appendingPathComponent(name)
    }

    public func load() throws -> SessionIndexSnapshot {
        try acquireLock(); defer { lock.unlock() }
        guard let directory = try openDirectory(create: false) else { return .init() }
        defer { Darwin.close(directory) }
        let descriptor = openat(directory, fileURL.lastPathComponent,
                                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return .init() }
            if errno == ELOOP { throw SessionIndexStoreError.unsafeLocation }
            throw SessionIndexStoreError.unavailable(errno)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw SessionIndexStoreError.unavailable(errno) }
        try validateFile(before)
        guard before.st_mode & 0o077 == 0 else {
            return rejected("会话索引权限过宽，已改为重新扫描原日志；重新保存会恢复私有权限。")
        }
        guard before.st_size >= 0, before.st_size <= cacheLimits.maximumBytes else {
            return rejected("会话索引超过读取上限，已改为重新扫描原日志。")
        }
        do {
            var entries: [SessionIndexEntry] = [], paths = Set<String>()
            var pending = Data(), total = 0, line = 0
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SessionIndexStoreError.unavailable(errno)
                }
                if count == 0 { break }
                total += count
                guard total <= cacheLimits.maximumBytes else { throw InvalidCache.exceeded }
                pending.append(contentsOf: buffer.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    try Task.checkCancellation()
                    guard pending.distance(from: pending.startIndex, to: newline) <= cacheLimits.maximumRecordBytes else {
                        throw InvalidCache.exceeded
                    }
                    try autoreleasepool {
                        let bytes = pending.subdata(in: pending.startIndex..<newline)
                        pending.removeSubrange(pending.startIndex...newline)
                        let decoder = JSONDecoder()
                        if line == 0 {
                            guard try decoder.decode(Header.self, from: bytes) == header else {
                                throw InvalidCache.mismatch
                            }
                        } else {
                            guard entries.count < cacheLimits.maximumEntries else { throw InvalidCache.exceeded }
                            let entry = try decoder.decode(SessionIndexEntry.self, from: bytes)
                            try validate(entry)
                            guard paths.insert(entry.relativePath).inserted else { throw InvalidCache.corrupt }
                            entries.append(entry)
                        }
                        line += 1
                    }
                }
                guard pending.count <= cacheLimits.maximumRecordBytes else { throw InvalidCache.exceeded }
            }
            guard line > 0, pending.isEmpty, total == before.st_size else { throw InvalidCache.corrupt }
            var after = stat()
            guard fstat(descriptor, &after) == 0 else { throw SessionIndexStoreError.unavailable(errno) }
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw InvalidCache.corrupt }
            try Task.checkCancellation()
            return .init(entries: entries)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SessionIndexStoreError {
            // Invalid cache contents are disposable; filesystem access failures
            // remain distinct so the repository can explain the actual problem.
            if case .invalidEntry = error { return rejected("会话索引条目已损坏，已改为重新扫描原日志。") }
            throw error
        } catch {
            return rejected("会话索引无效或版本不匹配，已改为重新扫描原日志。")
        }
    }

    /// Replaces the file only after every selected entry is encoded and flushed.
    /// The caller receives a warning if only a bounded subset fits the cache.
    @discardableResult
    public func save(entries: [SessionIndexEntry]) throws -> [String] {
        try acquireLock(); defer { lock.unlock() }
        guard let directory = try openDirectory(create: true) else { throw SessionIndexStoreError.unavailable(ENOENT) }
        defer { Darwin.close(directory) }
        try validateDestination(in: directory)
        let temporary = ".session-index-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SessionIndexStoreError.unavailable(errno) }
        defer { Darwin.close(descriptor); unlinkat(directory, temporary, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw SessionIndexStoreError.unavailable(errno) }
        var written = 0, retained = 0, truncated = false, paths = Set<String>()
        try autoreleasepool {
            let data = try JSONEncoder().encode(header)
            guard data.count <= cacheLimits.maximumRecordBytes, data.count + 1 <= cacheLimits.maximumBytes else {
                throw SessionIndexStoreError.invalidEntry
            }
            try writeLine(data, to: descriptor)
            written = data.count + 1
        }
        let ordered = entries.sorted {
            $0.summary.updatedAt == $1.summary.updatedAt
                ? $0.relativePath < $1.relativePath : $0.summary.updatedAt > $1.summary.updatedAt
        }
        for entry in ordered {
            try Task.checkCancellation()
            try validate(entry)
            guard paths.insert(entry.relativePath).inserted else { throw SessionIndexStoreError.invalidEntry }
            // A bounded character index can still contain many UTF-8 bytes (for
            // example joined emoji). Skip it before encoding rather than failing
            // every other valid entry or allocating an oversized JSON buffer.
            if retained >= cacheLimits.maximumEntries
                || entry.summary.searchText.utf8.count > cacheLimits.maximumRecordBytes {
                truncated = true; continue
            }
            try autoreleasepool {
                let data = try JSONEncoder().encode(entry)
                guard data.count <= cacheLimits.maximumRecordBytes,
                      data.count + 1 <= cacheLimits.maximumBytes - written else {
                    truncated = true; return
                }
                try writeLine(data, to: descriptor)
                written += data.count + 1; retained += 1
            }
        }
        try Task.checkCancellation()
        guard fsync(descriptor) == 0 else { throw SessionIndexStoreError.unavailable(errno) }
        try validateDestination(in: directory)
        try Task.checkCancellation()
        guard renameat(directory, temporary, directory, fileURL.lastPathComponent) == 0 else {
            throw SessionIndexStoreError.unavailable(errno)
        }
        _ = fsync(directory)
        return truncated ? ["会话索引已达缓存上限，仅保存部分摘要；未缓存的会话仍可通过原日志读取。"] : []
    }

    public func clear() throws {
        try acquireLock(); defer { lock.unlock() }
        guard let directory = try openDirectory(create: false) else { return }
        defer { Darwin.close(directory) }
        try validateDestination(in: directory)
        try Task.checkCancellation()
        guard unlinkat(directory, fileURL.lastPathComponent, 0) == 0 || errno == ENOENT else {
            throw SessionIndexStoreError.unavailable(errno)
        }
        _ = fsync(directory)
    }

    private struct Header: Codable, Equatable {
        let version: Int
        let parserVersion: Int
        let rootPath: String
        let limits: LimitSignature
    }
    private struct LimitSignature: Codable, Equatable {
        let maximumFiles: Int, maximumScanEntries: Int, maximumFileBytes: Int, maximumLineBytes: Int
        let maximumMessages: Int, maximumCatalogReadBytes: Int, maximumSearchCharacters: Int
        let maximumCachedTranscripts: Int, maximumCachedTranscriptBytes: Int
        init(_ value: SessionReadLimits) {
            maximumFiles = value.maximumFiles; maximumScanEntries = value.maximumScanEntries
            maximumFileBytes = value.maximumFileBytes; maximumLineBytes = value.maximumLineBytes
            maximumMessages = value.maximumMessages; maximumCatalogReadBytes = value.maximumCatalogReadBytes
            maximumSearchCharacters = value.maximumSearchCharacters
            maximumCachedTranscripts = value.maximumCachedTranscripts
            maximumCachedTranscriptBytes = value.maximumCachedTranscriptBytes
        }
    }
    private enum InvalidCache: Error { case exceeded, mismatch, corrupt }

    private func rejected(_ warning: String) -> SessionIndexSnapshot { .init(warnings: [warning]) }

    private func validate(_ entry: SessionIndexEntry) throws {
        let parts = entry.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let summary = entry.summary, revision = entry.revision
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              (parts.first == "sessions" || parts.first == "archived_sessions"),
              !entry.relativePath.utf8.contains(0), entry.relativePath.utf8.count <= 4_096,
              entry.relativePath.lowercased().hasSuffix(".jsonl"),
              summary.fileURL.isFileURL,
              summary.fileURL.standardizedFileURL == rootURL.appendingPathComponent(entry.relativePath).standardizedFileURL,
              summary.isArchived == (parts.first == "archived_sessions"), summary.isArchived == revision.archived,
              !summary.id.isEmpty, summary.id.utf8.count <= 8_192,
              !summary.sessionID.isEmpty, summary.sessionID.utf8.count <= 4_096,
              summary.metadataSessionID == nil || (summary.metadataSessionID == summary.sessionID
                  && !(summary.metadataSessionID?.isEmpty ?? true)
                  && (summary.metadataSessionID?.count ?? 0) <= 256
                  && (summary.metadataSessionID?.utf8.count ?? 0) <= 4_096),
              summary.title.utf8.count <= 65_536, (summary.projectPath?.utf8.count ?? 0) <= 16_384,
              (summary.model?.utf8.count ?? 0) <= 4_096,
              summary.searchText.count <= readLimits.maximumSearchCharacters,
              summary.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              summary.startedAt?.timeIntervalSinceReferenceDate.isFinite != false,
              summary.messageCount >= 0, summary.toolCallCount >= 0,
              [summary.tokens.input, summary.tokens.cachedInput, summary.tokens.output,
               summary.tokens.reasoningOutput, summary.tokens.total].allSatisfy({ $0 == nil || $0! >= 0 }),
              revision.bytes >= 0, revision.changedNanoseconds >= 0, revision.changedNanoseconds < 1_000_000_000,
              revision.modifiedNanoseconds >= 0, revision.modifiedNanoseconds < 1_000_000_000,
              entry.warnings.count <= 128, entry.warnings.allSatisfy({ $0.utf8.count <= 4_096 }) else {
            throw SessionIndexStoreError.invalidEntry
        }
    }

    private func acquireLock() throws {
        try Task.checkCancellation()
        while !lock.try() { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.005) }
        do { try Task.checkCancellation() } catch { lock.unlock(); throw error }
    }

    private func validateFile(_ info: stat) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid() else {
            throw SessionIndexStoreError.unsafeLocation
        }
    }

    private func validateDestination(in directory: Int32) throws {
        var info = stat()
        if fstatat(directory, fileURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            try validateFile(info)
        } else if errno != ENOENT { throw SessionIndexStoreError.unavailable(errno) }
    }

    private static func canonicalLocation(_ url: URL) -> URL {
        var parent = url.standardizedFileURL.deletingLastPathComponent(), missing: [String] = []
        while true {
            if let resolved = parent.path.withCString({ realpath($0, nil) }) {
                var canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                free(resolved)
                for component in missing.reversed() { canonical.appendPathComponent(component, isDirectory: true) }
                return canonical.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            }
            guard parent.path != "/", !parent.lastPathComponent.isEmpty else { return url.standardizedFileURL }
            missing.append(parent.lastPathComponent); parent.deleteLastPathComponent()
        }
    }

    private static func physicalRootPath(_ url: URL) -> String {
        // Foundation resolvingSymlinksInPath can abbreviate /private/var back
        // to /var on macOS. Directory guards compare realpath strings so aliases
        // of the same source root cannot bypass the source's read-only boundary.
        if let resolved = url.standardizedFileURL.path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return canonicalLocation(url).path
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        try Task.checkCancellation()
        // Source directories are strictly read-only. Otherwise the index's own
        // JSONL could be discovered as a rollout during a subsequent scan.
        guard physicalRootPath != "/", safeURL.path != physicalRootPath,
              !safeURL.path.hasPrefix(physicalRootPath + "/") else {
            throw SessionIndexStoreError.unsafeLocation
        }
        let components = safeURL.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw SessionIndexStoreError.unsafeLocation }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SessionIndexStoreError.unavailable(errno) }
        var transferred = false
        defer { if !transferred { Darwin.close(descriptor) } }
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                    throw SessionIndexStoreError.unavailable(errno)
                }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                if errno == ENOENT, !create { return nil }
                if errno == ELOOP || errno == ENOTDIR { throw SessionIndexStoreError.unsafeLocation }
                throw SessionIndexStoreError.unavailable(errno)
            }
            Darwin.close(descriptor); descriptor = next
            if index == components.count - 1 {
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { throw SessionIndexStoreError.unavailable(errno) }
                guard info.st_uid == getuid() else { throw SessionIndexStoreError.unsafeLocation }
                if create, fchmod(descriptor, 0o700) != 0 { throw SessionIndexStoreError.unavailable(errno) }
            }
        }
        transferred = true
        return descriptor
    }

    private func writeLine(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 { if errno == EINTR { continue }; throw SessionIndexStoreError.unavailable(errno) }
                guard count > 0 else { throw SessionIndexStoreError.unavailable(EIO) }
                written += count
            }
        }
        var newline: UInt8 = 10
        while Darwin.write(descriptor, &newline, 1) != 1 {
            try Task.checkCancellation()
            if errno != EINTR { throw SessionIndexStoreError.unavailable(errno) }
        }
    }
}
