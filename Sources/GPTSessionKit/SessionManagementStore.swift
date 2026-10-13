import Foundation
import CryptoKit
import Darwin

public enum SessionManagementKind: String, Codable, Sendable {
    case project, session
}

/// Local annotations are independent of rollout paths and token counts. The
/// caller supplies a stable session identity or the project's full grouping key.
public struct SessionManagementEntry: Codable, Equatable, Identifiable, Sendable {
    public let kind: SessionManagementKind
    public let itemID: String
    public let isFavorite: Bool
    public let displayName: String?
    public let note: String?
    public let tags: [String]
    public var id: String { kind.rawValue + ":" + itemID }

    public init(kind: SessionManagementKind, itemID: String, isFavorite: Bool = false,
                displayName: String? = nil, note: String? = nil, tags: [String] = []) {
        self.kind = kind; self.itemID = itemID; self.isFavorite = isFavorite
        self.displayName = displayName; self.note = note; self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case kind, itemID, isFavorite, displayName, note, tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(SessionManagementKind.self, forKey: .kind)
        itemID = try container.decode(String.self, forKey: .itemID)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        // Version 1 metadata has no tags. Explicit null or another type is
        // malformed data rather than an absent legacy field.
        tags = container.contains(.tags) ? try container.decode([String].self, forKey: .tags) : []
    }
}

public struct SessionManagementSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let entries: [SessionManagementEntry]
    public init(revision: UInt64 = 0, entries: [SessionManagementEntry] = []) {
        self.revision = revision; self.entries = entries
    }
    public func entry(kind: SessionManagementKind, itemID: String) -> SessionManagementEntry? {
        entries.first { $0.kind == kind && $0.itemID == itemID }
    }
}

public enum SessionManagementTextChange: Sendable {
    case unchanged
    case set(String?)
}

public enum SessionManagementChange: Sendable {
    case setFavorite(Bool)
    case setDisplayName(String?)
    case setNote(String?)
    case setTags([String])
    case setDetails(displayName: String?, note: String?)
    case update(isFavorite: Bool?, displayName: SessionManagementTextChange = .unchanged,
                note: SessionManagementTextChange = .unchanged, tags: [String]? = nil)
    case clear
}

public struct SessionManagementLimits: Sendable {
    public let maximumBytes: Int
    public let maximumEntries: Int
    public init(maximumBytes: Int = 512 * 1_024, maximumEntries: Int = 2_000) {
        self.maximumBytes = min(512 * 1_024, max(1, maximumBytes))
        self.maximumEntries = min(2_000, max(1, maximumEntries))
    }
}

public enum SessionManagementStoreError: Error, LocalizedError, Equatable {
    case unsafeLocation
    case unavailable(Int32)
    case corruptData
    case unsupportedVersion(Int)
    case invalidInput(String)
    case capacityExceeded
    case conflict(expected: UInt64, actual: UInt64)
    case itemConflict
    case changedOnDisk

    public var errorDescription: String? {
        switch self {
        case .unsafeLocation:
            return "管理数据目录或权限不安全；请使用原会话目录之外的私有普通目录。"
        case .unavailable(let code):
            return "无法访问本地管理数据（\(code)）；已有数据保持不变。"
        case .corruptData:
            return "本地管理数据已损坏或来源不匹配；请保留原文件并恢复备份，已有文件未被覆盖。"
        case .unsupportedVersion:
            return "本地管理数据版本不受支持；已有文件未被覆盖。"
        case .invalidInput(let reason):
            return reason
        case .capacityExceeded:
            return "本地管理数据已达上限（最多 2000 条、512 KiB）；请精简备注或移除部分管理信息后重试。"
        case .conflict:
            return "管理数据已被其他操作更新，请刷新后重新保存。"
        case .itemConflict:
            return "该对象的管理信息已被其他操作更新，请刷新后重新保存。"
        case .changedOnDisk:
            return "管理文件在保存期间发生变化，请刷新后重新保存；已有文件未被覆盖。"
        }
    }
}

