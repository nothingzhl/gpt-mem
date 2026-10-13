import Foundation
import Darwin

public enum SessionReadError: Error, LocalizedError {
    case inaccessibleRoot
    case invalidSessionPath
    case inaccessibleSession
    public var errorDescription: String? {
        switch self {
        case .inaccessibleRoot: return "无法读取 Codex 会话目录，请检查目录与权限。"
        case .invalidSessionPath: return "会话文件必须位于所选 Codex 根目录内，且不能经过符号链接。"
        case .inaccessibleSession: return "无法读取该会话；文件可能已移动、删除或没有读取权限。"
        }
    }
}

/// Local, read-only repository. The lock serializes summary/title caches and the bounded transcript LRU; callers
/// should run catalog/transcript reads off the UI actor. No credentials or state DBs are read.
public final class CodexSessionRepository: SessionRepository, @unchecked Sendable {
    public let rootURL: URL
    private let limits: SessionReadLimits
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var transcriptCache: [String: TranscriptCacheEntry] = [:]
    private var transcriptAccessOrder: [String] = []
    private var transcriptCacheBytes = 0
    private var titleIndexCache: TitleIndexCacheEntry?
    // Only one bounded summary parser is retained between refreshes. It allows
    // tight per-refresh budgets to make progress without keeping all log bodies.
    private var catalogContinuation: CatalogContinuation?
    private var readMetrics = SessionReadMetrics()

    public var lastReadMetrics: SessionReadMetrics {
        lock.lock(); defer { lock.unlock() }
        return readMetrics
    }

