import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers
import Darwin
import GPTMemoryCore
import GPTAnalysisKit

private struct DesktopUpdate {
    var snapshot: MemorySnapshot?
    var history: [MemorySnapshot]
    var analysis: MemoryAnalysis?
    var monitoring: Bool
    var mode: String
    var error: String?
    var historyError: String?
    var notice: String?
}

@MainActor
final class DesktopModel: ObservableObject {
    @Published var snapshot: MemorySnapshot?
    @Published var history: [MemorySnapshot] = []
    @Published var analysis: MemoryAnalysis?
    @Published var isMonitoring = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var historyErrorMessage: String?
    @Published var noticeMessage: String?
    @Published var interval: Double = 5
    @Published var windowSeconds: TimeInterval = 1800
    @Published var modeLabel = "准备就绪"
    @Published var isSessionWorkspaceActive = false
    @Published var lastExportURL: URL?
    @Published var lastDiagnosticURL: URL?
    let databaseURL: URL
    let aiModel: DesktopAIModel
    let sessionModel = SessionDesktopModel()
    private var isPerformingFileOperation = false

    var displayedErrorMessage: String? {
        let messages = [errorMessage, historyErrorMessage].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private lazy var service = DesktopSamplingService(databaseURL: databaseURL) { [weak self] update in
        DispatchQueue.main.async {
            guard let self else { return }
            if let snapshot = update.snapshot { self.snapshot = snapshot }
            self.history = update.history
            self.analysis = update.analysis
            self.aiModel.updateWindow(start: update.analysis?.start, end: update.analysis?.end,
                                      selectionSeconds: self.windowSeconds)
            self.isMonitoring = update.monitoring
            self.modeLabel = update.mode
            self.isBusy = self.isPerformingFileOperation
            if let error = update.error { self.errorMessage = error }
            self.historyErrorMessage = update.historyError
            if let notice = update.notice { self.noticeMessage = notice }
        }
    }

    init() {
        let arguments = CommandLine.arguments
        let override: String?
        if let index = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(index + 1) {
            override = arguments[index + 1]
        } else { override = ProcessInfo.processInfo.environment["GPT_MEM_HOME"] }
        let directory = override.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/gpt-mem")
        databaseURL = directory.appendingPathComponent("history.sqlite3")
        aiModel = DesktopAIModel(configurationStore: AIConfigurationStore(url: directory.appendingPathComponent("ai-services.json")))
        let saved = UserDefaults.standard.double(forKey: "samplingInterval")
        if [1.0, 2.0, 5.0, 10.0].contains(saved) { interval = saved }
    }

    func startMonitoring() {
        isBusy = true
        service.start(interval: interval, window: windowSeconds)
    }
    func stopMonitoring() { service.stop() }
    func refresh() { isBusy = true; service.refresh(window: windowSeconds) }
    func refreshCurrentPage() {
        if isSessionWorkspaceActive {
            guard !sessionModel.isLoading else { return }
            sessionModel.refresh()
        } else {
            guard !isBusy else { return }
            refresh()
        }
    }
    func setWindow(seconds: TimeInterval) {
        guard seconds >= 60 && seconds <= 7200 else { return }
        windowSeconds = seconds
        aiModel.updateWindow(start: analysis?.start, end: analysis?.end, selectionSeconds: seconds)
        refresh()
    }
    func setInterval(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 1, seconds <= 60 else { return }
        interval = seconds
        UserDefaults.standard.set(seconds, forKey: "samplingInterval")
        service.setInterval(seconds)
    }
    func dismissMessage() { errorMessage = nil; historyErrorMessage = nil; noticeMessage = nil }
    func prepareMemoryAIAnalysis() {
        guard let analysis, analysis.sampleCount >= 2 else { return }
        let module = MemoryAIAnalysisModule(snapshots: history, analysis: analysis, context: aiModel.activityContext)
        aiModel.prepare(module: module, subjectLabels: module.subjectLabels, windowSelectionSeconds: windowSeconds)
    }
    func openDataDirectory() {
        let directory = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch { errorMessage = error.localizedDescription }
    }

    func exportReport() {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "导出内存报告"
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "GPT-内存报告.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isPerformingFileOperation = true; isBusy = true
        service.exportReport(to: url, window: windowSeconds) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPerformingFileOperation = false; self.isBusy = false
                switch result {
                case .success:
                    self.lastExportURL = url; self.noticeMessage = "报告已保存，可离线打开。"
                case .failure(let error): self.errorMessage = String(describing: error)
                }
            }
        }
    }

    func diagnose(process: ProcessSample) {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "保存进程内存摘要"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "GPT-PID-\(process.pid)-\(Int(Date().timeIntervalSince1970)).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isPerformingFileOperation = true; isBusy = true
        service.diagnose(process: process, output: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPerformingFileOperation = false; self.isBusy = false
                switch result {
                case .success(let diagnostic):
                    self.lastDiagnosticURL = url
                    self.noticeMessage = diagnostic.partial ? "摘要已保存；部分内存区域未能解析，结果不完整。" : "进程内存摘要已保存。"
                case .failure(let error): self.errorMessage = String(describing: error)
                }
            }
        }
    }
}

