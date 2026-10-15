import Foundation
import Darwin

public struct KnowledgeSourceDocument: Identifiable, Equatable, Sendable {
    public let id: String
    public let relativePath: String
    public let fileURL: URL
    public let text: String
    public let modifiedAt: Date
    public let title: String
    public let category: String
    public let items: [CodexMemoryItem]
    public init(id: String, relativePath: String, fileURL: URL, text: String, modifiedAt: Date) {
        self.id = id; self.relativePath = relativePath; self.fileURL = fileURL; self.text = text; self.modifiedAt = modifiedAt
        var heading: String?
        text.enumerateLines { line, stop in
            if line.hasPrefix("# ") { heading = String(line.dropFirst(2)); stop = true }
        }
        title = heading ?? fileURL.lastPathComponent
        category = relativePath.contains("/") ? String(relativePath.prefix { $0 != "/" }) : "主记忆文件"
        // Parsing happens on the reader's IO actor once per snapshot, never in a SwiftUI body.
        items = relativePath == "MEMORY.md" ? CodexMemoryItem.parse(text) : []
    }
    public func importedDraft() -> KnowledgeDraft {
        .init(title: String(title.prefix(120)), body: text, state: .draft,
              sources: [.init(origin: .codex, label: relativePath, locator: fileURL.path)])
    }
}
public struct KnowledgeSourceCatalog: Sendable {
    public let documents: [KnowledgeSourceDocument]
    public let warnings: [String]
    public init(documents: [KnowledgeSourceDocument] = [], warnings: [String] = []) { self.documents = documents; self.warnings = warnings }
}
public protocol KnowledgeSourceProvider: Sendable { func read() throws -> KnowledgeSourceCatalog }

/// Inspect generated Markdown only; never writes, executes embedded instructions or reads rollouts outside this root.
public struct CodexMemoryReader: KnowledgeSourceProvider {
    public let rootURL: URL
    public init(rootURL: URL) { self.rootURL = rootURL.standardizedFileURL }
    public func read() throws -> KnowledgeSourceCatalog {
        var rootInfo = stat()
        if lstat(rootURL.path, &rootInfo) != 0 {
            if errno == ENOENT { return .init(warnings: ["尚未找到本地记忆目录；可以选择已有的 Codex memories 目录。不会自动启用 Codex 记忆或生成文件。"] ) }
            throw KnowledgeError.io(errno)
        }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR, rootInfo.st_uid == getuid() else { throw KnowledgeError.unsafe }
        let root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw KnowledgeError.unsafe }; defer { close(root) }
        // Foundation may canonicalize ancestor links (e.g. /var -> /private/var).
        // Use the same canonical prefix for enumeration, after rejecting a linked root itself.
        guard let canonical = realpath(rootURL.path, nil) else { throw KnowledgeError.io(errno) }
        let enumerationRoot = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        guard let enumeration = FileManager.default.enumerator(at: enumerationRoot, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw KnowledgeError.unsafe }
        var paths: [(String, Date)] = [], warnings: [String] = [], visited = 0
        for case let url as URL in enumeration {
            visited += 1
            if visited > 2000 { warnings.append("目录扫描到达 2000 个项目上限，结果可能不完整。"); break }
            guard url.path.hasPrefix(enumerationRoot.path + "/") else { throw KnowledgeError.unsafe }
            let relative = String(url.path.dropFirst(enumerationRoot.path.count + 1))
            if relative.split(separator: "/").count > 6 { enumeration.skipDescendants(); continue }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFLNK { enumeration.skipDescendants(); warnings.append("跳过符号链接：" + relative); continue }
            guard url.pathExtension.lowercased() == "md", info.st_mode & S_IFMT == S_IFREG else { continue }
            paths.append((relative, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))))
        }
        paths.sort { a, b in
            let priority: (String) -> Int = { $0 == "MEMORY.md" ? 0 : $0 == "memory_summary.md" ? 1 : 2 }
            let pa = priority(a.0), pb = priority(b.0)
            return pa == pb ? (a.1 == b.1 ? a.0 < b.0 : a.1 > b.1) : pa < pb
        }
        if paths.count > 256 { warnings.append("只读取最近及主要的 256 个 Markdown 文件；搜索结果不覆盖其余文件。") }
        var documents: [KnowledgeSourceDocument] = [], total = 0
        for (path, date) in paths.prefix(256) {
            if total >= 8 * 1024 * 1024 { warnings.append("达到 8 MiB 总读取预算；搜索结果可能不完整。"); break }
            do {
                var live = stat(), opened = stat()
                guard lstat(rootURL.path, &live) == 0, fstat(root, &opened) == 0,
                      live.st_ino == opened.st_ino, live.st_dev == opened.st_dev, live.st_mode & S_IFMT == S_IFDIR else { throw KnowledgeError.unsafe }
                let data = try load(path, root: root)
                if total + data.count > 8 * 1024 * 1024 { warnings.append("达到 8 MiB 总读取预算；搜索结果可能不完整。"); break }
                guard let text = String(data: data, encoding: .utf8) else { throw KnowledgeError.corrupt }
                total += data.count
                documents.append(.init(id: path, relativePath: path, fileURL: rootURL.appendingPathComponent(path), text: text, modifiedAt: date))
            } catch { warnings.append("未读取 \(path)：\(error.localizedDescription)") }
        }
        return .init(documents: documents, warnings: Array(warnings.prefix(100)))
    }
    private func load(_ relative: String, root: Int32) throws -> Data {
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw KnowledgeError.unsafe }
        var directory = dup(root)
        guard directory >= 0 else { throw KnowledgeError.io(errno) }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw KnowledgeError.unsafe }
            close(directory); directory = next
        }
        let fd = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw KnowledgeError.unsafe }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_size <= 524_288 else { throw KnowledgeError.unsafe }
        let data = try handle.read(upToCount: 524_289) ?? Data()
        var after = stat()
        guard data.count <= 524_288, data.count == before.st_size, fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw KnowledgeError.conflict }
        return data
    }
}
