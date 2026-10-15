import Foundation
import CNative

public struct MemoryStoreReadMetrics {
    public fileprivate(set) var decodedSnapshots = 0
    public fileprivate(set) var reusedSnapshots = 0
    public fileprivate(set) var cachedPayloadBytes = 0
}

/// Local snapshot history. Process arguments and conversation content are never stored.
public final class MemoryStore {
    private var database: OpaquePointer?
    private let readOnly: Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let decodedCacheByteLimit: Int
    private var decodedCache: [String: (snapshot: MemorySnapshot, bytes: Int)] = [:]
    private var cachedPayloadBytes = 0
    private var cacheDataVersion: Int64?
    public private(set) var lastReadMetrics = MemoryStoreReadMetrics()

    public init(url: URL, readOnly: Bool = false, decodedCacheByteLimit: Int = 0) throws {
        guard url.isFileURL else { throw MemoryError.message("数据库必须使用本地文件 URL。") }
        self.readOnly = readOnly
        self.decodedCacheByteLimit = max(0, decodedCacheByteLimit)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if readOnly {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MemoryError.message("历史数据库不存在：\(url.lastPathComponent)。请先运行一次采样。")
            }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let handle { sqlite3_close_v2(handle) }
            throw MemoryError.message("打开历史数据库失败（\(result)）：\(detail)")
        }
        database = handle
        do {
            guard sqlite3_busy_timeout(handle, 5_000) == SQLITE_OK else {
                throw sqliteError("设置数据库等待时间")
            }
            if !readOnly {
                try execute("PRAGMA journal_mode=WAL")
                try execute("CREATE TABLE IF NOT EXISTS snapshots (id TEXT PRIMARY KEY, captured_at REAL NOT NULL, payload BLOB NOT NULL)")
                try execute("CREATE INDEX IF NOT EXISTS snapshots_captured_at ON snapshots(captured_at)")
            }
        } catch {
            sqlite3_close_v2(handle)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close_v2(database) } }

    public func save(_ snapshot: MemorySnapshot) throws {
        try requireWritable()
        let data = try encoder.encode(snapshot)
        let statement = try prepare("INSERT INTO snapshots(id, captured_at, payload) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET captured_at=excluded.captured_at, payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try check(sqlite3_bind_text(statement, 1, snapshot.id, -1, transient), "绑定快照 ID")
        try check(sqlite3_bind_double(statement, 2, snapshot.capturedAt.timeIntervalSince1970), "绑定采样时间")
        try data.withUnsafeBytes { bytes in
            try check(sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(data.count), transient), "绑定快照数据")
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError("保存快照") }
        // This connection's commits do not change PRAGMA data_version. Invalidate
        // upserts explicitly, including replacements with the same timestamp.
        if let old = decodedCache.removeValue(forKey: snapshot.id) { cachedPayloadBytes -= old.bytes }
    }

    public func latest() throws -> MemorySnapshot? {
        try query("SELECT payload FROM snapshots ORDER BY captured_at DESC, id DESC LIMIT 1").first
    }

    /// Changes only when another SQLite connection commits. A sampling owner can
    /// advance its in-memory window with its own saved values until this changes.
    public func dataVersion() throws -> Int64 {
        let statement = try prepare("PRAGMA data_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError("读取历史版本") }
        return sqlite3_column_int64(statement, 0)
    }

    /// Includes the latest snapshot before `since`, when available, as the comparison baseline.
    /// The default budget covers a two-hour window at one sample per second plus its baseline.
    public func load(since: Date, maxSamples: Int = 10_000) throws -> [MemorySnapshot] {
        guard maxSamples > 0 else { throw MemoryError.message("历史快照读取上限必须大于零。") }
        lastReadMetrics = .init()
        try execute("BEGIN DEFERRED")
        var committed = false
        defer { if !committed { try? execute("ROLLBACK") } }
        let bindings = [since.timeIntervalSince1970, since.timeIntervalSince1970]
        // Count before touching the JSON payloads so a seven-day window cannot
        // load all raw process samples into the observer's own memory.
        // Split the baseline and range: the OR predicate made SQLite walk the
        // entire retained history when the ordered payload query used its index.
        let countStatement = try prepare("SELECT (SELECT COUNT(*) FROM snapshots WHERE captured_at >= ?) + EXISTS(SELECT 1 FROM snapshots WHERE captured_at < ?)")
        defer { sqlite3_finalize(countStatement) }
        for (index, value) in bindings.enumerated() {
            try check(sqlite3_bind_double(countStatement, Int32(index + 1), value), "绑定历史读取时间")
        }
        guard sqlite3_step(countStatement) == SQLITE_ROW else { throw sqliteError("统计历史快照") }
        if sqlite3_column_int64(countStatement, 0) > Int64(maxSamples) { throw sampleLimitError(maxSamples) }
        // COUNT establishes the SQLite read snapshot before checking other
        // connections' commits. Cache and payloads thus see one database version.
        if decodedCacheByteLimit > 0 {
            let version = try dataVersion()
            if cacheDataVersion != version {
                decodedCache.removeAll(keepingCapacity: true); cachedPayloadBytes = 0
                cacheDataVersion = version
            }
        }
        var result = try query("SELECT payload, id FROM snapshots WHERE captured_at < ? ORDER BY captured_at DESC, id DESC LIMIT 1",
            bindings: [bindings[0]], rowLimit: 1, reuseDecoded: decodedCacheByteLimit > 0)
        result += try query("SELECT payload, id FROM snapshots WHERE captured_at >= ? ORDER BY captured_at ASC, id ASC",
            bindings: [bindings[0]], rowLimit: maxSamples - result.count, reuseDecoded: decodedCacheByteLimit > 0)
        try execute("COMMIT"); committed = true
        let retained = Set(result.map(\.id))
        for id in Array(decodedCache.keys) where !retained.contains(id) {
            if let old = decodedCache.removeValue(forKey: id) { cachedPayloadBytes -= old.bytes }
        }
        lastReadMetrics.cachedPayloadBytes = cachedPayloadBytes
        return result
    }

    /// Keep every sample for 24 hours, one sample per minute for the preceding six days,
    /// and remove history older than seven days. This is one atomic transaction.
    @discardableResult
    public func maintenance(now: Date = Date()) throws -> Int {
        try requireWritable()
        let week = now.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970
        let day = now.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM snapshots WHERE captured_at < ?", bindings: [week])
            var removed = Int(sqlite3_changes(database))
            try execute("DELETE FROM snapshots WHERE id IN (SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY CAST(captured_at / 60 AS INTEGER) ORDER BY captured_at DESC, id DESC) AS ordinal FROM snapshots WHERE captured_at < ?) WHERE ordinal > 1)", bindings: [day])
            removed += Int(sqlite3_changes(database))
            try execute("COMMIT")
            return removed
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func requireWritable() throws {
        guard !readOnly else { throw MemoryError.message("数据库以只读方式打开，不能保存或清理快照。") }
    }

    private func sqliteError(_ operation: String) -> MemoryError {
        let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库已关闭"
        return .message("\(operation)失败：\(detail)")
    }

    private func check(_ result: Int32, _ operation: String) throws {
        guard result == SQLITE_OK else { throw sqliteError(operation) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw sqliteError("准备数据库查询")
        }
        return statement
    }

    private func execute(_ sql: String, bindings: [Double] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            try check(sqlite3_bind_double(statement, Int32(index + 1), value), "绑定数据库参数")
        }
        // PRAGMA journal_mode returns a row; consume it before SQLITE_DONE.
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw sqliteError("执行数据库操作") }
    }

    private func sampleLimitError(_ limit: Int) -> MemoryError {
        .message("历史快照超过 \(limit) 条读取上限，请缩短观察窗口（since/window）后重试；本次没有截断或降采样结果。")
    }

    private func query(_ sql: String, bindings: [Double] = [], rowLimit: Int? = nil,
                       reuseDecoded: Bool = false) throws -> [MemorySnapshot] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            try check(sqlite3_bind_double(statement, Int32(index + 1), value), "绑定查询时间")
        }
        var snapshots: [MemorySnapshot] = []
        var metadata = MemoryProcessMetadataPool()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return snapshots }
            guard result == SQLITE_ROW else { throw sqliteError("读取历史快照") }
            // Also enforce the limit while streaming in case another writer
            // commits samples between the COUNT and payload query.
            if let rowLimit, snapshots.count >= rowLimit { throw sampleLimitError(rowLimit) }
            let id = reuseDecoded ? sqlite3_column_text(statement, 1).map { String(cString: $0) } : nil
            if let id, let cached = decodedCache[id] {
                snapshots.append(cached.snapshot); lastReadMetrics.reusedSnapshots += 1
                continue
            }
            let length = Int(sqlite3_column_bytes(statement, 0))
            guard length > 0, let bytes = sqlite3_column_blob(statement, 0) else {
                throw MemoryError.message("历史快照数据为空或损坏。")
            }
            do {
                // JSONDecoder and Data can create autoreleased Foundation objects.
                // Drain each row's temporaries while keeping the decoded Swift value
                // alive, rather than retaining a full window's decoding scratch space.
                var snapshot = try autoreleasepool {
                    try decoder.decode(MemorySnapshot.self, from: Data(bytes: bytes, count: length))
                }
                metadata.canonicalize(&snapshot)
                snapshots.append(snapshot); lastReadMetrics.decodedSnapshots += 1
                if let id, length <= decodedCacheByteLimit - cachedPayloadBytes {
                    decodedCache[id] = (snapshot, length); cachedPayloadBytes += length
                }
            } catch {
                throw MemoryError.message("历史快照无法解析：\(error.localizedDescription)")
            }
        }
    }
}

