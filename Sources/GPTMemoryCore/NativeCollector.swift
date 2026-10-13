import Foundation
import CNative
import Darwin

public enum ProcessClassifier {
    public static func isAppRoot(executable: String) -> Bool {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return (name == "ChatGPT" || name == "Codex") && executable.contains(".app/Contents/MacOS/")
    }

    public static func classify(executable: String, safeHint: String) -> ProcessRole {
        if isAppRoot(executable: executable) { return .appMain }
        if let hint = ProcessRole(rawValue: safeHint), !safeHint.isEmpty { return hint }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if name.contains("(Renderer)") { return .renderer }
        if name.contains("(Service)") || name == "SkyComputerUseService" { return .appService }
        if name == "node_repl" { return .repl }
        if name == "node" { return .unknownNode }
        if name == "codex" || name == "codex-code-mode-host" { return .codexBackend }
        return .other
    }
}

public final class NativeCollector {
    private let bootID: String
    private var priorCPU: [String: (UInt64, Double)] = [:]
    private var cachedRoleHints: [String: String] = [:]
    private var knownOwners: [String: String] = [:]
    private var priorOwnedPIDs: [Int: (String, String)] = [:]

    public init() {
        var buffer = [CChar](repeating: 0, count: 128)
        let result = gpt_boot_id(&buffer, buffer.count)
        // A random fallback would falsely classify all processes as new after watch restarts.
        // The key still contains the absolute microsecond birth timestamp when boot ID is unavailable.
        bootID = result == 0 ? String(cString: buffer) : "boot-unavailable-start-epoch"
    }

    private func string<T>(_ array: inout T) -> String {
        withUnsafePointer(to: &array) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }

