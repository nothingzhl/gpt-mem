import Foundation
import AppKit
import Combine
import Darwin
import GPTMemoryCore

struct ProcessActionTrendPoint: Codable, Sendable {
    let capturedAt: Date
    let footprintBytes: UInt64?
}

struct MemoryProcessActionRequest: Identifiable, Sendable {
    let id = UUID()
    let process: ProcessSample
    let kind: ProcessExitKind
    let relatedProcessCount: Int
    let trend: [ProcessActionTrendPoint]
    init(process: ProcessSample, kind: ProcessExitKind, relatedProcessCount: Int, trend: [ProcessActionTrendPoint] = []) {
        self.process = process; self.kind = kind; self.relatedProcessCount = relatedProcessCount; self.trend = trend
    }
}

struct MemoryProcessActionRecord: Codable, Identifiable, Sendable {
    let id: String
    let process: ProcessSample
    let createdAt: Date
    var receipt: ProcessExitReceipt?
    var observation: ProcessExitObservation?
    var diagnostic: DiagnosticResult?
    var diagnosticSnapshot: MemorySnapshot?
    var trend: [ProcessActionTrendPoint]?
    var effectComplete: Bool?
    var observationFailed: Bool?
}

/// Signals, effect reads and private record writes never run on the UI actor.
@MainActor
final class MemoryProcessActionsModel: ObservableObject {
    @Published var pending: MemoryProcessActionRequest?
    @Published private(set) var isBusy = false
    @Published private(set) var isObserving = false
    @Published private(set) var isSavingRecords = false
    @Published private(set) var records: [MemoryProcessActionRecord] = []
    @Published private(set) var message: String?
    @Published private(set) var recordError: String?
    let directoryURL: URL
    var didRequestExit: (() -> Void)?
    private let queue = DispatchQueue(label: "local.gpt-manager.process-actions", qos: .utility,
                                     autoreleaseFrequency: .workItem)
    private let control: ProcessControl
    private var observationID: String?
    private var pendingWrites = 0
    private let observationDelays: [Double]
    private let protectedPIDs = ProcessControl.observerAncestors()
    @Published private(set) var isOptimizing = false
    @Published private(set) var optimizationMessage: String?
    private var optimizationQueue: [MemoryProcessActionRequest] = []
    private var optimizationFirstReceipt: ProcessExitReceipt?
    private var optimizationCompleted = 0
    var hasPendingWork: Bool { isBusy || isObserving || isSavingRecords || isOptimizing }

    func optimizationCandidates(snapshot: MemorySnapshot?) -> [MemoryOptimizationCandidate] {
        guard let snapshot, Date().timeIntervalSince(snapshot.capturedAt) <= 30 else { return [] }
        return MemoryOptimizationPlanner.candidates(snapshot: snapshot, protectedPIDs: protectedPIDs)
            .filter { canRequest($0.process) }
    }

    func startOptimization(candidates: [MemoryOptimizationCandidate], selected: Set<String>, snapshot: MemorySnapshot?, history: [MemorySnapshot]) {
        guard !isBusy, !isObserving, !isOptimizing, pending == nil, let snapshot,
              Date().timeIntervalSince(snapshot.capturedAt) <= 30 else {
            optimizationMessage = "采样已过期或有其他操作，请刷新后重新扫描。"; return
        }
        let allowed = Set(optimizationCandidates(snapshot: snapshot).map(\.id))
        let targets = candidates.filter { selected.contains($0.id) }
        guard !targets.isEmpty, targets.allSatisfy({ allowed.contains($0.id) }) else {
            optimizationMessage = "目标已变化，请重新扫描。"; return
        }
        optimizationQueue = targets.map { .init(process: $0.process, kind: .request,
            relatedProcessCount: $0.relatedProcessCount, trend: Self.trend(for: $0.process, in: history)) }
        optimizationFirstReceipt = nil; optimizationCompleted = 0; isOptimizing = true
        optimizationMessage = "依次正常退出所选应用，每个对象观察完成后继续。"
        advanceOptimization()
    }