/// All native collector, SQLite and lock operations are serialized off the UI thread.
private final class DesktopSamplingService {
    private let queue = DispatchQueue(label: "local.gpt-manager.sampling", qos: .utility)
    private let operationQueue = DispatchQueue(label: "local.gpt-manager.files", qos: .utility)
    private let historyCacheLimit = 32 * 1_024 * 1_024
    private let databaseURL: URL
    private let handler: (DesktopUpdate) -> Void
    private let sample: () throws -> MemorySnapshot
    private let diagnosticCapture: (ProcessSample, URL) throws -> DiagnosticResult
    private var writer: MemoryStore?
    private var reader: MemoryStore?
    private var lock: MonitorLock?
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 5
    private var window: TimeInterval = 1800
    private var lastMaintenance = Date.distantPast
    private var lastSnapshot: MemorySnapshot?
    private var historyState = MemoryHistoryState()
    private var mode = "已暂停"

    init(databaseURL: URL, sample: @escaping () throws -> MemorySnapshot = NativeCollector().sample,
         diagnosticCapture: @escaping (ProcessSample, URL) throws -> DiagnosticResult = {
             try DiagnosticCapture.capture(process: $0, output: $1)
         }, handler: @escaping (DesktopUpdate) -> Void) {
        self.databaseURL = databaseURL; self.handler = handler
        self.sample = sample; self.diagnosticCapture = diagnosticCapture
    }

