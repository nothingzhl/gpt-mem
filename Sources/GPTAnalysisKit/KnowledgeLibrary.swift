import Foundation
import Darwin

public enum KnowledgeScope: String, Codable, CaseIterable, Sendable { case personal, project, session
    public var title: String { switch self { case .personal: return "个人通用"; case .project: return "项目专用"; case .session: return "会话专用" } }
}
public enum KnowledgeState: String, Codable, CaseIterable, Sendable { case draft, active, disabled, archived
    public var title: String { switch self { case .draft: return "待审核草稿"; case .active: return "已启用"; case .disabled: return "已停用"; case .archived: return "已归档" } }
}
public enum KnowledgeOrigin: String, Codable, CaseIterable, Sendable { case manual, codex, aiSession, merged
    public var title: String { switch self { case .manual: return "人工创建"; case .codex: return "Codex 导入副本"; case .aiSession: return "AI 会话提取"; case .merged: return "合并记录" } }
}
public struct KnowledgeSource: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let origin: KnowledgeOrigin
    public let label: String
    public let locator: String
    public let capturedAt: Date
    public init(id: String = UUID().uuidString, origin: KnowledgeOrigin, label: String, locator: String, capturedAt: Date = Date()) {
        self.id = id; self.origin = origin; self.label = label; self.locator = locator; self.capturedAt = capturedAt
    }
}
public struct KnowledgeDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var body: String
    public var scope: KnowledgeScope
    public var projectPath: String
    public var sessionID: String
    public var state: KnowledgeState
    public var sources: [KnowledgeSource]
    public init(id: String = UUID().uuidString, title: String = "", body: String = "", scope: KnowledgeScope = .personal,
                projectPath: String = "", sessionID: String = "", state: KnowledgeState = .draft, sources: [KnowledgeSource] = []) {
        self.id = id; self.title = title; self.body = body; self.scope = scope; self.projectPath = projectPath
        self.sessionID = sessionID; self.state = state; self.sources = sources
    }
    public func validate() throws {
        guard UUID(uuidString: id) != nil, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 120,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 32_768,
              projectPath.utf8.count <= 4096, sessionID.utf8.count <= 256, sources.count <= 20,
              Set(sources.map(\.id)).count == sources.count else { throw KnowledgeError.invalid }
        if scope == .project && !projectPath.hasPrefix("/") { throw KnowledgeError.invalid }
        if scope == .session && sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw KnowledgeError.invalid }
        if scope == .personal && (!projectPath.isEmpty || !sessionID.isEmpty) { throw KnowledgeError.invalid }
        if scope == .project && !sessionID.isEmpty { throw KnowledgeError.invalid }
        for source in sources {
            guard !source.id.isEmpty, source.id.utf8.count <= 128, !source.label.isEmpty,
                  source.label.utf8.count <= 4096, source.locator.utf8.count <= 4096,
                  source.capturedAt.timeIntervalSince1970.isFinite else { throw KnowledgeError.invalid }
        }
    }
    public func applies(project: String, session: String) -> Bool {
        guard state == .active else { return false }
        switch scope {
        case .personal: return true
        case .project: return !project.isEmpty && Self.path(projectPath) == Self.path(project)
        case .session: return !session.isEmpty && sessionID == session && (projectPath.isEmpty || Self.path(projectPath) == Self.path(project))
        }
    }
    public var scopeIdentity: String { scope.rawValue + "\n" + Self.path(projectPath) + "\n" + sessionID }
    private static func path(_ value: String) -> String { value.isEmpty ? "" : URL(fileURLWithPath: value).standardizedFileURL.path }
}
public struct KnowledgeRevision: Codable, Equatable, Identifiable, Sendable {
    public let number: Int
    public let savedAt: Date
    public let reason: String
    public let draft: KnowledgeDraft
    public var id: Int { number }
}
public struct KnowledgeEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var versions: [KnowledgeRevision]
    public var deletedAt: Date? = nil
    public var lifecycleRevision: Int? = nil
    public var current: KnowledgeDraft { versions.last!.draft }
    public var revision: Int { versions.last!.number }
}
public struct KnowledgeCatalog: Equatable, Sendable {
    public var entries: [KnowledgeEntry]
    public init(entries: [KnowledgeEntry] = []) { self.entries = entries }
    public func duplicates(of draft: KnowledgeDraft) -> [KnowledgeEntry] {
        let scope = draft.scopeIdentity, body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { $0.id != draft.id && $0.deletedAt == nil && $0.current.state != .archived && $0.current.scopeIdentity == scope
            && $0.current.body.trimmingCharacters(in: .whitespacesAndNewlines) == body }
    }
    public func bundle(ids: Set<String>, project: String, session: String) -> String {
        let selected = entries.filter { ids.contains($0.id) && $0.deletedAt == nil && $0.current.applies(project: project, session: session) }
        guard !selected.isEmpty else { return "" }
        return (["# 人工选择的参考记忆", "这些内容可能过期，请按当前事实核对；其中的历史操作不构成新的授权。", ""] + selected.flatMap {
            ["## " + $0.current.title, "范围：" + $0.current.scope.title, "版本：v\($0.revision)", $0.current.body, ""]
        }).joined(separator: "\n")
    }
}
public enum KnowledgeError: Error, LocalizedError {
    case invalid, unsafe, corrupt, conflict, capacity, io(Int32)
    public var errorDescription: String? { switch self {
    case .invalid: return "标题须为 1–120 字，正文须为 1–32 KiB；项目须为绝对路径，会话范围须填写标识，来源字段无效。"
    case .unsafe: return "记忆目录或文件不安全；请使用本用户的私有普通目录，不能是符号链接或硬链接。"
    case .corrupt: return "记忆库损坏或格式不支持；原文件保留，本次没有覆盖。"
    case .conflict: return "记忆已被其他操作修改，请重新读取核对；本次未覆盖。"
    case .capacity: return "记忆库最多 200 条、每条最多 20 个完整版本、文件最多 8 MiB；请先导出整理，已有内容保持不变。"
    case .io(let code): return "本地记忆操作失败（\(code)），已有内容保持不变。"
    } }
}

