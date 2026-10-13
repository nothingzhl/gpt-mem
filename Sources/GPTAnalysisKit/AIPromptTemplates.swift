import Foundation
import Darwin

public struct AIPromptTemplate: Codable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var text: String
    public var moduleID: String?
    public var revision: Int
    public var isArchived: Bool
    public var isBuiltIn: Bool { id.hasPrefix("builtin.") }
    public init(id: String = "user." + UUID().uuidString.lowercased(), title: String, text: String,
                moduleID: String? = nil, revision: Int = 1, isArchived: Bool = false) {
        self.id = id; self.title = title; self.text = text; self.moduleID = moduleID
        self.revision = revision; self.isArchived = isArchived
    }
    public func supports(_ module: String) -> Bool { !isArchived && (moduleID == nil || moduleID == module) }
    public static let builtIns: [AIPromptTemplate] = [
        .init(id: "builtin.concise", title: "简洁结论", text: "使用中文，先给结论，再给关键依据和可执行的下一步。减少重复，明确区分已知事实和待验证内容。"),
        .init(id: "builtin.handoff.continue", title: "继续开发", text: "重点提取当前目标、用户最新决定、已完成和未完成的工作、真实验证记录及关键限制。下一步按执行顺序排列，便于另一位开发者直接接手；对助手声称完成但缺少验证的内容标记待核验。", moduleID: "session.handoff"),
        .init(id: "builtin.handoff.review", title: "阶段复盘", text: "重点整理这一阶段的成果、需求变更、已确认的决策与理由、仍存在的问题和验收缺口。下一步优先补齐影响交付的缺口，不要把历史状态当成当前状态。", moduleID: "session.handoff"),
        .init(id: "builtin.handoff.debug", title: "问题排查交接", text: "重点整理问题现象、复现条件、已尝试的方法、已有证据、已排除与尚未确认的原因。下一步给出最少且有区分度的检查，避免重复无效尝试。", moduleID: "session.handoff"),
        .init(id: "builtin.memory.inspect", title: "优先排查大头", text: "优先解释已测内存变化的主要来源、进程身份与生命周期，以及缺测对判断的影响。按收益排序给出少量检查步骤，不把常驻或单次上涨当作泄漏。", moduleID: "memory")
    ]
}

/// The exact user-approved wording, including unsaved edits, belongs to the frozen input.
public struct AIAnalysisPrompt: Codable, Equatable {
    public let templateID: String?
    public let title: String
    public let revision: Int?
    public let text: String
    public let isModified: Bool
    public init(templateID: String? = nil, title: String = "本次自定义提示词", revision: Int? = nil,
                text: String, isModified: Bool = false) {
        self.templateID = templateID; self.title = title; self.revision = revision
        self.text = text; self.isModified = isModified
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 100,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 8_192,
              templateID.map({ !$0.isEmpty && $0.utf8.count <= 100 }) ?? true,
              revision.map({ $0 >= 1 }) ?? true else { throw AIPromptTemplateError.invalidInput }
    }
}

public struct AIPromptCatalog {
    public let revision: UInt64
    public let templates: [AIPromptTemplate]
    public let defaults: [String: String]
    public init(revision: UInt64 = 0, templates: [AIPromptTemplate] = [], defaults: [String: String] = [:]) {
        self.revision = revision; self.templates = templates; self.defaults = defaults
    }
    public var allTemplates: [AIPromptTemplate] { AIPromptTemplate.builtIns + templates }
    public func choices(for moduleID: String) -> [AIPromptTemplate] { allTemplates.filter { $0.supports(moduleID) } }
}

public enum AIPromptTemplateError: Error, LocalizedError {
    case invalidInput, corruptFile, conflict, unsafeLocation, capacity, unavailable(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "模板名称不能为空且最多 80 字；提示词不能为空且最多 8 KiB；模板范围或编号无效。"
        case .corruptFile: return "提示词模板文件损坏或版本不支持，原文件未覆盖。请修复后重新读取。"
        case .conflict: return "这个模板已被其他操作修改，请重新读取并核对；本次未覆盖。"
        case .unsafeLocation: return "提示词目录或文件不是本用户的私有普通文件，未读取或覆盖。"
        case .capacity: return "最多保存 40 个自定义模板，文件最多 512 KiB；已有模板保持不变。"
        case .unavailable(let code): return "提示词存储操作未完成（\(code)），已有内容保持不变。"
        }
    }
}

/// Private, bounded, atomic storage. A lock and per-item baselines prevent two windows overwriting each other.
public final class AIPromptTemplateStore {
    public let directoryURL: URL
    private let lock = NSLock()
    public init(directoryURL: URL) { self.directoryURL = directoryURL }
    private struct Document: Codable {
        var version = 1
        var revision: UInt64 = 0
        var templates: [AIPromptTemplate] = []
        var defaults: [String: String] = [:]
        var catalog: AIPromptCatalog { .init(revision: revision, templates: templates, defaults: defaults) }
    }

    public func load() throws -> AIPromptCatalog {
        lock.lock(); defer { lock.unlock() }
        guard directoryURL.isFileURL else { throw AIPromptTemplateError.unsafeLocation }
        var info = stat()
        if lstat(directoryURL.path, &info) != 0 {
            if errno == ENOENT { return .init() }
            throw AIPromptTemplateError.unavailable(errno)
        }
        return try withDirectory(create: false) { try read($0).catalog }
    }