    func start(interval: TimeInterval, window: TimeInterval) {
        queue.async {
            self.interval = interval; self.window = window
            if self.timer != nil, self.writer != nil { self.tick(); return }
            self.timer?.cancel(); self.timer = nil
            do {
                self.lock = try MonitorLock(url: self.databaseURL.deletingLastPathComponent().appendingPathComponent("monitor.lock"))
                self.writer = try MemoryStore(url: self.databaseURL, decodedCacheByteLimit: self.historyCacheLimit)
                self.reader = nil; self.mode = "正在采集"
            } catch MemoryError.monitorBusy {
                self.writer = nil; self.lock = nil
                if FileManager.default.fileExists(atPath: self.databaseURL.path),
                   let reader = try? MemoryStore(url: self.databaseURL, readOnly: true, decodedCacheByteLimit: self.historyCacheLimit) {
                    self.reader = reader; self.mode = "外部采集 · 只读"
                    self.handler(.init(snapshot: nil, history: self.historyState.snapshots, analysis: self.historyState.analysis, monitoring: false,
                        mode: self.mode, historyError: self.historyState.loadError,
                        notice: "已有采集器在记录，这个窗口以只读方式查看。"))
                } else {
                    self.reader = nil
                    self.mode = "无法开始采集"
                    self.handler(.init(snapshot: nil, history: self.historyState.snapshots, analysis: self.historyState.analysis, monitoring: false, mode: self.mode,
                        error: "已有采集器持有锁，但历史数据库暂不可读，请稍后重试。", historyError: self.historyState.loadError))
                    return
                }
            } catch {
                self.writer = nil; self.lock = nil; self.reader = nil
                self.mode = "无法开始采集"
                self.handler(.init(snapshot: self.lastSnapshot, history: self.historyState.snapshots, analysis: self.historyState.analysis, monitoring: false,
                    mode: self.mode, error: String(describing: error), historyError: self.historyState.loadError))
                return
            }
            self.tick()
            self.scheduleTimer()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.writer = nil; self.lock = nil; self.reader = nil
            self.mode = "已暂停"
            self.publish(snapshot: self.lastSnapshot)
        }
    }
    func setInterval(_ seconds: TimeInterval) {
        queue.async {
            self.interval = seconds
            if self.timer != nil { self.timer?.cancel(); self.timer = nil; self.scheduleTimer() }
        }
    }
    func refresh(window: TimeInterval) {
        queue.async {
            self.window = window
            if self.timer != nil { self.tick() }
            else {
                do { self.lastSnapshot = try self.sample(); self.publish(snapshot: self.lastSnapshot) }
                catch { self.publish(snapshot: self.lastSnapshot, error: String(describing: error)) }
            }
        }
    }
    private func scheduleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }
    private func tick() {
        do {
            var notice: String?
            // When an external CLI writer exits, the desktop can take over the same
            // lock instead of showing a stale "external collection" state forever.
            if writer == nil, reader != nil {
                do {
                    let recovered = try MonitorLock(url: databaseURL.deletingLastPathComponent().appendingPathComponent("monitor.lock"))
                    let store = try MemoryStore(url: databaseURL, decodedCacheByteLimit: historyCacheLimit)
                    lock = recovered; writer = store; reader = nil; mode = "正在采集"
                    notice = "外部采集已结束，桌面已接管记录。"
                } catch MemoryError.monitorBusy {
                    // The external writer is still active; continue reading.
                } catch {
                    timer?.cancel(); timer = nil; reader = nil
                    mode = "无法开始采集"
                    throw error
                }
            }
            if let writer {
                let snapshot = try sample()
                try writer.save(snapshot)
                lastSnapshot = snapshot
                if snapshot.capturedAt.timeIntervalSince(lastMaintenance) >= 60 {
                    try writer.maintenance(now: snapshot.capturedAt); lastMaintenance = snapshot.capturedAt
                }
            } else if let reader { lastSnapshot = try reader.latest() }
            publish(snapshot: lastSnapshot, notice: notice)
        } catch { publish(snapshot: lastSnapshot, error: String(describing: error)) }
    }
    private func publish(snapshot: MemorySnapshot?, error: String? = nil, notice: String? = nil) {
        historyState.refresh {
            let store: MemoryStore?
            if let writer { store = writer }
            else if let reader { store = reader }
            else if FileManager.default.fileExists(atPath: databaseURL.path) { store = try MemoryStore(url: databaseURL, readOnly: true) }
            else { store = nil }
            return try store?.load(since: Date().addingTimeInterval(-window)) ?? []
        }
        handler(.init(snapshot: snapshot, history: historyState.snapshots, analysis: historyState.analysis,
            monitoring: writer != nil, mode: mode, error: error, historyError: historyState.loadError, notice: notice))
    }

    func diagnose(process: ProcessSample, output: URL, completion: @escaping (Result<DiagnosticResult, Error>) -> Void) {
        operationQueue.async {
            do { completion(.success(try self.diagnosticCapture(process, output))) }
            catch { completion(.failure(error)) }
        }
    }
    func exportReport(to output: URL, window: TimeInterval, completion: @escaping (Result<Void, Error>) -> Void) {
        operationQueue.async {
            do {
                let candidates = [Bundle.main.resourceURL?.appendingPathComponent("gpt-mem"),
                    URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("gpt-mem")].compactMap { $0 }
                guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                    throw MemoryError.message("未找到报告导出组件。请使用 package-app.sh 打包后的应用。")
                }
                let task = Process()
                task.executableURL = binary
                task.arguments = ["report", "--since", String(Int(window)) + "s", "--db", self.databaseURL.path, "--output", output.path]
                // The CLI's human summary is unused. Avoid a pipe that can fill
                // while this queue waits for the export child to exit.
                var temporaryPath = Array(FileManager.default.temporaryDirectory.appendingPathComponent("gpt-manager-export-XXXXXX").path.utf8CString)
                let descriptor = mkstemp(&temporaryPath)
                guard descriptor >= 0 else { throw MemoryError.message("无法创建报告错误记录：\(String(cString: strerror(errno)))") }
                let errorURL = URL(fileURLWithPath: String(cString: temporaryPath))
                let errorFile = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? errorFile.close(); try? FileManager.default.removeItem(at: errorURL) }
                task.standardOutput = FileHandle.nullDevice; task.standardError = errorFile
                try task.run()
                let deadline = ProcessInfo.processInfo.systemUptime + 30
                while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if task.isRunning {
                    task.terminate(); Thread.sleep(forTimeInterval: 0.2)
                    if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
                    task.waitUntilExit()
                    throw MemoryError.message("报告导出超时，请缩短历史范围后重试。")
                }
                task.waitUntilExit()
                try errorFile.seek(toOffset: 0)
                let data = try errorFile.read(upToCount: 4096) ?? Data()
                guard task.terminationStatus == 0 else {
                    throw MemoryError.message(String(decoding: data.prefix(4096), as: UTF8.self))
                }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }
}
