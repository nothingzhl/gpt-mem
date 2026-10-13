import Foundation
import Darwin
import CNative

public enum ProcessExitKind: String, Codable, Sendable {
    case request, force
    public var label: String { self == .request ? "请求退出" : "强制结束" }
}

public struct ProcessExitReceipt: Codable, Identifiable, Sendable {
    public let id: String
    public let process: ProcessSample
    public let kind: ProcessExitKind
    public let requestedAt: Date
    public let before: MemorySnapshot
    public init(id: String = UUID().uuidString, process: ProcessSample, kind: ProcessExitKind,
                requestedAt: Date, before: MemorySnapshot) {
        self.id = id; self.process = process; self.kind = kind; self.requestedAt = requestedAt; self.before = before
    }
}

public enum ProcessInstanceState: String, Codable, Sendable {
    case running, exited, replaced, unknown
    public var label: String {
        switch self {
        case .running: return "原进程仍在运行"
        case .exited: return "原进程已退出"
        case .replaced: return "原 PID 已被其他实例使用"
        case .unknown: return "暂时无法核实目标状态"
        }
    }
}

public struct ProcessLiveIdentity: Sendable {
    public let birth: UInt64
    public let executable: String
    public init(birth: UInt64, executable: String) { self.birth = birth; self.executable = executable }
}

public enum ProcessLiveRead: Sendable { case found(ProcessLiveIdentity), missing, unavailable }

public struct ProcessExitObservation: Codable, Sendable {
    public let receipt: ProcessExitReceipt
    public let state: ProcessInstanceState
    public let after: MemorySnapshot
    public var replacementPIDs: [Int] {
        after.processes.filter {
            $0.key != receipt.process.key && $0.executable == receipt.process.executable
                && ($0.rootKey == receipt.process.rootKey || (receipt.process.role == .appMain && $0.role == .appMain))
                && $0.startedAt >= receipt.requestedAt.addingTimeInterval(-1)
        }.map(\.pid)
    }
    public var knownTotalChange: Int64? {
        guard receipt.before.unavailablePIDs.isEmpty, after.unavailablePIDs.isEmpty,
              after.capturedAt >= receipt.before.capturedAt,
              let beforeTotal = Self.total(receipt.before), let afterTotal = Self.total(after) else { return nil }
        return afterTotal - beforeTotal
    }
    private static func total(_ snapshot: MemorySnapshot) -> Int64? {
        var result: Int64 = 0
        for process in snapshot.processes {
            guard process.footprintBytes <= UInt64(Int64.max) else { return nil }
            let sum = result.addingReportingOverflow(Int64(process.footprintBytes))
            guard !sum.overflow else { return nil }; result = sum.partialValue
        }
        return result
    }
    public init(receipt: ProcessExitReceipt, state: ProcessInstanceState, after: MemorySnapshot) {
        self.receipt = receipt; self.state = state; self.after = after
    }
}

/// Injectable boundaries let checks verify refusal and effects without touching
/// any real application. Production always re-enumerates the owned process tree.
public final class ProcessControl: @unchecked Sendable {
    // Controller calls serialize even if clients use different queues. Injected
    // dependencies must not be mutated externally while a call is in progress.
    private let lock = NSRecursiveLock()
    private let sample: () throws -> MemorySnapshot
    private let read: (Int) -> ProcessLiveRead
    private let send: (ProcessSample, ProcessExitKind) throws -> Void
    private let protectedPIDs: Set<Int>
    private let now: () -> Date

    public init(sample: (() throws -> MemorySnapshot)? = nil,
                read: @escaping (Int) -> ProcessLiveRead = ProcessControl.readLive,
                send: @escaping (ProcessSample, ProcessExitKind) throws -> Void = ProcessControl.sendNative,
                protectedPIDs: Set<Int> = ProcessControl.observerAncestors(), now: @escaping () -> Date = Date.init) {
        let collector = NativeCollector()
        self.sample = sample ?? { try collector.sample() }
        self.read = read; self.send = send; self.protectedPIDs = protectedPIDs; self.now = now
    }

    public static func birth(_ process: ProcessSample) -> UInt64 {
        process.absoluteStartTimeMicroseconds ?? process.startTimeTicks
    }