/// Stable native metadata repeats across most samples. Reuse equal string storage
/// while keeping every process measurement; bound unique metadata independently.
/// The pool never stores payloads, arguments, conversation content or snapshot IDs.
struct MemoryProcessMetadataPool {
    private var strings: [String: String] = [:]
    private var bytes = 0
    private let maximumEntries = 2_048
    private let maximumBytes = 4 * 1_024 * 1_024
    var cachedStringCount: Int { strings.count }
    var cachedStringBytes: Int { bytes }

    mutating func canonicalized(_ snapshot: MemorySnapshot) -> MemorySnapshot {
        var result = snapshot
        canonicalize(&result)
        return result
    }

    mutating func canonicalize(_ snapshot: inout MemorySnapshot) {
        for index in snapshot.processes.indices { canonicalize(&snapshot.processes[index]) }
        if snapshot.observer != nil { canonicalize(&snapshot.observer!) }
    }

    mutating func observe(_ snapshot: MemorySnapshot) {
        for var process in snapshot.processes { canonicalize(&process) }
        if var observer = snapshot.observer { canonicalize(&observer) }
    }

    private mutating func canonicalize(_ process: inout ProcessSample) {
        process.bootID = intern(process.bootID)
        process.executable = intern(process.executable)
        process.roleHint = intern(process.roleHint)
        process.rootKey = intern(process.rootKey)
        process.ownership = intern(process.ownership)
    }

    private mutating func intern(_ value: String) -> String {
        let length = value.utf8.count
        // Swift stores short strings inline, so pooling them adds table overhead.
        guard length > 15 else { return value }
        if let existing = strings[value] {
            // String equality normalizes Unicode; executable paths and encoded
            // exports must retain their original byte representation as well.
            return existing.utf8.elementsEqual(value.utf8) ? existing : value
        }
        if strings.count < maximumEntries, length <= maximumBytes - bytes {
            strings[value] = value; bytes += length
        }
        return value
    }
}
