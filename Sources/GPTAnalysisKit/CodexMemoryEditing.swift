import Foundation
import Darwin

public struct CodexMemoryItem: Identifiable, Equatable, Sendable {
    public let offset: Int
    public let length: Int
    public let text: String
    public let context: String
    public var id: Int { offset }
    public static func parse(_ text: String) -> [Self] {
        let ns = text as NSString
        var lines: [(String, NSRange)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, range, enclosing, _ in
            lines.append((ns.substring(with: range), enclosing))
        }
        var items: [Self] = [], context = "MEMORY.md", index = 0
        var fence: (Character, Int)?
        while index < lines.count {
            let line = lines[index].0
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if count >= 3 {
                    if let current = fence {
                        if current.0 == marker && count >= current.1 && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    } else { fence = (marker, count) }
                    index += 1; continue
                }
            }
            if fence != nil { index += 1; continue }
            if line.hasPrefix("#") { context = line }
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { index += 1; continue }
            let start = index; index += 1
            while index < lines.count {
                let next = lines[index].0
                if !next.isEmpty && !next.hasPrefix(" ") && !next.hasPrefix("\t") { break }
                index += 1
            }
            let offset = lines[start].1.location
            let end = NSMaxRange(lines[index - 1].1)
            items.append(.init(offset: offset, length: end - offset, text: ns.substring(with: .init(location: offset, length: end - offset)), context: context))
        }
        return items
    }
    public func replacing(in original: String, with replacement: String?) throws -> String {
        guard Self.parse(original).contains(self) else { throw CodexMemoryEditError.conflict }
        if let replacement {
            guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  replacement.utf8.count <= 32_768, Self.parse(replacement).count == 1,
                  Self.parse(replacement).first?.offset == 0,
                  Self.parse(replacement).first?.length == (replacement as NSString).length else { throw CodexMemoryEditError.invalid }
        }
        let ns = original as NSString
        let suffix = ns.substring(from: offset + length)
        var value = replacement ?? ""
        if !value.isEmpty && !suffix.isEmpty && !value.hasSuffix("\n") { value += original.contains("\r\n") ? "\r\n" : "\n" }
        return ns.substring(to: offset) + value + suffix
    }
}
public enum CodexMemoryEditError: Error, LocalizedError {
    case conflict, invalid, unsafe, capacity
    public var errorDescription: String? {
        switch self {
        case .conflict: return "原文件已变化，不能覆盖。请保留草稿，重新读取后核对。"
        case .invalid: return "仅支持 MEMORY.md 中一条顶层列表项；正文以 - 或 * 加空格开头，续行缩进，最多 32 KiB。"
        case .unsafe: return "目录或文件不安全、不存在或无写入权限；拒绝符号链接、硬链接和非普通文件。"
        case .capacity: return "原文件最多 512 KiB，操作备份最多 20 份；请先导出备份，已有文件未修改。"
        }
    }
}
public struct CodexMemoryBackup: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let rootPath: String
    public let createdAt: Date
    public let action: String
    public let before: String
    public let after: String
}
/// Explicit source mutation boundary; callers must display a preview and obtain confirmation.
public final class CodexMemoryEditor: @unchecked Sendable {
    public let backupDirectory: URL
    private let lock = NSLock()
    public init(backupDirectory: URL) { self.backupDirectory = backupDirectory }
    public func backups() throws -> [CodexMemoryBackup] {
        lock.lock(); defer { lock.unlock() }; return try readBackups()
    }
    private func readBackups() throws -> [CodexMemoryBackup] {
        guard FileManager.default.fileExists(atPath: backupDirectory.path) else { return [] }
        try safeDirectory(backupDirectory, privateMode: true)
        let urls = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard urls.count <= 20 else { throw CodexMemoryEditError.capacity }
        return try urls.map { url in
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw CodexMemoryEditError.unsafe }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
            var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size <= 2_200_000 else { throw CodexMemoryEditError.unsafe }
            let backup = try JSONDecoder().decode(CodexMemoryBackup.self, from: handle.read(upToCount: 2_200_001) ?? Data())
            guard UUID(uuidString: backup.id) != nil, backup.id + ".json" == url.lastPathComponent,
                  backup.rootPath.hasPrefix("/"), backup.rootPath.utf8.count <= 4096, backup.action.utf8.count <= 256, backup.createdAt.timeIntervalSince1970.isFinite, backup.before.utf8.count <= 524_288, backup.after.utf8.count <= 524_288 else { throw CodexMemoryEditError.unsafe }
            return backup
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func apply(root: URL, original: String, replacement: String, action: String) throws -> CodexMemoryBackup {
        lock.lock(); defer { lock.unlock() }
        guard original != replacement, original.utf8.count <= 524_288, replacement.utf8.count <= 524_288, action.utf8.count <= 256 else { throw CodexMemoryEditError.invalid }
        try safeDirectory(root, privateMode: false)
        let dir = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw CodexMemoryEditError.unsafe }; defer { close(dir) }
        let fd = openat(dir, "MEMORY.md", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CodexMemoryEditError.unsafe }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1, before.st_size <= 524_288 else { throw CodexMemoryEditError.unsafe }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CodexMemoryEditError.conflict }; defer { _ = flock(fd, LOCK_UN) }
        let current = try handle.read(upToCount: 524_289) ?? Data()
        guard before.st_size == original.utf8.count, current == Data(original.utf8) else { throw CodexMemoryEditError.conflict }
        if !FileManager.default.fileExists(atPath: backupDirectory.path) { try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try safeDirectory(backupDirectory, privateMode: true)
        let coordination = try acquireBackupLock()
        defer { _ = flock(coordination, LOCK_UN); close(coordination) }
        guard try readBackups().count < 20 else { throw CodexMemoryEditError.capacity }
        let backup = CodexMemoryBackup(id: UUID().uuidString, rootPath: root.standardizedFileURL.path, createdAt: Date(), action: action, before: original, after: replacement)
        let encoded = try JSONEncoder().encode(backup)
        guard encoded.count <= 2_200_000 else { throw CodexMemoryEditError.capacity }
        let backupURL = backupDirectory.appendingPathComponent(backup.id + ".json")
        let backupFD = open(backupDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard backupFD >= 0 else { throw CodexMemoryEditError.unsafe }; defer { close(backupFD) }
        var backupInfo = stat()
        guard fstat(backupFD, &backupInfo) == 0, backupInfo.st_uid == getuid(), backupInfo.st_mode & 0o077 == 0 else { throw CodexMemoryEditError.unsafe }
        let stagedBackup = ".pending-" + backup.id
        let bfd = openat(backupFD, stagedBackup, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard bfd >= 0 else { throw CodexMemoryEditError.unsafe }
        let bh = FileHandle(fileDescriptor: bfd, closeOnDealloc: true); defer { try? bh.close(); unlinkat(backupFD, stagedBackup, 0) }
        try bh.write(contentsOf: encoded); try bh.synchronize(); try bh.close()
        let temporary = ".gpt-memory-" + UUID().uuidString
        let output = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, before.st_mode & 0o777)
        guard output >= 0 else { throw CodexMemoryEditError.unsafe }
        let oh = FileHandle(fileDescriptor: output, closeOnDealloc: true); defer { try? oh.close(); unlinkat(dir, temporary, 0) }
        try oh.write(contentsOf: Data(replacement.utf8)); try oh.synchronize(); try oh.close()
        var backupPath = stat(), backupOpened = stat()
        guard lstat(backupDirectory.path, &backupPath) == 0, fstat(backupFD, &backupOpened) == 0,
              backupPath.st_ino == backupOpened.st_ino, backupPath.st_dev == backupOpened.st_dev else { throw CodexMemoryEditError.unsafe }
        guard renameat(backupFD, stagedBackup, backupFD, backupURL.lastPathComponent) == 0 else { throw CodexMemoryEditError.unsafe }
        _ = fsync(backupFD)
        var live = stat(), opened = stat(), path = stat()
        guard fstat(dir, &opened) == 0, lstat(root.path, &path) == 0, opened.st_ino == path.st_ino, opened.st_dev == path.st_dev,
              fstatat(dir, "MEMORY.md", &live, AT_SYMLINK_NOFOLLOW) == 0, live.st_ino == before.st_ino, live.st_dev == before.st_dev,
              live.st_size == before.st_size, live.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, live.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              live.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, live.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw CodexMemoryEditError.conflict }
        guard renameat(dir, temporary, dir, "MEMORY.md") == 0 else { throw CodexMemoryEditError.unsafe }
        _ = fsync(dir)
        return backup
    }
    public func restore(_ backup: CodexMemoryBackup, root: URL) throws -> CodexMemoryBackup {
        guard root.standardizedFileURL.path == backup.rootPath,
              try backups().contains(backup) else { throw CodexMemoryEditError.invalid }
        return try apply(root: root, original: backup.after, replacement: backup.before, action: "恢复备份 " + backup.id)
    }
    public func removeBackup(_ backup: CodexMemoryBackup) throws {
        lock.lock(); defer { lock.unlock() }
        try safeDirectory(backupDirectory, privateMode: true)
        let coordination = try acquireBackupLock()
        defer { _ = flock(coordination, LOCK_UN); close(coordination) }
        guard try readBackups().contains(backup) else { throw CodexMemoryEditError.conflict }
        let fd = open(backupDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodexMemoryEditError.unsafe }; defer { close(fd) }
        guard unlinkat(fd, backup.id + ".json", 0) == 0 else { throw CodexMemoryEditError.unsafe }
        _ = fsync(fd)
    }
    private func acquireBackupLock() throws -> Int32 {
        let fd = open(backupDirectory.appendingPathComponent("operations.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CodexMemoryEditError.unsafe }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw CodexMemoryEditError.conflict }
        return fd
    }
    private func safeDirectory(_ url: URL, privateMode: Bool) throws {
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), !privateMode || info.st_mode & 0o077 == 0 else { throw CodexMemoryEditError.unsafe }
    }
}