    public func execute(process: ProcessSample, kind: ProcessExitKind,
                        previous: ProcessExitReceipt? = nil) throws -> ProcessExitReceipt {
        lock.lock(); defer { lock.unlock() }
        guard process.pid > 1, process.pid <= Int(Int32.max), !protectedPIDs.contains(process.pid),
              process.ownership == "process_tree", !process.rootKey.isEmpty,
              Self.birth(process) > 0 else { throw MemoryError.message("目标归属未确认或属于观察器及其父进程，不能执行退出操作。") }
        if kind == .force {
            guard let previous, previous.kind == .request, previous.process.key == process.key,
                  previous.process.executable == process.executable,
                  previous.process.rootKey == process.rootKey,
                  now().timeIntervalSince(previous.requestedAt) >= 5 else {
                throw MemoryError.message("请先请求同一进程正常退出，等待至少 5 秒并重新核实后再强制结束。")
            }
        }
        let before = try sample()
        guard let fresh = before.processes.first(where: { $0.key == process.key }),
              fresh.executable == process.executable, fresh.rootKey == process.rootKey,
              fresh.ownership == "process_tree", Self.hasCurrentAncestry(fresh, in: before) else {
            throw MemoryError.message("目标已经退出、归属变化或 PID 已复用；退出请求未发送。")
        }
        guard case .found(let live) = read(process.pid), live.birth == Self.birth(process),
              live.executable == process.executable else {
            throw MemoryError.message("目标身份无法确认，退出请求未发送。")
        }
        try send(fresh, kind)
        // A successful send means accepted/requested, never proof of exit.
        return .init(process: fresh, kind: kind, requestedAt: now(), before: before)
    }

    private static func hasCurrentAncestry(_ target: ProcessSample, in snapshot: MemorySnapshot) -> Bool {
        let byPID = Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var current = target, visited: Set<Int> = []
        for _ in 0..<64 {
            guard visited.insert(current.pid).inserted else { return false }
            if ProcessClassifier.isAppRoot(executable: current.executable) {
                return current.key == target.rootKey
            }
            guard let parent = byPID[current.parentPID], birth(parent) <= birth(current) else { return false }
            current = parent
        }
        return false
    }

    public func observe(_ receipt: ProcessExitReceipt) throws -> ProcessExitObservation {
        lock.lock(); defer { lock.unlock() }
        let after = try sample()
        let state: ProcessInstanceState
        switch read(receipt.process.pid) {
        case .missing: state = .exited
        case .unavailable: state = .unknown
        case .found(let live):
            state = live.birth == Self.birth(receipt.process) && live.executable == receipt.process.executable ? .running : .replaced
        }
        return .init(receipt: receipt, state: state, after: after)
    }

    public static func readLive(_ pid: Int) -> ProcessLiveRead {
        guard pid > 1, pid <= Int(Int32.max) else { return .unavailable }
        var info = gpt_process_info()
        if gpt_read_process(Int32(pid), &info) == 0 {
            let path = withUnsafePointer(to: &info.executable) {
                $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
            }
            return .found(.init(birth: info.start_ticks, executable: path))
        }
        if Darwin.kill(Int32(pid), 0) != 0 && errno == ESRCH { return .missing }
        return .unavailable
    }

    public static func observerAncestors() -> Set<Int> {
        var result: Set<Int> = [Int(getpid())]
        var pid = getppid()
        for _ in 0..<64 {
            guard pid > 1, result.insert(Int(pid)).inserted else { break }
            var info = gpt_process_info()
            guard gpt_read_process(pid, &info) == 0 else { break }
            pid = Int32(info.parent_pid)
        }
        return result
    }

    public static func sendNative(_ process: ProcessSample, _ kind: ProcessExitKind) throws {
        guard process.pid > 1, process.pid <= Int(Int32.max) else {
            throw MemoryError.message("退出目标 PID 无效。")
        }
        guard kind != .request || process.role != .appMain else {
            throw MemoryError.message("应用主进程的正常退出需要通过桌面应用请求。")
        }
        guard gpt_signal_process(Int32(process.pid), birth(process), process.executable,
                                 kind == .force ? SIGKILL : SIGTERM) == 0 else {
            throw MemoryError.message("退出请求未发送：\(String(cString: strerror(errno)))。")
        }
    }

    public static func validateNative(_ process: ProcessSample) throws {
        guard process.pid > 1, process.pid <= Int(Int32.max),
              gpt_validate_process(Int32(process.pid), birth(process), process.executable) == 0 else {
            throw MemoryError.message("目标身份或本机用户无法确认；退出请求未发送。")
        }
    }
}