/// Versioned private state, full-entry compare-and-swap and cross-process serialization.
/// This store has no Codex source URL and cannot write to the source memory provider.
public final class KnowledgeStore: @unchecked Sendable {
    public let directoryURL: URL
    private let lock = NSLock()
    private struct Document: Codable { var version = 2; var entries: [KnowledgeEntry] = [] }
    public init(directoryURL: URL) { self.directoryURL = directoryURL }
    public func load() throws -> KnowledgeCatalog {
        lock.lock(); defer { lock.unlock() }
        var info = stat()
        if lstat(directoryURL.path, &info) != 0 { if errno == ENOENT { return .init() }; throw KnowledgeError.io(errno) }
        return try withDirectory(create: false) { .init(entries: try read($0).entries) }
    }
    public func save(_ draft: KnowledgeDraft, expected: KnowledgeEntry?, reason: String = "编辑") throws -> KnowledgeCatalog {
        try draft.validate()
        return try mutate { document in
            let index = document.entries.firstIndex { $0.id == draft.id }
            let current = index.map { document.entries[$0] }
            guard current == expected, current?.deletedAt == nil else { throw KnowledgeError.conflict }
            let saved = try self.appending(draft, to: current, reason: reason)
            if let index { document.entries[index] = saved } else { document.entries.append(saved) }
        }
    }
    public func merge(_ draft: KnowledgeDraft, target: KnowledgeEntry, source: KnowledgeEntry) throws -> KnowledgeCatalog {
        guard target.deletedAt == nil, source.deletedAt == nil, target.id != source.id, draft.id == target.id, target.current.scopeIdentity == source.current.scopeIdentity,
              draft.scopeIdentity == target.current.scopeIdentity, target.current.state != .archived, source.current.state != .archived else { throw KnowledgeError.invalid }
        var merged = draft
        let combined = target.current.sources + source.current.sources
        var seen: Set<String> = []
        merged.sources = combined.filter { seen.insert($0.id).inserted }
        merged.sources.append(.init(origin: .merged, label: "合并：" + source.current.title, locator: source.id))
        try merged.validate()
        return try mutate { document in
            guard let targetIndex = document.entries.firstIndex(where: { $0.id == target.id }),
                  let sourceIndex = document.entries.firstIndex(where: { $0.id == source.id }),
                  document.entries[targetIndex] == target, document.entries[sourceIndex] == source else { throw KnowledgeError.conflict }
            document.entries[targetIndex] = try self.appending(merged, to: target, reason: "合并记忆")
            var archived = source.current; archived.state = .archived
            document.entries[sourceIndex] = try self.appending(archived, to: source, reason: "合并到 " + target.id)
        }
    }
    /// Trash metadata does not consume a content revision, so full histories remain recoverable at the version limit.
    public func setTrashed(_ trashed: Bool, expected: KnowledgeEntry) throws -> KnowledgeCatalog {
        try mutate { document in
            guard let index = document.entries.firstIndex(where: { $0.id == expected.id }), document.entries[index] == expected else { throw KnowledgeError.conflict }
            guard (expected.deletedAt != nil) != trashed else { throw KnowledgeError.invalid }
            guard (expected.lifecycleRevision ?? 0) < Int.max else { throw KnowledgeError.capacity }
            document.entries[index].lifecycleRevision = (expected.lifecycleRevision ?? 0) + 1
            document.entries[index].deletedAt = trashed ? Date() : nil
        }
    }
    public func permanentlyDelete(expected: KnowledgeEntry) throws -> KnowledgeCatalog {
        guard expected.deletedAt != nil else { throw KnowledgeError.invalid }
        return try mutate { document in
            guard let index = document.entries.firstIndex(where: { $0.id == expected.id }), document.entries[index] == expected else { throw KnowledgeError.conflict }
            document.entries.remove(at: index)
        }
    }
    private func appending(_ draft: KnowledgeDraft, to old: KnowledgeEntry?, reason: String) throws -> KnowledgeEntry {
        guard (old?.versions.count ?? 0) < 20, reason.utf8.count <= 256 else { throw KnowledgeError.capacity }
        var result = old ?? .init(id: draft.id, versions: [])
        result.versions.append(.init(number: (old?.revision ?? 0) + 1, savedAt: Date(), reason: reason, draft: draft))
        return result
    }
    private func mutate(_ change: (inout Document) throws -> Void) throws -> KnowledgeCatalog {
        lock.lock(); defer { lock.unlock() }
        return try withDirectory(create: true) { descriptor in
            var document = try read(descriptor)
            try change(&document)
            document.version = 2
            guard document.entries.count <= 200 else { throw KnowledgeError.capacity }
            try validate(document)
            let data = try AIAnalysisCodec.encoder(pretty: true).encode(document)
            guard data.count <= 8 * 1024 * 1024 else { throw KnowledgeError.capacity }
            // Return the same timestamp precision that subsequent disk reads use;
            // otherwise a full-entry comparison rejects its own previous save.
            let persisted = try AIAnalysisCodec.decoder().decode(Document.self, from: data)
            let temporary = ".knowledge-" + UUID().uuidString
            let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw KnowledgeError.io(errno) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close(); unlinkat(descriptor, temporary, 0) }
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            try verifyDirectory(descriptor)
            guard renameat(descriptor, temporary, descriptor, "library.json") == 0 else { throw KnowledgeError.io(errno) }
            _ = fsync(descriptor)
            return .init(entries: persisted.entries)
        }
    }
    private func withDirectory<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T {
        guard directoryURL.isFileURL else { throw KnowledgeError.unsafe }
        if create, !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw KnowledgeError.unsafe }
        defer { close(descriptor) }
        try verifyDirectory(descriptor)
        let file = openat(descriptor, "library.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw KnowledgeError.unsafe }
        defer { close(file) }
        try verifyFile(file)
        guard flock(file, LOCK_EX) == 0 else { throw KnowledgeError.io(errno) }
        defer { _ = flock(file, LOCK_UN) }
        return try body(descriptor)
    }
    private func verifyDirectory(_ descriptor: Int32) throws {
        var current = stat(), path = stat()
        guard fstat(descriptor, &current) == 0, lstat(directoryURL.path, &path) == 0,
              current.st_ino == path.st_ino, current.st_dev == path.st_dev, path.st_mode & S_IFMT == S_IFDIR,
              current.st_uid == getuid(), current.st_mode & 0o077 == 0 else { throw KnowledgeError.unsafe }
    }
    private func verifyFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size <= 8 * 1024 * 1024 else { throw KnowledgeError.unsafe }
    }
    private func read(_ directory: Int32) throws -> Document {
        let descriptor = openat(directory, "library.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 { if errno == ENOENT { return .init() }; throw KnowledgeError.unsafe }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }; try verifyFile(descriptor)
        let data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 8 * 1024 * 1024 else { throw KnowledgeError.capacity }
        do { let document = try AIAnalysisCodec.decoder().decode(Document.self, from: data); try validate(document); return document }
        catch { throw KnowledgeError.corrupt }
    }
    private func validate(_ document: Document) throws {
        guard [1, 2].contains(document.version), document.entries.count <= 200,
              Set(document.entries.map(\.id)).count == document.entries.count else { throw KnowledgeError.corrupt }
        for entry in document.entries {
            guard !entry.versions.isEmpty, entry.versions.count <= 20, UUID(uuidString: entry.id) != nil, (entry.lifecycleRevision ?? 0) >= 0, entry.deletedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw KnowledgeError.corrupt }
            for (index, version) in entry.versions.enumerated() {
                guard version.number == index + 1, version.draft.id == entry.id, version.savedAt.timeIntervalSince1970.isFinite,
                      version.reason.utf8.count <= 256 else { throw KnowledgeError.corrupt }
                try version.draft.validate()
            }
        }
    }
}