/// Durable user metadata, unlike the disposable summary index. A damaged file
/// always fails closed. Each patch locks and reads the latest generation before
/// changing a single item, preserving other instances' changes.
public final class SessionManagementStore: @unchecked Sendable {
    public static let maximumDisplayNameCharacters = 120
    public static let maximumDisplayNameBytes = 1_024
    public static let maximumNoteCharacters = 4_000
    public static let maximumNoteBytes = 16 * 1_024
    public static let maximumTags = 8
    public static let maximumTagCharacters = 20
    public static let maximumTagBytes = 256
    public let directoryURL: URL
    public let fileURL: URL
    private let sourceRootURL: URL
    private let rootPath: String
    private let lockName: String
    private let limits: SessionManagementLimits
    private let lock = NSLock()

    public init(directoryURL: URL, sourceRootURL: URL,
                limits: SessionManagementLimits = .init()) throws {
        guard directoryURL.isFileURL, sourceRootURL.isFileURL,
              !directoryURL.path.utf8.contains(0), !sourceRootURL.path.utf8.contains(0),
              directoryURL.path.utf8.count <= 16_384, sourceRootURL.path.utf8.count <= 16_384 else {
            throw SessionManagementStoreError.unsafeLocation
        }
        self.sourceRootURL = sourceRootURL.standardizedFileURL
        self.rootPath = Self.physicalPath(sourceRootURL)
        self.directoryURL = Self.canonicalLocation(directoryURL)
        self.limits = limits
        guard rootPath != "/", rootPath.utf8.count <= 16_384,
              self.directoryURL.path != rootPath,
              !self.directoryURL.path.hasPrefix(rootPath + "/"),
              self.directoryURL.path != "/" else {
            throw SessionManagementStoreError.unsafeLocation
        }
        let namespace = SHA256.hash(data: Data(rootPath.utf8)).map { String(format: "%02x", $0) }.joined()
        self.fileURL = self.directoryURL.appendingPathComponent(namespace + ".json")
        self.lockName = namespace + ".lock"
    }

    /// Reading an absent store does not create a directory, lock or data file.
    public func load() throws -> SessionManagementSnapshot {
        try acquireLocalLock(); defer { lock.unlock() }
        guard let directory = try openDirectory(create: false) else { return .init() }
        defer { Darwin.close(directory) }
        let loaded = try readLatest(in: directory)
        try Task.checkCancellation()
        return .init(revision: loaded.document.revision, entries: loaded.document.entries)
    }

    @discardableResult
    public func patch(kind: SessionManagementKind, itemID: String, change: SessionManagementChange,
                      expectedRevision: UInt64? = nil,
                      expectedEntry: SessionManagementEntry? = nil) throws -> SessionManagementSnapshot {
        try Self.validateIdentity(itemID)
        // Validate text before any file or directory mutation, including invalid
        // details where one field is valid and the other exceeds its limit.
        let normalized = try Self.normalize(change)
        try acquireLocalLock(); defer { lock.unlock() }
        guard let directory = try openDirectory(create: true) else {
            throw SessionManagementStoreError.unavailable(ENOENT)
        }
        defer { Darwin.close(directory) }
        let fileLock = try acquireFileLock(in: directory)
        defer { _ = flock(fileLock, LOCK_UN); Darwin.close(fileLock) }
        let loaded = try readLatest(in: directory)
        if let expectedRevision, expectedRevision != loaded.document.revision {
            throw SessionManagementStoreError.conflict(expected: expectedRevision, actual: loaded.document.revision)
        }
        var entries = loaded.document.entries
        let index = entries.firstIndex { $0.kind == kind && $0.itemID == itemID }
        let old = index.map { entries[$0] } ?? .init(kind: kind, itemID: itemID)
        let updated = try Self.applying(change: normalized, to: old, expectedEntry: expectedEntry)
        if updated == old { return .init(revision: loaded.document.revision, entries: entries) }
        let empty = !updated.isFavorite && updated.displayName == nil && updated.note == nil && updated.tags.isEmpty
        if let index {
            if empty { entries.remove(at: index) } else { entries[index] = updated }
        } else if !empty { entries.append(updated) }
        guard entries.count <= limits.maximumEntries, loaded.document.revision < UInt64.max else {
            throw SessionManagementStoreError.capacityExceeded
        }
        entries.sort { $0.kind.rawValue == $1.kind.rawValue ? $0.itemID < $1.itemID : $0.kind.rawValue < $1.kind.rawValue }
        let document = Document(version: 2, rootPath: rootPath, revision: loaded.document.revision + 1, entries: entries)
        try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(document)
        guard bytes.count <= limits.maximumBytes else { throw SessionManagementStoreError.capacityExceeded }
        try install(bytes, in: directory, replacing: loaded.identity)
        return .init(revision: document.revision, entries: entries)
    }