    public static var defaultRootURL: URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public init(rootURL: URL = CodexSessionRepository.defaultRootURL, limits: SessionReadLimits = .init()) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.limits = limits
    }

    public func loadCatalog() throws -> SessionCatalog {
        // Return owned Swift values while draining filesystem/URL temporaries
        // created during directory enumeration and metadata inspection.
        try autoreleasepool { try readCatalog() }
    }

    private func readCatalog() throws -> SessionCatalog {
        try acquireReadLock(); defer { lock.unlock() }
        readMetrics = .init()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            cache.removeAll()
            transcriptCache.removeAll(); transcriptAccessOrder.removeAll(); transcriptCacheBytes = 0
            titleIndexCache = nil
            catalogContinuation = nil
            return SessionCatalog(warnings: ["尚未找到 Codex 根目录；首次使用 Codex 后刷新，或选择已有目录。"])
        }
        guard isDirectory.boolValue, FileManager.default.isReadableFile(atPath: rootURL.path) else {
            throw SessionReadError.inaccessibleRoot
        }
        var warnings: [String] = []
        var candidates: [Candidate] = []
        var scanned = 0
        for folder in ["sessions", "archived_sessions"] {
            try Task.checkCancellation()
            let directory = rootURL.appendingPathComponent(folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink != true, values?.isDirectory == true else {
                appendWarning("已跳过非普通目录或符号链接：\(folder)。", to: &warnings); continue
            }
            guard let enumeration = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in
                    self.appendWarning("部分会话子目录无法读取。", to: &warnings); return true
                }) else { appendWarning("无法扫描 \(folder) 目录。", to: &warnings); continue }
            for case let file as URL in enumeration {
                try Task.checkCancellation()
                scanned += 1
                if scanned > limits.maximumScanEntries {
                    appendWarning("扫描已达 \(limits.maximumScanEntries) 项上限，目录结果可能不完整。", to: &warnings)
                    break
                }
                guard let metadata = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else {
                    appendWarning("部分会话文件属性无法读取。", to: &warnings); continue
                }
                if metadata.isSymbolicLink == true {
                    enumeration.skipDescendants()
                    appendWarning("已跳过会话目录内的符号链接。", to: &warnings)
                    continue
                }
                guard metadata.isRegularFile == true, file.pathExtension.lowercased() == "jsonl",
                      isInsideRoot(file) else { continue }
                candidates.append(Candidate(url: file.standardizedFileURL, bytes: metadata.fileSize ?? 0,
                                            modified: metadata.contentModificationDate ?? .distantPast,
                                            archived: folder == "archived_sessions"))
            }
            if scanned > limits.maximumScanEntries { break }
        }
        candidates.sort { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified }
        if candidates.count > limits.maximumFiles {
            appendWarning("会话文件超过 \(limits.maximumFiles) 个，本次只加载最近修改的文件。", to: &warnings)
            candidates = Array(candidates.prefix(limits.maximumFiles))
        }
        let candidatePaths = Set(candidates.map { $0.url.path })
        if let continuation = catalogContinuation, !candidatePaths.contains(continuation.candidate.url.path) {
            catalogContinuation = nil
        }
        cache = cache.filter { candidatePaths.contains($0.key) }
        for path in transcriptAccessOrder where !candidatePaths.contains(path) { removeTranscript(at: path) }
        var sessions: [CodexSessionSummary] = []
        var missingMetadataPaths: Set<String> = []
        var readBytes = 0
        for candidate in candidates {
            try Task.checkCancellation()
            if let cached = cache[candidate.url.path], cached.matches(candidate) {
                readMetrics.cachedRolloutFiles += 1
                sessions.append(cached.summary)
                if cached.warnings.contains(where: { $0.contains("缺少有效 session_meta") }) { missingMetadataPaths.insert(candidate.url.path) }
                cached.warnings.forEach { appendWarning("\(candidate.url.lastPathComponent)：\($0)", to: &warnings) }
                continue
            }
            let remaining = limits.maximumCatalogReadBytes - readBytes
            guard remaining > 0 else {
                appendWarning("本次索引读取已达 \(limits.maximumCatalogReadBytes / 1_024 / 1_024) MiB 上限；结果不完整，后续刷新会继续读取。", to: &warnings)
                continue
            }
            do {
                let continuation = catalogContinuation.flatMap { $0.candidate.matches(candidate) && $0.candidate.url == candidate.url ? $0 : nil }
                let fileRemaining = limits.maximumFileBytes - (continuation?.bytesRead ?? 0)
                let parsed = try parse(candidate, byteBudget: min(fileRemaining, remaining), retainsMessages: false,
                                       continuation: continuation)
                readBytes += parsed.bytesRead
                sessions.append(parsed.transcript.summary)
                if parsed.transcript.warnings.contains(where: { $0.contains("缺少有效 session_meta") }) { missingMetadataPaths.insert(candidate.url.path) }
                // A catalog-budget truncation must be retried on the next refresh.
                if !parsed.catalogBudgetTruncated {
                    cache[candidate.url.path] = CacheEntry(candidate: candidate, summary: parsed.transcript.summary,
                                                          warnings: parsed.transcript.warnings)
                    if catalogContinuation?.candidate.url == candidate.url { catalogContinuation = nil }
                } else {
                    catalogContinuation = parsed.continuation
                }
                parsed.transcript.warnings.forEach { appendWarning("\(candidate.url.lastPathComponent)：\($0)", to: &warnings) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                appendWarning("\(candidate.url.lastPathComponent)：无法读取，会话可能已移动或权限不足。", to: &warnings)
            }
        }
        var seenSessionIDs: Set<String> = []
        let unique = sessions.filter { summary in
            let identity = missingMetadataPaths.contains(summary.fileURL.path) ? summary.id : summary.sessionID
            return seenSessionIDs.insert(identity).inserted
        }
        if unique.count < sessions.count {
            appendWarning("已合并 \(sessions.count - unique.count) 个相同会话 ID 的副本，只统计最近修改的文件。", to: &warnings)
        }
        let titles = try loadTitleIndex(for: Set(unique.map(\.sessionID)), warnings: &warnings)
        try Task.checkCancellation()
        return SessionCatalog(sessions: unique.map { applyingTitle(titles[$0.sessionID], to: $0) }, warnings: warnings)
    }

    public func loadTranscript(for summary: CodexSessionSummary) throws -> SessionTranscript {
        try autoreleasepool { try readTranscript(for: summary) }
    }

    private func readTranscript(for summary: CodexSessionSummary) throws -> SessionTranscript {
        try acquireReadLock(); defer { lock.unlock() }
        readMetrics = .init()
        var fileURL = summary.fileURL
        // URL resource values are cached on the URL value. A summary can live
        // through several appends, so explicitly invalidate those values before
        // deciding whether a transcript cache entry is still current.
        fileURL.removeAllCachedResourceValues()
        guard isInsideRoot(fileURL) else { throw SessionReadError.invalidSessionPath }
        let metadata = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard metadata?.isSymbolicLink != true, metadata?.isRegularFile == true else { throw SessionReadError.inaccessibleSession }
        let candidate = Candidate(url: fileURL, bytes: metadata?.fileSize ?? 0,
                                  modified: metadata?.contentModificationDate ?? summary.updatedAt,
                                  archived: relativePath(summary.fileURL)?.hasPrefix("archived_sessions/") == true)
        // Cached text must still pass the component-by-component no-symlink open
        // on each access; metadata alone would accept a replaced parent symlink.
        let verification = try safeHandle(for: candidate.url)
        try? verification.close()
        let transcript: SessionTranscript
        if let cached = transcriptCache[candidate.url.path], cached.candidate.matches(candidate) {
            readMetrics.cachedRolloutFiles += 1
            transcript = cached.transcript
            transcriptAccessOrder.removeAll { $0 == candidate.url.path }
            transcriptAccessOrder.append(candidate.url.path)
        } else {
            removeTranscript(at: candidate.url.path)
            let parsed = try parse(candidate, byteBudget: limits.maximumFileBytes)
            transcript = parsed.transcript
            cache[candidate.url.path] = CacheEntry(candidate: candidate, summary: transcript.summary, warnings: transcript.warnings)
            if catalogContinuation?.candidate.url == candidate.url { catalogContinuation = nil }
            retainTranscript(transcript, for: candidate)
        }
        var warnings = transcript.warnings
        let titles = try loadTitleIndex(for: [transcript.summary.sessionID], warnings: &warnings)
        try Task.checkCancellation()
        return SessionTranscript(summary: applyingTitle(titles[transcript.summary.sessionID], to: transcript.summary),
                                 messages: transcript.messages, warnings: warnings)
    }

    /// The CLI's append-only title index is independent of rollout mtimes. Apply it
    /// after retrieving raw cached summaries, so edits/deletion need no rollout reparse.
    private func loadTitleIndex(for sessionIDs: Set<String>, warnings: inout [String]) throws -> [String: String] {
        try Task.checkCancellation()
        guard !sessionIDs.isEmpty else { return [:] }
        let file = rootURL.appendingPathComponent("session_index.jsonl")
        let metadata = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        let candidate = Candidate(url:file,bytes:metadata?.fileSize ?? 0,
                                  modified:metadata?.contentModificationDate ?? .distantPast,archived:false)
        if metadata?.isSymbolicLink != true, metadata?.isRegularFile == true,
           let cached = titleIndexCache, cached.candidate.matches(candidate), sessionIDs.isSubset(of:cached.sessionIDs) {
            do {
                let verification = try safeHandle(for:file)
                try? verification.close()
                cached.warnings.forEach { appendWarning($0,to:&warnings) }
                return cached.titles
            } catch { titleIndexCache = nil }
        }
        var indexWarnings: [String] = []
        let titles = try readTitleIndex(for:sessionIDs,warnings:&indexWarnings)
        if metadata?.isSymbolicLink != true, metadata?.isRegularFile == true,
           !indexWarnings.contains(where:{ $0.contains("无法读取") }) {
            titleIndexCache = TitleIndexCacheEntry(candidate:candidate,sessionIDs:sessionIDs,titles:titles,warnings:indexWarnings)
        } else { titleIndexCache = nil }
        indexWarnings.forEach { appendWarning($0,to:&warnings) }
        return titles
    }

    private func readTitleIndex(for sessionIDs: Set<String>, warnings: inout [String]) throws -> [String: String] {
        try Task.checkCancellation()
        guard !sessionIDs.isEmpty else { return [:] }
        let file = rootURL.appendingPathComponent("session_index.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let metadata = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard metadata?.isSymbolicLink != true else {
            appendWarning("标题索引 session_index.jsonl 是符号链接，已忽略。", to: &warnings); return [:]
        }
        guard metadata?.isRegularFile == true else {
            appendWarning("标题索引 session_index.jsonl 无法读取，使用会话内的标题。", to: &warnings); return [:]
        }
        var titles: [String: String] = [:]
        do {
            let handle = try safeHandle(for: file)
            defer { try? handle.close() }
            let byteBudget = min(8 * 1_024 * 1_024, limits.maximumFileBytes)
            var pending = Data(), oversized = false
            var bytesRead = 0, lines = 0
            var reachedEOF = false, lineLimitReached = false
            func consume(_ data: Data, final: Bool) {
                autoreleasepool { consumeRecord(data, final: final) }
            }
            func consumeRecord(_ data: Data, final: Bool) {
                guard !data.isEmpty, !data.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) else { return }
                guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    appendWarning(final ? "标题索引末行未完整写入或格式无效，已保留之前的标题。"
                                  : "标题索引包含无效 JSONL 记录，已跳过。", to: &warnings)
                    return
                }
                guard let id = value["id"] as? String, sessionIDs.contains(id),
                      let raw = value["thread_name"] as? String else { return }
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                // Later append-only entries win, as in the original adapter. Only
                // IDs belonging to the bounded catalog are retained in memory.
                titles[id] = String(name.prefix(140))
            }
            while bytesRead < byteBudget, !lineLimitReached {
                let chunkReachedEOF = try autoreleasepool { () throws -> Bool in
                    try Task.checkCancellation()
                    let chunk = try handle.read(upToCount: min(64 * 1_024, byteBudget - bytesRead)) ?? Data()
                    guard !chunk.isEmpty else { return true }
                    bytesRead += chunk.count
                    readMetrics.titleIndexBytesRead += chunk.count
                    var start = chunk.startIndex
                    while start < chunk.endIndex {
                        try Task.checkCancellation()
                        let newline = chunk[start...].firstIndex(of: 10)
                        let end = newline ?? chunk.endIndex
                        if !oversized {
                            if pending.count + chunk.distance(from: start, to: end) > limits.maximumLineBytes {
                                oversized = true; pending.removeAll(keepingCapacity: true)
                                appendWarning("标题索引单行超过读取上限，已跳过该记录。", to: &warnings)
                            } else { pending.append(contentsOf: chunk[start..<end]) }
                        }
                        if let newline {
                            lines += 1
                            if !oversized { consume(pending, final: false) }
                            pending.removeAll(keepingCapacity: true); oversized = false
                            if lines >= 50_000 {
                                lineLimitReached = true
                                appendWarning("标题索引已达 50000 行上限，部分标题可能未更新。", to: &warnings)
                                break
                            }
                            start = chunk.index(after: newline)
                        } else { break }
                    }
                    return false
                }
                if chunkReachedEOF { reachedEOF = true; break }
            }
            if !reachedEOF, !lineLimitReached, bytesRead == byteBudget {
                let probe = try handle.read(upToCount: 1) ?? Data()
                readMetrics.titleIndexBytesRead += probe.count
                reachedEOF = probe.isEmpty
            }
            if reachedEOF, !pending.isEmpty, !oversized { consume(pending, final: true) }
            else if !reachedEOF, !lineLimitReached {
                appendWarning("标题索引读取达到大小上限，部分标题可能未更新。", to: &warnings)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            appendWarning("标题索引 session_index.jsonl 无法读取，使用会话内的标题。", to: &warnings)
        }
        return titles
    }

    private func applyingTitle(_ title: String?, to summary: CodexSessionSummary) -> CodexSessionSummary {
        guard let title else { return summary }
        return CodexSessionSummary(id: summary.id, sessionID: summary.sessionID, fileURL: summary.fileURL,
                                   title: title, projectPath: summary.projectPath, startedAt: summary.startedAt,
                                   updatedAt: summary.updatedAt, model: summary.model, messageCount: summary.messageCount,
                                   toolCallCount: summary.toolCallCount, tokens: summary.tokens,
                                   isArchived: summary.isArchived, searchText: summary.searchText)
    }

    private func parse(_ candidate: Candidate, byteBudget: Int, retainsMessages: Bool = true,
                       continuation: CatalogContinuation? = nil) throws -> ParsedFile {
        try Task.checkCancellation()
        let handle = try safeHandle(for: candidate.url)
        defer { try? handle.close() }
        var parser = continuation?.parser ?? CodexRolloutParser(fileURL: candidate.url, updatedAt: candidate.modified,
                                       isArchived: candidate.archived, limits: limits, retainsMessages: retainsMessages)
        if let continuation { try handle.seek(toOffset: UInt64(continuation.bytesRead)) }
        readMetrics.parsedRolloutFiles += 1
        var pending = continuation?.pending ?? Data()
        var oversized = continuation?.oversized ?? false
        var bytesRead = 0
        var lineNumber = continuation?.lineNumber ?? 0
        var reachedEOF = false
        while bytesRead < byteBudget {
            // FileHandle returns bridged NSData; a pool around consume alone
            // would still accumulate every read chunk until the whole scan ends.
            let chunkReachedEOF = try autoreleasepool { () throws -> Bool in
                try Task.checkCancellation()
                let count = min(64 * 1_024, byteBudget - bytesRead)
                let chunk = try handle.read(upToCount: count) ?? Data()
                guard !chunk.isEmpty else { return true }
                bytesRead += chunk.count
                readMetrics.rolloutBytesRead += chunk.count
                var start = chunk.startIndex
                while start < chunk.endIndex {
                    try Task.checkCancellation()
                    let newline = chunk[start...].firstIndex(of: 10)
                    let end = newline ?? chunk.endIndex
                    if !oversized {
                        if pending.count + chunk.distance(from: start, to: end) > limits.maximumLineBytes {
                            oversized = true; pending.removeAll(keepingCapacity: true)
                            parser.warn("单行超过 \(limits.maximumLineBytes / 1_024) KiB，已跳过该记录。")
                        } else { pending.append(contentsOf: chunk[start..<end]) }
                    }
                    if let newline {
                        lineNumber += 1
                        if !oversized { parser.consume(pending, line: lineNumber, isFinalLine: false) }
                        pending.removeAll(keepingCapacity: true); oversized = false
                        start = chunk.index(after: newline)
                    } else { break }
                }
                return false
            }
            if chunkReachedEOF { reachedEOF = true; break }
        }
        if !reachedEOF, bytesRead == byteBudget {
            let probe = try handle.read(upToCount: 1) ?? Data()
            readMetrics.rolloutBytesRead += probe.count
            reachedEOF = probe.isEmpty
        }
        if reachedEOF, !pending.isEmpty, !oversized {
            parser.consume(pending, line: lineNumber + 1, isFinalLine: true)
        }
        let fileBytesRead = (continuation?.bytesRead ?? 0) + bytesRead
        let catalogBudgetTruncated = !retainsMessages && !reachedEOF && fileBytesRead < limits.maximumFileBytes
        let nextContinuation = catalogBudgetTruncated
            ? CatalogContinuation(candidate: candidate, parser: parser, pending: pending, oversized: oversized,
                                  bytesRead: fileBytesRead, lineNumber: lineNumber) : nil
        var snapshot = parser
        if !reachedEOF {
            snapshot.warn(catalogBudgetTruncated
                ? "本次索引读取达到大小上限；刷新会从当前位置继续，消息和 Token 暂不完整。"
                : "读取达到文件大小上限，仅展示已完整读取的记录；消息和 Token 可能不完整。")
        }
        return ParsedFile(transcript: snapshot.finish(), bytesRead: bytesRead,
                          catalogBudgetTruncated: catalogBudgetTruncated, continuation: nextContinuation)
    }

    private func relativePath(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url.isFileURL, path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        guard relative.hasPrefix("sessions/") || relative.hasPrefix("archived_sessions/") else { return nil }
        return relative
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        guard relativePath(url) != nil else { return false }
        let resolved = url.resolvingSymlinksInPath()
        return relativePath(resolved) != nil
    }

    // Walk every component with openat + O_NOFOLLOW. This also protects against a
    // symlink swapped in after directory enumeration, including parent directories.
    private func safeHandle(for url: URL) throws -> FileHandle {
        let path: String
        if url.isFileURL, url.standardizedFileURL.path == rootURL.appendingPathComponent("session_index.jsonl").path {
            path = "session_index.jsonl"
        } else if let relative = relativePath(url), url.pathExtension.lowercased() == "jsonl" {
            path = relative
        } else { throw SessionReadError.invalidSessionPath }
        var descriptor = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SessionReadError.inaccessibleRoot }
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            if Task.isCancelled { Darwin.close(descriptor); throw CancellationError() }
            let last = index == components.count - 1
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? 0 : O_DIRECTORY))
            Darwin.close(descriptor)
            guard next >= 0 else { throw SessionReadError.inaccessibleSession }
            descriptor = next
        }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor); throw SessionReadError.inaccessibleSession
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func appendWarning(_ warning: String, to values: inout [String]) {
        guard values.count < 200, !values.contains(warning) else { return }
        values.append(warning)
    }

    private func acquireReadLock() throws {
        try Task.checkCancellation()
        // NSLock.lock() cannot respond to a cancelled detail request while a large
        // catalog read owns the lock. Poll only on contention, off the UI actor.
        while !lock.try() {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.005)
        }
        do { try Task.checkCancellation() }
        catch { lock.unlock(); throw error }
    }

    private func removeTranscript(at path: String) {
        if let entry = transcriptCache.removeValue(forKey: path) { transcriptCacheBytes -= entry.retainedBytes }
        transcriptAccessOrder.removeAll { $0 == path }
    }

    private func retainTranscript(_ transcript: SessionTranscript, for candidate: Candidate) {
        guard limits.maximumCachedTranscripts > 0 else { return }
        // Charge UTF-8 bodies plus per-record overhead. Large transcripts remain
        // viewable but are never retained merely because they were opened once.
        var retainedBytes = transcript.summary.searchText.utf8.count
        for message in transcript.messages {
            retainedBytes += message.text.utf8.count + message.id.utf8.count + 128
            if let name = message.toolName { retainedBytes += name.utf8.count }
            if let callID = message.callID { retainedBytes += callID.utf8.count }
            guard retainedBytes <= limits.maximumCachedTranscriptBytes else { return }
        }
        guard retainedBytes <= limits.maximumCachedTranscriptBytes else { return }
        while transcriptCache.count >= limits.maximumCachedTranscripts
                || transcriptCacheBytes > limits.maximumCachedTranscriptBytes - retainedBytes {
            guard let oldest = transcriptAccessOrder.first else { break }
            removeTranscript(at: oldest)
        }
        transcriptCache[candidate.url.path] = TranscriptCacheEntry(candidate: candidate, transcript: transcript,
                                                                  retainedBytes: retainedBytes)
        transcriptAccessOrder.append(candidate.url.path)
        transcriptCacheBytes += retainedBytes
    }

    private struct Candidate {
        let url: URL; let bytes: Int; let modified: Date; let archived: Bool
        let revision: FileRevision?

        init(url: URL, bytes: Int, modified: Date, archived: Bool) {
            self.url = url; self.bytes = bytes; self.modified = modified; self.archived = archived
            var info = stat()
            revision = Darwin.lstat(url.path, &info) == 0
                ? FileRevision(device: info.st_dev, inode: info.st_ino,
                               changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
                : nil
        }

        func matches(_ value: Candidate) -> Bool {
            // Atomic rewrites and same-size in-place edits can preserve mtime. A
            // missing identity is never considered trustworthy for a cache hit.
            revision != nil && revision == value.revision && bytes == value.bytes
                && modified == value.modified && archived == value.archived
        }
    }
    private struct FileRevision: Equatable {
        let device: dev_t; let inode: ino_t; let changedSeconds: Int; let changedNanoseconds: Int
    }
    private struct CacheEntry {
        let candidate: Candidate; let summary: CodexSessionSummary; let warnings: [String]
        func matches(_ value: Candidate) -> Bool { candidate.matches(value) }
    }
    private struct TranscriptCacheEntry {
        let candidate: Candidate; let transcript: SessionTranscript; let retainedBytes: Int
    }
    private struct TitleIndexCacheEntry {
        let candidate: Candidate; let sessionIDs: Set<String>; let titles: [String:String]; let warnings: [String]
    }
    private struct ParsedFile {
        let transcript: SessionTranscript; let bytesRead: Int; let catalogBudgetTruncated: Bool
        let continuation: CatalogContinuation?
    }
    private struct CatalogContinuation {
        let candidate: Candidate; let parser: CodexRolloutParser; let pending: Data; let oversized: Bool
        let bytesRead: Int; let lineNumber: Int
    }
}