    public func sample() throws -> MemorySnapshot {
        let capturedAt = Date()
        let now = gpt_monotonic_seconds()
        var pointer: UnsafeMutablePointer<Int32>?
        let count = gpt_list_pids(&pointer)
        guard count > 0, let pointer = pointer else {
            throw MemoryError.message("无法读取 macOS 进程列表：\(String(cString: strerror(errno)))。请在普通本机终端运行；受限执行环境可能禁止进程查询。")
        }
        defer { free(pointer) }
        var native: [Int: gpt_process_info] = [:]
        var failedPIDs: Set<Int> = []
        for i in 0..<Int(count) {
            let pid = pointer[i]
            if pid <= 0 { continue }
            var info = gpt_process_info()
            if gpt_read_process(pid, &info) == 0 { native[Int(pid)] = info }
            else { failedPIDs.insert(Int(pid)) }
        }
        guard !native.isEmpty else {
            throw MemoryError.message("进程枚举成功但无法读取任何进程信息；当前环境限制了 libproc 权限。")
        }
        var values: [Int: ProcessSample] = [:]
        for (pid, var info) in native {
            let executable = string(&info.executable)
            values[pid] = ProcessSample(bootID: bootID, pid: pid, parentPID: Int(info.parent_pid),
                startTimeTicks: info.start_ticks, startedAt: Date(timeIntervalSince1970: info.started_at),
                executable: executable, role: ProcessClassifier.classify(executable: executable, safeHint: ""),
                footprintBytes: info.footprint_bytes, rssBytes: info.rss_bytes,
                peakFootprintBytes: info.peak_footprint_bytes,
                absoluteStartTimeMicroseconds: info.start_ticks)
        }
        let roots = values.values.filter { $0.role == .appMain }
        var owners: [String: String] = Dictionary(uniqueKeysWithValues: roots.map { ($0.key, $0.key) })
        var remembered: Set<String> = []
        for value in values.values {
            if let owner = knownOwners[value.key], owners[value.key] == nil {
                owners[value.key] = owner; remembered.insert(value.key)
            }
        }
        var changed = true
        while changed {
            changed = false
            for value in values.values where owners[value.key] == nil {
                if let parent = values[value.parentPID], parent.startTimeTicks <= value.startTimeTicks,
                   let owner = owners[parent.key] {
                    owners[value.key] = owner; changed = true
                }
            }
        }
        // Exclude every observer instance and its descendants even when launched by Codex.
        var observerPIDs = Set(values.values.filter {
            ["gpt-mem", "gpt-manager"].contains(URL(fileURLWithPath: $0.executable).lastPathComponent) || $0.pid == Int(getpid())
        }.map(\.pid))
        changed = true
        while changed {
            changed = false
            for value in values.values where !observerPIDs.contains(value.pid) {
                if observerPIDs.contains(value.parentPID) { observerPIDs.insert(value.pid); changed = true }
            }
        }
        var monitored: [ProcessSample] = []
        var unavailable: [Int] = []
        var nextCPU: [String: (UInt64, Double)] = [:]
        var nextHints: [String: String] = [:]
        var nextOwners: [String: String] = [:]
        var nextOwnedPIDs: [Int: (String, String)] = [:]
        for pid in failedPIDs {
            if let (key, owner) = priorOwnedPIDs[pid] {
                unavailable.append(pid)
                nextOwners[key] = owner
                nextOwnedPIDs[pid] = (key, owner)
            }
        }
        for (pid, var value) in values {
            let isSelf = pid == Int(getpid())
            guard let owner = owners[value.key], !observerPIDs.contains(pid) else {
                if isSelf, let info = native[pid], info.metrics_valid != 0 {
                    value.cpuPercent = cpuPercent(key: value.key, cpu: info.cpu_time_ns, now: now)
                    nextCPU[value.key] = (info.cpu_time_ns, now)
                    values[pid] = value
                }
                continue
            }
            nextOwners[value.key] = owner
            nextOwnedPIDs[pid] = (value.key, owner)
            guard let info = native[pid], info.metrics_valid != 0 else { unavailable.append(pid); continue }
            let hint: String
            if let previous = cachedRoleHints[value.key] {
                hint = previous
            } else {
                var buffer = [CChar](repeating: 0, count: 64)
                if value.role == .unknownNode || value.role == .renderer || value.role == .appService {
                    gpt_read_role_hint(Int32(pid), &buffer, buffer.count)
                }
                hint = String(cString: buffer)
            }
            nextHints[value.key] = hint
            value.roleHint = hint
            value.role = ProcessClassifier.classify(executable: value.executable, safeHint: hint)
            value.rootKey = owner
            value.ownership = remembered.contains(value.key) && native[pid]?.parent_pid == 1 ? "remembered_ancestry" : "process_tree"
            value.cpuPercent = cpuPercent(key: value.key, cpu: info.cpu_time_ns, now: now)
            nextCPU[value.key] = (info.cpu_time_ns, now)
            monitored.append(value)
        }
        // Cache only currently live instances, bounding observer memory over long runs.
        priorCPU = nextCPU; cachedRoleHints = nextHints; knownOwners = nextOwners
        priorOwnedPIDs = nextOwnedPIDs
        var sys = gpt_system_info(); gpt_read_system(&sys)
        var warnings: [String] = []
        if bootID == "boot-unavailable-start-epoch" { warnings.append("系统启动身份不可读取；使用 PID 加绝对微秒启动时间识别进程。") }
        if !unavailable.isEmpty { warnings.append("\(unavailable.count) 个应用子进程的内存指标不可读取；合计不包含这些进程。") }
        if roots.isEmpty && monitored.isEmpty { warnings.append("当前未发现运行中的 ChatGPT/Codex 桌面应用。") }
        if sys.pressure_valid == 0 { warnings.append("当前环境无法读取系统内存压力等级。") }
        let unknownCount = monitored.filter { $0.role == .unknownNode }.count
        if unknownCount > 0 { warnings.append("\(unknownCount) 个 Node 的服务角色未确认，已单列，未计作 MCP。") }
        var observer = values[Int(getpid())]
        if native[Int(getpid())]?.metrics_valid == 0 { observer = nil }
        observer?.ownership = "observer"
        observer?.rootKey = "observer"
        return MemorySnapshot(capturedAt: capturedAt,
            processes: monitored.sorted { $0.footprintBytes > $1.footprintBytes }, observer: observer,
            system: .init(physicalBytes: sys.physical_bytes,
                compressedPhysicalBytes: sys.compressed_valid != 0 ? sys.compressed_physical_bytes : nil,
                swapUsedBytes: sys.swap_valid != 0 ? sys.swap_used_bytes : nil,
                pressureLevel: sys.pressure_valid != 0 ? Int(sys.pressure_level) : nil),
            unavailablePIDs: unavailable.sorted(), warnings: warnings)
    }

    private func cpuPercent(key: String, cpu: UInt64, now: Double) -> Double? {
        guard let (oldCPU, oldTime) = priorCPU[key], now > oldTime, cpu >= oldCPU else { return nil }
        return Double(cpu - oldCPU) / 1_000_000_000 / (now - oldTime) * 100
    }
}

public final class MonitorLock {
    private var fd: Int32
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = url.path.withCString { gpt_lock_acquire($0) }
        guard fd >= 0 else {
            if errno == EWOULDBLOCK { throw MemoryError.monitorBusy }
            throw MemoryError.message("无法取得监控锁（可能已有 watch 正在运行）：\(String(cString: strerror(errno)))。不会停止现有进程。")
        }
    }
    deinit { gpt_lock_release(fd) }
}
