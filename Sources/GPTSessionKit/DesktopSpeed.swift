import Foundation
import CoreFoundation
import Darwin

public struct DesktopSpeedSample: Identifiable, Equatable, Sendable {
    public let id: String
    public let model: String
    public let sessionID: String
    public let start: Date
    public let end: Date
    public let output: Int
    public let reasoning: Int?
    public let firstInTurn: Bool
    public var seconds: Double { end.timeIntervalSince(start) }
    /// Wall-clock efficiency between usage records, not streaming generation speed.
    public var intervalRate: Double { Double(output) / seconds }
}
public struct DesktopSpeedSnapshot: Sendable {
    public let samples: [DesktopSpeedSample]
    public let files: Int
    public let pendingFiles: Int
    public let warnings: [String]
    public init(samples: [DesktopSpeedSample] = [], files: Int = 0, pendingFiles: Int = 0, warnings: [String] = []) {
        self.samples = samples; self.files = files; self.pendingFiles = pendingFiles; self.warnings = warnings
    }
}
struct DesktopSpeedParser {
    var desktop = false
    var model = "未记录模型"
    var session = "未知会话"
    var start: Date?
    var first = true
    var turnID: String?
    var skipInterval = false
    var total: Int?
    var reasoning: Int?
    var rows: [DesktopSpeedSample] = []
    var warnings: Set<String> = []
    private let dates: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private let fallback = ISO8601DateFormatter()
    mutating func consume(_ data: Data, identity: String) {
        autoreleasepool {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = root["payload"] as? [String: Any] else { return }
            let type = root["type"] as? String
            if type == "session_meta" {
                let origin = payload["originator"] as? String ?? ""
                desktop = origin == "Codex Desktop" || origin == "ChatGPT Desktop"
                session = String((payload["id"] as? String ?? "未知会话").prefix(256))
            }
            guard desktop else { return }
            if type == "turn_context" {
                let next = String((payload["model"] as? String ?? "未记录模型").prefix(256))
                if next != model && model != "未记录模型" && start != nil { skipInterval = true; warnings.insert("模型切换后的首个混合区间已跳过。") }
                model = next; return
            }
            guard type == "event_msg", let subtype = payload["type"] as? String,
                  let stamp = root["timestamp"] as? String, let date = dates.date(from: stamp) ?? fallback.date(from: stamp) else { return }
            if subtype == "task_started" {
                let id = payload["turn_id"] as? String
                if let id, id == turnID, start != nil { return }
                turnID = id; start = date; first = true; skipInterval = false; return
            }
            if ["task_complete", "task_completed", "turn_aborted"].contains(subtype) {
                if let id = payload["turn_id"] as? String, let turnID, id != turnID { return }
                start = nil; return
            }
            guard subtype == "token_count", let info = payload["info"] as? [String: Any], let usage = info["total_token_usage"] as? [String: Any],
                  let output = Self.count(usage["output_tokens"]) else { return }
            let newReasoning = Self.count(usage["reasoning_output_tokens"])
            defer { total = output; reasoning = newReasoning }
            if let total, output == total { return } // Duplicate notifications must not shorten the next interval.
            if let total, output < total { warnings.insert("累计输出计数重置，已跳过该区间。"); if start != nil { start = date; first = false }; return }
            if skipInterval { skipInterval = false; if start != nil { start = date; first = false }; return }
            let delta: Int?
            let reasoningDelta: Int?
            if let total {
                delta = output - total
                if let old = reasoning, let newReasoning, newReasoning >= old { reasoningDelta = newReasoning - old } else { reasoningDelta = nil }
            } else {
                let last = info["last_token_usage"] as? [String: Any]
                delta = Self.count(last?["output_tokens"])
                reasoningDelta = Self.count(last?["reasoning_output_tokens"])
                guard delta == output else {
                    warnings.insert("首段累计用量没有可靠基线，已跳过首段速度。")
                    if start != nil { start = date; first = false }
                    return
                }
            }
            guard let intervalStart = start else { return }
            guard date > intervalStart, let delta, delta <= output, delta > 0 else { warnings.insert("部分用量缺少有效时间或增量，未计算速度。"); return }
            rows.append(.init(id: identity, model: model, sessionID: session, start: intervalStart, end: date, output: delta,
                              reasoning: reasoningDelta.flatMap { $0 <= delta ? $0 : nil }, firstInTurn: first))
            if rows.count > 500 { rows.removeFirst(rows.count - 500) }
            start = date; first = false
        }
    }
    private static func count(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d.rounded(.towardZero) == d, d < Double(Int.max) else { return nil }
        return n.intValue
    }
}