    private struct Document: Codable {
        let version: Int
        let rootPath: String
        let revision: UInt64
        let entries: [SessionManagementEntry]
    }
    private struct Loaded {
        let document: Document
        let identity: FileIdentity?
    }
    private struct FileIdentity: Equatable {
        let device: dev_t, inode: ino_t, bytes: off_t
        let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; bytes = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private func readLatest(in directory: Int32) throws -> Loaded {
        try Task.checkCancellation()
        try validateDirectoryLocation(directory)
        let descriptor = openat(directory, fileURL.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return .init(document: .init(version: 2, rootPath: rootPath, revision: 0, entries: []), identity: nil) }
            if errno == ELOOP { throw SessionManagementStoreError.unsafeLocation }
            throw SessionManagementStoreError.unavailable(errno)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw SessionManagementStoreError.unavailable(errno) }
        try validatePrivateFile(before)
        guard before.st_size > 0, before.st_size <= limits.maximumBytes else {
            throw SessionManagementStoreError.corruptData
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw SessionManagementStoreError.unavailable(errno) }
            if count == 0 { break }
            guard count <= limits.maximumBytes - data.count else { throw SessionManagementStoreError.corruptData }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw SessionManagementStoreError.unavailable(errno) }
        guard FileIdentity(before) == FileIdentity(after), data.count == before.st_size else {
            throw SessionManagementStoreError.changedOnDisk
        }
        try Task.checkCancellation()
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw SessionManagementStoreError.corruptData }
        guard document.version == 1 || document.version == 2 else { throw SessionManagementStoreError.unsupportedVersion(document.version) }
        guard document.rootPath == rootPath, document.revision > 0,
              document.entries.count <= limits.maximumEntries else { throw SessionManagementStoreError.corruptData }
        var keys = Set<String>()
        for entry in document.entries {
            try Task.checkCancellation()
            do {
                try Self.validateIdentity(entry.itemID)
                let name = try Self.normalizeName(entry.displayName), note = try Self.normalizeNote(entry.note)
                let tags = try Self.normalizedTags(entry.tags)
                let canonicalTags = tags.count == entry.tags.count && zip(tags, entry.tags).allSatisfy {
                    $0.utf8.elementsEqual($1.utf8)
                }
                guard name == entry.displayName, note == entry.note, canonicalTags,
                      entry.isFavorite || name != nil || note != nil || !tags.isEmpty,
                      keys.insert(entry.id).inserted else { throw SessionManagementStoreError.corruptData }
            } catch is CancellationError { throw CancellationError() }
            catch { throw SessionManagementStoreError.corruptData }
        }
        return .init(document: document, identity: FileIdentity(before))
    }

    private func install(_ data: Data, in directory: Int32, replacing expected: FileIdentity?) throws {
        let temporary = ".session-management-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SessionManagementStoreError.unavailable(errno) }
        defer { Darwin.close(descriptor); unlinkat(directory, temporary, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw SessionManagementStoreError.unavailable(errno) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), min(16_384, bytes.count - offset))
                if count < 0 { if errno == EINTR { continue }; throw SessionManagementStoreError.unavailable(errno) }
                guard count > 0 else { throw SessionManagementStoreError.unavailable(EIO) }
                offset += count
            }
        }
        try Task.checkCancellation()
        guard fsync(descriptor) == 0 else { throw SessionManagementStoreError.unavailable(errno) }
        try validateDirectoryLocation(directory)
        var current = stat()
        if fstatat(directory, fileURL.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0 {
            try validatePrivateFile(current)
            guard expected == FileIdentity(current) else { throw SessionManagementStoreError.changedOnDisk }
        } else {
            guard errno == ENOENT else { throw SessionManagementStoreError.unavailable(errno) }
            guard expected == nil else { throw SessionManagementStoreError.changedOnDisk }
        }
        try Task.checkCancellation()
        guard renameat(directory, temporary, directory, fileURL.lastPathComponent) == 0 else {
            throw SessionManagementStoreError.unavailable(errno)
        }
        // The successful atomic rename is the commit point; cancellation after
        // it must not report a failed save that actually changed user metadata.
        _ = fsync(directory)
    }

    /// Shared with in-memory desktop fixtures so drafts have the same validation
    /// and normalization as the durable store, without touching the filesystem.
    public static func applying(change: SessionManagementChange, to entry: SessionManagementEntry,
                                expectedEntry: SessionManagementEntry? = nil) throws -> SessionManagementEntry {
        try validateIdentity(entry.itemID)
        let change = try normalize(change), updated = apply(change, to: entry)
        if let baseline = expectedEntry {
            guard baseline.kind == entry.kind, baseline.itemID == entry.itemID else {
                throw SessionManagementStoreError.invalidInput("管理对象已变化，请重新打开编辑窗口。")
            }
            let fields: (favorite: Bool, name: Bool, note: Bool, tags: Bool)
            switch change {
            case .setFavorite: fields = (true, false, false, false)
            case .setDisplayName: fields = (false, true, false, false)
            case .setNote: fields = (false, false, true, false)
            case .setTags: fields = (false, false, false, true)
            case .setDetails: fields = (false, true, true, false)
            case .clear: fields = (true, true, true, true)
            case .update(let favorite, let name, let note, let tags):
                let changesName: Bool, changesNote: Bool
                switch name { case .unchanged: changesName = false; case .set: changesName = true }
                switch note { case .unchanged: changesNote = false; case .set: changesNote = true }
                fields = (favorite != nil, changesName, changesNote, tags != nil)
            }
            if (fields.favorite && entry.isFavorite != baseline.isFavorite && entry.isFavorite != updated.isFavorite)
                || (fields.name && entry.displayName != baseline.displayName && entry.displayName != updated.displayName)
                || (fields.note && entry.note != baseline.note && entry.note != updated.note)
                || (fields.tags && entry.tags != baseline.tags && entry.tags != updated.tags) {
                throw SessionManagementStoreError.itemConflict
            }
        }
        return updated
    }

    private static func normalize(_ change: SessionManagementChange) throws -> SessionManagementChange {
        switch change {
        case .setDisplayName(let name): return .setDisplayName(try normalizeName(name))
        case .setNote(let note): return .setNote(try normalizeNote(note))
        case .setTags(let tags): return .setTags(try normalizedTags(tags))
        case .setDetails(let name, let note): return .setDetails(displayName: try normalizeName(name), note: try normalizeNote(note))
        case .update(let favorite, let name, let note, let tags):
            let cleanName: SessionManagementTextChange, cleanNote: SessionManagementTextChange
            switch name { case .unchanged: cleanName = .unchanged; case .set(let value): cleanName = .set(try normalizeName(value)) }
            switch note { case .unchanged: cleanNote = .unchanged; case .set(let value): cleanNote = .set(try normalizeNote(value)) }
            return .update(isFavorite: favorite, displayName: cleanName, note: cleanNote,
                           tags: try tags.map(normalizedTags))
        default: return change
        }
    }

    private static func apply(_ change: SessionManagementChange, to entry: SessionManagementEntry) -> SessionManagementEntry {
        var favorite = entry.isFavorite, name = entry.displayName, note = entry.note, tags = entry.tags
        switch change {
        case .setFavorite(let value): favorite = value
        case .setDisplayName(let value): name = value
        case .setNote(let value): note = value
        case .setTags(let value): tags = value
        case .setDetails(let newName, let newNote): name = newName; note = newNote
        case .update(let value, let newName, let newNote, let newTags):
            if let value { favorite = value }
            if case .set(let value) = newName { name = value }
            if case .set(let value) = newNote { note = value }
            if let newTags { tags = newTags }
        case .clear: favorite = false; name = nil; note = nil; tags = []
        }
        return .init(kind: entry.kind, itemID: entry.itemID, isFavorite: favorite, displayName: name, note: note, tags: tags)
    }

    /// Tags use canonical Unicode and a fixed locale so case matching and
    /// sorting do not change with the user's system language.
    public static func tagKey(_ tag: String) -> String {
        tag.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    /// Retain the first spelling of each case-insensitive label, then sort by
    /// its key. Bound raw input as well as stored output before any disk write.
    public static func normalizedTags(_ values: [String]) throws -> [String] {
        guard values.count <= maximumTags * 16 else {
            throw SessionManagementStoreError.invalidInput("一次最多输入 128 个标签，去重后最多保留 8 个。")
        }
        var labels: [String: String] = [:]
        for value in values {
            guard value.utf8.count <= maximumTagBytes * 16,
                  !value.unicodeScalars.contains(where: { invalidSingleLineScalar($0) || $0 == "," || $0 == "，" }) else {
                throw SessionManagementStoreError.invalidInput("标签请使用单行文本，不允许控制字符或逗号。")
            }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            guard cleaned.utf8.count <= maximumTagBytes, cleaned.count <= maximumTagCharacters else {
                throw SessionManagementStoreError.invalidInput("每个标签最多 20 个字符、256 字节。")
            }
            if cleaned.isEmpty { continue }
            let key = tagKey(cleaned)
            if labels[key] == nil { labels[key] = cleaned }
            guard labels.count <= maximumTags else {
                throw SessionManagementStoreError.invalidInput("每个项目最多保存 8 个不同标签。")
            }
        }
        return labels.keys.sorted().compactMap { labels[$0] }
    }

    private static func validateIdentity(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 8_192,
              !value.unicodeScalars.contains(where: { invalidSingleLineScalar($0) }) else {
            throw SessionManagementStoreError.invalidInput("管理对象标识无效或过长；请刷新会话后重试。")
        }
    }
    private static func normalizeName(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.utf8.count <= maximumDisplayNameBytes, cleaned.count <= maximumDisplayNameCharacters,
              !cleaned.unicodeScalars.contains(where: { invalidSingleLineScalar($0) }) else {
            throw SessionManagementStoreError.invalidInput("本地名称最多 120 个字符、1024 字节，请使用单行文本。")
        }
        return cleaned.isEmpty ? nil : cleaned
    }
    private static func normalizeNote(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard value.utf8.count <= maximumNoteBytes, value.count <= maximumNoteCharacters, !value.utf8.contains(0) else {
            throw SessionManagementStoreError.invalidInput("本地备注最多 4000 个字符、16 KiB，不允许空字符。")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
    private static func invalidSingleLineScalar(_ scalar: Unicode.Scalar) -> Bool {
        // Unicode format characters include emoji joiners and should remain
        // usable in plain text names; reject actual controls and line breaks.
        scalar.value < 32 || (127...159).contains(scalar.value) || CharacterSet.newlines.contains(scalar)
    }

    private func acquireLocalLock() throws {
        try Task.checkCancellation()
        while !lock.try() { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.005) }
        do { try Task.checkCancellation() } catch { lock.unlock(); throw error }
    }
    private func acquireFileLock(in directory: Int32) throws -> Int32 {
        try Task.checkCancellation()
        let descriptor = try openLockFile(in: directory)
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw SessionManagementStoreError.unavailable(errno) }
            try validatePrivateFile(info)
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                try Task.checkCancellation()
                if code == EINTR { continue }
                guard code == EWOULDBLOCK || code == EAGAIN else { throw SessionManagementStoreError.unavailable(code) }
                Thread.sleep(forTimeInterval: 0.005)
            }
            try Task.checkCancellation()
            var pathInfo = stat()
            guard fstatat(directory, lockName, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SessionManagementStoreError.unavailable(errno)
            }
            try validatePrivateFile(pathInfo)
            guard info.st_dev == pathInfo.st_dev, info.st_ino == pathInfo.st_ino else {
                throw SessionManagementStoreError.changedOnDisk
            }
            return descriptor
        } catch { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor); throw error }
    }

    private func openLockFile(in directory: Int32) throws -> Int32 {
        let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        // Multiple first writers must not perform non-exclusive creation on
        // this shared path. Open an installed lock or elect a single creator;
        // another creator's EEXIST means the following safe open can reuse it.
        for _ in 0..<32 {
            try Task.checkCancellation()
            try validateDirectoryLocation(directory)
            let existing = openat(directory, lockName, flags)
            if existing >= 0 { return existing }
            let code = errno
            if code == ELOOP { throw SessionManagementStoreError.unsafeLocation }
            guard code == ENOENT else { throw SessionManagementStoreError.unavailable(code) }
            let created = openat(directory, lockName, flags | O_CREAT | O_EXCL, 0o600)
            if created >= 0 { return created }
            let creationCode = errno
            if creationCode == EEXIST { continue }
            if creationCode == ELOOP { throw SessionManagementStoreError.unsafeLocation }
            throw SessionManagementStoreError.unavailable(creationCode)
        }
        throw SessionManagementStoreError.changedOnDisk
    }

    private func validatePrivateFile(_ info: stat) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw SessionManagementStoreError.unsafeLocation
        }
    }
    private func validateDirectoryLocation(_ descriptor: Int32) throws {
        guard Self.physicalPath(sourceRootURL) == rootPath else { throw SessionManagementStoreError.unsafeLocation }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw SessionManagementStoreError.unavailable(errno) }
        let openedPath = Self.physicalPath(URL(fileURLWithPath: String(cString: path), isDirectory: true))
        guard openedPath == directoryURL.path, openedPath != rootPath,
              !openedPath.hasPrefix(rootPath + "/") else { throw SessionManagementStoreError.unsafeLocation }
    }
    private func openDirectory(create: Bool) throws -> Int32? {
        try Task.checkCancellation()
        guard Self.physicalPath(sourceRootURL) == rootPath else { throw SessionManagementStoreError.unsafeLocation }
        let components = directoryURL.path.split(separator: "/").map(String.init)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SessionManagementStoreError.unavailable(errno) }
        var transferred = false
        defer { if !transferred { Darwin.close(descriptor) } }
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else {
                    throw SessionManagementStoreError.unavailable(errno)
                }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                if errno == ENOENT, !create { return nil }
                if errno == ELOOP || errno == ENOTDIR { throw SessionManagementStoreError.unsafeLocation }
                throw SessionManagementStoreError.unavailable(errno)
            }
            Darwin.close(descriptor); descriptor = next
            if index == components.count - 1 {
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { throw SessionManagementStoreError.unavailable(errno) }
                guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                    throw SessionManagementStoreError.unsafeLocation
                }
            }
        }
        try validateDirectoryLocation(descriptor)
        transferred = true
        return descriptor
    }

    // Resolve existing ancestors, retaining a nonexistent leaf. In particular,
    // /var and /private/var aliases produce the same source namespace on macOS.
    private static func canonicalLocation(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL.deletingLastPathComponent(), missing: [String] = []
        while true {
            if let resolved = ancestor.path.withCString({ realpath($0, nil) }) {
                defer { free(resolved) }
                var result = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                for component in missing.reversed() { result.appendPathComponent(component, isDirectory: true) }
                return result.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            }
            guard ancestor.path != "/", !ancestor.lastPathComponent.isEmpty else { return url.standardizedFileURL }
            missing.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
        }
    }
    private static func physicalPath(_ url: URL) -> String {
        if let resolved = url.standardizedFileURL.path.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return canonicalLocation(url).path
    }
}