    func stopOptimization() {
        optimizationQueue = []
        optimizationMessage = "已停止后续退出；已经发送的请求仍会完成状态检查。"
        if !isBusy && !isObserving { isOptimizing = false }
    }

    private func advanceOptimization() {
        guard !optimizationQueue.isEmpty else { isOptimizing = false; return }
        pending = optimizationQueue.removeFirst()
        executePending()
    }


    init(directoryURL: URL, control: ProcessControl = ProcessControl(send: MemoryProcessActionsModel.sendDesktop), observationDelays: [Double] = [1, 5, 10]) {
        self.directoryURL = directoryURL; self.control = control
        self.observationDelays = observationDelays.count == 3 && observationDelays.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 10 }
            ? observationDelays.sorted() : [1, 5, 10]
        queue.async { [weak self] in
            let loaded = Self.load(directoryURL)
            DispatchQueue.main.async {
                guard let self else { return }
                for record in loaded where !self.records.contains(where: { $0.id == record.id }) { self.publish(record) }
            }
        }
    }

    nonisolated static func sendDesktop(_ process: ProcessSample, _ kind: ProcessExitKind) throws {
        guard process.pid > 1, process.pid <= Int(Int32.max) else { throw MemoryError.message("退出目标 PID 无效。") }
        if kind == .request && process.role == .appMain {
            guard let application = NSRunningApplication(processIdentifier: Int32(process.pid)) else {
                throw MemoryError.message("目标应用已退出或无法确认。")
            }
            try ProcessControl.validateNative(process)
            guard application.terminate() else { throw MemoryError.message("应用未接受正常退出请求；目标状态需要继续核实。") }
        } else { try ProcessControl.sendNative(process, kind) }
    }

    func prepare(_ process: ProcessSample, kind: ProcessExitKind, snapshot: MemorySnapshot?, history: [MemorySnapshot] = []) {
        guard !isBusy, !isObserving, !isOptimizing, pending == nil else { return }
        guard let snapshot, snapshot.processes.contains(where: { $0.key == process.key }), canRequest(process) else {
            message = "目标当前不可操作，请刷新并重新选择。"; return
        }
        if kind == .force && !canForce(process) { message = "先请求正常退出并等待状态检查。"; return }
        let count = snapshot.processes.filter { $0.rootKey == process.rootKey && $0.key != process.key }.count
        pending = .init(process: process, kind: kind, relatedProcessCount: count, trend: Self.trend(for: process, in: history))
    }

    func canRequest(_ process: ProcessSample) -> Bool {
        let status = latestExit(for: process)?.observation?.state
        return status != .exited && status != .replaced
            && process.pid > 1 && process.pid <= Int(Int32.max) && process.ownership == "process_tree"
            && !process.rootKey.isEmpty && !protectedPIDs.contains(process.pid)
    }

    func canForce(_ process: ProcessSample) -> Bool {
        guard !isBusy, !isObserving, !isOptimizing, let record = latestExit(for: process),
              let receipt = record.receipt, receipt.kind == .request,
              receipt.process.key == process.key, record.effectComplete == true,
              record.observationFailed != true, record.observation?.state == .running else { return false }
        return Date().timeIntervalSince(receipt.requestedAt) >= 5
    }
    private func latestExit(for process: ProcessSample) -> MemoryProcessActionRecord? {
        records.first { $0.process.key == process.key && $0.receipt != nil }
    }

    func confirm() {
        guard !isOptimizing else { return }
        executePending()
    }

    private func executePending() {
        guard !isBusy, !isObserving, let request = pending else { return }
        pending = nil; isBusy = true; message = nil
        let previous = latestExit(for: request.process)?.receipt
        queue.async { [weak self, control] in
            do {
                let receipt = try control.execute(process: request.process, kind: request.kind, previous: previous)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isBusy = false; self.isObserving = true; self.observationID = receipt.id
                    let record = MemoryProcessActionRecord(id: receipt.id, process: receipt.process,
                        createdAt: receipt.requestedAt, receipt: receipt, trend: request.trend)
                    self.publish(record)
                    if self.isOptimizing && self.optimizationFirstReceipt == nil { self.optimizationFirstReceipt = receipt }
                    self.message = "\(request.kind.label)请求已发送；正在核实目标和处理后占用。"
                    self.persist(record)
                    self.didRequestExit?()
                    for (index, delay) in self.observationDelays.enumerated() {
                        self.scheduleObservation(receipt, delay: delay, final: index == 2)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isBusy = false; self?.message = Self.describe(error)
                    if self?.isOptimizing == true {
                        self?.optimizationQueue = []; self?.isOptimizing = false
                        self?.optimizationMessage = "优化已停止：" + Self.describe(error)
                    }
                }
            }
        }
    }

    private func scheduleObservation(_ receipt: ProcessExitReceipt, delay: Double, final: Bool) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self, control] in
            let result = Result { try control.observe(receipt) }
            DispatchQueue.main.async {
                guard let self, self.observationID == receipt.id else { return }
                if final { self.isObserving = false; self.observationID = nil }
                switch result {
                case .success(let observation):
                    guard var record = self.records.first(where: { $0.id == receipt.id }) else { return }
                    record.observation = observation; record.observationFailed = false; record.effectComplete = final
                    self.publish(record); self.persist(record)
                    self.message = observation.state.label + (final ? "。效果记录已更新。" : "；继续观察到 10 秒。")
                    if final && self.isOptimizing {
                        if observation.state == .exited {
                            self.optimizationCompleted += 1
                            let delta = self.optimizationFirstReceipt.map {
                                ProcessExitObservation(receipt: $0, state: observation.state, after: observation.after).knownTotalChange
                            } ?? nil
                            self.optimizationMessage = "已确认退出 \(self.optimizationCompleted) 个应用。已知应用总占用变化：\(delta.map { String(format: "%+.1f MiB", Double($0) / 1048576) } ?? "指标不完整")。变化包含期间其他活动，并非保证释放量。"
                            self.advanceOptimization()
                        } else {
                            self.optimizationQueue = []; self.isOptimizing = false
                            self.optimizationMessage = "优化已停止：目标\(observation.state.label)，未继续退出其他应用。可在操作记录中查看结果。"
                        }
                    }
                case .failure(let error):
                    if var record = self.records.first(where: { $0.id == receipt.id }) {
                        record.observationFailed = true; record.effectComplete = final
                        self.publish(record); self.persist(record)
                    }
                    self.message = "退出请求已经发送；效果检查失败：\(Self.describe(error))"
                    if final && self.isOptimizing {
                        self.optimizationQueue = []; self.isOptimizing = false
                        self.optimizationMessage = "优化已停止：无法确认退出效果，未继续处理后续应用。"
                    }
                }
            }
        }
    }

    func recordDiagnostic(process: ProcessSample, snapshot: MemorySnapshot?, history: [MemorySnapshot] = [], result: DiagnosticResult) {
        let record = MemoryProcessActionRecord(id: UUID().uuidString, process: process, createdAt: Date(),
            diagnostic: result, diagnosticSnapshot: snapshot, trend: Self.trend(for: process, in: history))
        publish(record); persist(record)
    }

    private static func trend(for target: ProcessSample, in history: [MemorySnapshot]) -> [ProcessActionTrendPoint] {
        history.suffix(360).map { snapshot in
            let process = snapshot.processes.first {
                $0.pid == target.pid && ProcessControl.birth($0) == ProcessControl.birth(target) && $0.executable == target.executable
            }
            return .init(capturedAt: snapshot.capturedAt, footprintBytes: process?.footprintBytes)
        }
    }

    private func publish(_ record: MemoryProcessActionRecord) {
        records.removeAll { $0.id == record.id }; records.append(record)
        records.sort { $0.createdAt > $1.createdAt }; records = Array(records.prefix(12))
    }

    private func persist(_ record: MemoryProcessActionRecord) {
        let directory = directoryURL
        pendingWrites += 1; isSavingRecords = true
        queue.async { [weak self] in
            let result = Result { try Self.save(record, directory: directory) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingWrites -= 1; self.isSavingRecords = self.pendingWrites > 0
                if case .failure(let error) = result { self.recordError = "操作状态保持不变；本地记录保存失败：\(Self.describe(error))" }
                else { self.recordError = nil }
            }
        }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        (error as? MemoryError)?.description ?? error.localizedDescription
    }

    nonisolated private static func privateDirectory(_ directory: URL, create: Bool) throws -> Bool {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw MemoryError.message("无法读取操作记录目录。") }
            if !create { return false }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw MemoryError.message("无法创建操作记录目录。") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw MemoryError.message("操作记录需要本机私有目录（0700）。")
        }
        return true
    }

    nonisolated private static func save(_ record: MemoryProcessActionRecord, directory: URL) throws {
        guard UUID(uuidString: record.id) != nil else { throw MemoryError.message("操作记录标识无效。") }
        _ = try privateDirectory(directory, create: true)
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw MemoryError.message("无法打开私有操作目录。") }
        defer { close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o077 == 0 else { throw MemoryError.message("操作目录权限已变化。") }
        let expectedPath = try physicalPath(directory.path)
        let bytes = try MemoryJSON.encoder().encode(record)
        guard bytes.count <= 512 * 1024 else { throw MemoryError.message("操作记录超过 512 KiB。") }
        let destination = record.id + ".json"
        let temporary = ".\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MemoryError.message("无法创建私有操作记录。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(directoryFD, temporary, 0) }
        try handle.write(contentsOf: bytes); try handle.synchronize()
        var openedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(directoryFD, F_GETPATH, &openedPath) == 0,
              try physicalPath(String(cString: openedPath)) == expectedPath,
              try physicalPath(directory.path) == expectedPath else { throw MemoryError.message("操作记录目录在保存期间发生变化。") }
        var existing = stat()
        if fstatat(directoryFD, destination, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1,
                  existing.st_uid == getuid(), existing.st_mode & 0o077 == 0 else { throw MemoryError.message("已有记录不是私有普通文件。") }
        } else if errno != ENOENT { throw MemoryError.message("无法核实已有操作记录。") }
        guard renameat(directoryFD, temporary, directoryFD, destination) == 0 else { throw MemoryError.message("无法保存操作记录。") }
        _ = fsync(directoryFD)
    }

    nonisolated private static func physicalPath(_ path: String) throws -> String {
        guard let resolved = path.withCString({ realpath($0, nil) }) else {
            throw MemoryError.message("无法核实操作记录目录的实际位置。")
        }
        defer { free(resolved) }; return String(cString: resolved)
    }

    nonisolated private static func load(_ directory: URL) -> [MemoryProcessActionRecord] {
        guard (try? privateDirectory(directory, create: false)) == true,
              let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        var candidates: [(URL, Date)] = [], visited = 0
        for case let url as URL in enumerator {
            visited += 1; if visited > 256 { break }
            guard url.pathExtension == "json" else { continue }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 512 * 1024 else { continue }
            candidates.append((url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        return candidates.sorted { $0.1 > $1.1 }.prefix(12).compactMap { url, _ in
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 512 * 1024,
                  let data = try? handle.read(upToCount: 512 * 1024 + 1), data.count <= 512 * 1024,
                  let record = try? MemoryJSON.decoder().decode(MemoryProcessActionRecord.self, from: data),
                  record.id + ".json" == url.lastPathComponent else { return nil }; return record
        }.sorted { $0.createdAt > $1.createdAt }
    }
}