    public func save(_ draft: AIPromptTemplate, expected: AIPromptTemplate?) throws -> AIPromptCatalog {
        try validate(draft)
        guard !draft.isBuiltIn else { throw AIPromptTemplateError.invalidInput }
        return try mutate { document in
            let old = document.templates.first { $0.id == draft.id }
            guard old == expected else { throw AIPromptTemplateError.conflict }
            guard (old?.revision ?? 0) < Int.max else { throw AIPromptTemplateError.capacity }
            var saved = draft
            saved.revision = (old?.revision ?? 0) + 1
            if let index = document.templates.firstIndex(where: { $0.id == draft.id }) { document.templates[index] = saved }
            else { document.templates.append(saved) }
            // A changed scope or archived template cannot remain an incompatible default.
            document.defaults = document.defaults.filter { $0.value != saved.id || saved.supports($0.key) }
        }
    }

    public func setDefault(_ id: String?, for moduleID: String) throws -> AIPromptCatalog {
        guard validModule(moduleID) else { throw AIPromptTemplateError.invalidInput }
        return try mutate { document in
            if let id {
                guard document.catalog.choices(for: moduleID).contains(where: { $0.id == id }) else { throw AIPromptTemplateError.invalidInput }
                document.defaults[moduleID] = id
            } else { document.defaults.removeValue(forKey: moduleID) }
        }
    }

    private func mutate(_ change: (inout Document) throws -> Void) throws -> AIPromptCatalog {
        lock.lock(); defer { lock.unlock() }
        return try withDirectory(create: true) { descriptor in
            var document = try read(descriptor)
            try change(&document)
            guard document.revision < UInt64.max else { throw AIPromptTemplateError.capacity }
            document.revision += 1
            guard document.templates.count <= 40, document.defaults.count <= 50 else { throw AIPromptTemplateError.capacity }
            try validate(document)
            let data = try AIAnalysisCodec.encoder(pretty: true).encode(document)
            guard data.count <= 524_288 else { throw AIPromptTemplateError.capacity }
            let temporary = ".prompt-\(UUID().uuidString)"
            let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard file >= 0 else { throw AIPromptTemplateError.unavailable(errno) }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            defer { try? handle.close(); unlinkat(descriptor, temporary, 0) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try verifyDirectory(descriptor)
            guard renameat(descriptor, temporary, descriptor, "library.json") == 0 else { throw AIPromptTemplateError.unavailable(errno) }
            _ = fsync(descriptor)
            return document.catalog
        }
    }

    private func withDirectory<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T {
        guard directoryURL.isFileURL else { throw AIPromptTemplateError.unsafeLocation }
        if create, !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        let descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AIPromptTemplateError.unsafeLocation }
        defer { close(descriptor) }
        try verifyDirectory(descriptor)
        let lockFile = openat(descriptor, "library.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFile >= 0 else { throw AIPromptTemplateError.unsafeLocation }
        defer { close(lockFile) }
        try verifyFile(lockFile)
        guard flock(lockFile, LOCK_EX) == 0 else { throw AIPromptTemplateError.unavailable(errno) }
        defer { _ = flock(lockFile, LOCK_UN) }
        return try body(descriptor)
    }

    private func verifyDirectory(_ descriptor: Int32) throws {
        var current = stat(), path = stat()
        guard fstat(descriptor, &current) == 0, lstat(directoryURL.path, &path) == 0,
              current.st_ino == path.st_ino, current.st_dev == path.st_dev,
              (path.st_mode & S_IFMT) == S_IFDIR, current.st_uid == getuid(), current.st_mode & 0o077 == 0 else {
            throw AIPromptTemplateError.unsafeLocation
        }
    }
    private func verifyFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size <= 524_288 else {
            throw AIPromptTemplateError.unsafeLocation
        }
    }
    private func read(_ directory: Int32) throws -> Document {
        let descriptor = openat(directory, "library.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return Document() }
            throw AIPromptTemplateError.unsafeLocation
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try verifyFile(descriptor)
        let bytes = try handle.read(upToCount: 524_289) ?? Data()
        guard bytes.count <= 524_288 else { throw AIPromptTemplateError.capacity }
        do {
            let document = try AIAnalysisCodec.decoder().decode(Document.self, from: bytes)
            try validate(document)
            return document
        } catch { throw AIPromptTemplateError.corruptFile }
    }
    private func validModule(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 100 }
    private func validate(_ template: AIPromptTemplate) throws {
        guard template.id.hasPrefix("user."), UUID(uuidString: String(template.id.dropFirst(5))) != nil,
              !template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, template.title.count <= 80,
              !template.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, template.text.utf8.count <= 8_192,
              template.revision >= 1, template.moduleID.map(validModule) ?? true else { throw AIPromptTemplateError.invalidInput }
    }
    private func validate(_ document: Document) throws {
        guard document.version == 1, document.templates.count <= 40,
              Set(document.templates.map(\.id)).count == document.templates.count, document.defaults.count <= 50 else {
            throw AIPromptTemplateError.corruptFile
        }
        for template in document.templates { try validate(template) }
        for (module, id) in document.defaults {
            guard validModule(module), document.catalog.choices(for: module).contains(where: { $0.id == id }) else { throw AIPromptTemplateError.corruptFile }
        }
    }
}