/// Bounded incremental metadata-only reader. No requests, UI interception, chat storage or source writes.
public final class DesktopSpeedReader: @unchecked Sendable {
    public let rootURL: URL
    private let lock = NSLock()
    private struct Cursor {
        var inode: UInt64; var device: UInt64; var offset: UInt64 = 0
        var modified: timespec; var changed: timespec
        var buffer = Data(); var skipping = false; var parser = DesktopSpeedParser()
    }
    private var cursors: [String: Cursor] = [:]
    public init(rootURL: URL = CodexSessionRepository.defaultRootURL) { self.rootURL = rootURL }
    public func read(now: Date = Date()) throws -> DesktopSpeedSnapshot {
        lock.lock(); defer { lock.unlock() }
        let sessions = rootURL.appendingPathComponent("sessions")
        var rootInfo = stat()
        guard lstat(sessions.path, &rootInfo) == 0 else { return .init(warnings: ["未找到本地 Codex sessions 目录。普通 ChatGPT 云端会话不在本监听范围中。"] ) }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR, rootInfo.st_uid == getuid() else { throw SessionIndexStoreError.unsafeLocation }
        guard let rootPath = realpath(sessions.path, nil) else { throw SessionIndexStoreError.unsafeLocation }
        let canonicalRoot = String(cString: rootPath); free(rootPath)
        var urls: [URL] = [], warnings: [String] = []
        var scanned: Set<String> = []
        let calendar = Calendar(identifier: .gregorian)
        let format = DateFormatter(); format.dateFormat = "yyyy/MM/dd"; format.locale = Locale(identifier: "en_US_POSIX")
        // Include both UTC and local day folders for desktop naming differences.
        for zone in [TimeZone(secondsFromGMT: 0)!, TimeZone.current] {
            format.timeZone = zone
            for day in 0..<3 {
                let date = calendar.date(byAdding: .day, value: -day, to: now)!
                let directory = sessions.appendingPathComponent(format.string(from: date))
                var info = stat()
                guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                guard scanned.insert(directory.path).inserted, let pointer = realpath(directory.path, nil) else { continue }
                let canonical = String(cString: pointer); free(pointer)
                guard canonical.hasPrefix(canonicalRoot + "/") else { warnings.append("跳过目录外链接日期目录。"); continue }
                guard let enumeration = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }
                var visited = 0
                for case let url as URL in enumeration {
                    visited += 1
                    if visited > 2000 { warnings.append("日期目录超过 2000 个项目，扫描结果不完整。"); break }
                    if url.pathExtension == "jsonl" { urls.append(url) }
                }
            }
        }
        let unique = Array(Set(urls)).map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast) }.sorted { $0.1 > $1.1 }.map { $0.0 }
        urls = Array(unique.prefix(32)); if unique.count > 32 { warnings.append("只监听近 3 天最近更新的 32 个日志文件。") }
        let keys = Set(urls.map(\.path)); cursors = cursors.filter { keys.contains($0.key) }
        var budget = 8 * 1024 * 1024, pending = 0
        for url in urls {
            guard budget > 0 else { pending += 1; continue }
            // Canonical containment rejects linked ancestors and paths outside sessions.
            guard let base = realpath(sessions.path, nil), let path = realpath(url.path, nil) else { continue }
            let baseString = String(cString: base), pathString = String(cString: path); free(base); free(path)
            guard pathString.hasPrefix(baseString + "/") else { warnings.append("跳过目录外链接日志。"); continue }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_size >= 0 else { continue }
            var cursor = cursors[url.path]
            if let old = cursor, old.inode != UInt64(info.st_ino) || old.device != UInt64(info.st_dev) || old.offset > UInt64(info.st_size)
                || (old.offset == UInt64(info.st_size) && (old.modified.tv_sec != info.st_mtimespec.tv_sec || old.modified.tv_nsec != info.st_mtimespec.tv_nsec || old.changed.tv_sec != info.st_ctimespec.tv_sec || old.changed.tv_nsec != info.st_ctimespec.tv_nsec)) { cursor = nil }
            var current = cursor ?? Cursor(inode: UInt64(info.st_ino), device: UInt64(info.st_dev), modified: info.st_mtimespec, changed: info.st_ctimespec)
            try handle.seek(toOffset: current.offset)
            let amount = min(budget, 2 * 1024 * 1024)
            let data = try handle.read(upToCount: amount) ?? Data(); budget -= data.count
            for byte in data {
                current.offset += 1
                if byte == 10 {
                    if !current.skipping { current.parser.consume(current.buffer, identity: url.lastPathComponent + ":" + String(current.offset)) }
                    current.buffer.removeAll(keepingCapacity: true); current.skipping = false
                } else if !current.skipping {
                    if current.buffer.count >= 1_048_576 { current.buffer.removeAll(keepingCapacity: true); current.skipping = true; warnings.append("跳过超过 1 MiB 的日志行，相关统计可能缺失。") }
                    else { current.buffer.append(byte) }
                }
            }
            current.modified = info.st_mtimespec; current.changed = info.st_ctimespec
            if current.offset < UInt64(info.st_size) { pending += 1 }
            cursors[url.path] = current
        }
        let all = cursors.values.flatMap { $0.parser.rows }
        let samples = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.filter { $0.end >= now.addingTimeInterval(-48 * 3600) }.sorted { $0.end > $1.end }
        warnings += cursors.values.flatMap { Array($0.parser.warnings) }
        return .init(samples: Array(samples.prefix(1000)), files: urls.count, pendingFiles: pending, warnings: Array(Set(warnings).sorted().prefix(30)))
    }
}
