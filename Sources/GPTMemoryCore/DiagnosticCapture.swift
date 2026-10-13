import Foundation
import Darwin
import CNative

public struct DiagnosticResult: Codable {
    public var pid: Int
    public var outputPath: String
    public var exitCode: Int32
    public var timedOut: Bool
    public var partial: Bool
}

public enum DiagnosticCapture {
    /// Summaries contain memory regions, never object contents or a heap dump.
    public static func capture(process: ProcessSample, output: URL, timeout: TimeInterval = 10) throws -> DiagnosticResult {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else {
            throw MemoryError.message("诊断超时必须在 0–60 秒内。")
        }
        var live = gpt_process_info()
        guard gpt_read_process(Int32(process.pid), &live) == 0, live.start_ticks == process.startTimeTicks else {
            throw MemoryError.message("目标进程已退出或 PID 已复用，已取消诊断。")
        }
        guard !process.rootKey.isEmpty, process.ownership != "observer" else {
            throw MemoryError.message("仅支持已确认属于 ChatGPT/Codex 的目标进程。")
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Do not clobber a user's file, and refuse symlinks.
        let fd = output.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw MemoryError.message("无法创建诊断文件（不能覆盖已有文件）：\(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        task.arguments = ["-summary", String(process.pid)]
        task.standardOutput = handle; task.standardError = handle
        do { try task.run() } catch {
            try? FileManager.default.removeItem(at: output)
            throw MemoryError.message("无法启动 vmmap：\(error.localizedDescription)")
        }
        let start = gpt_monotonic_seconds()
        var timedOut = false
        var sizeLimited = false
        while task.isRunning {
            let fileBytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            if fileBytes > 512 * 1024 { sizeLimited = true; break }
            if gpt_monotonic_seconds() - start >= timeout { timedOut = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            task.terminate() // Only our vmmap helper, never the application target.
            let stopAt = gpt_monotonic_seconds() + 1
            while task.isRunning && gpt_monotonic_seconds() < stopAt { Thread.sleep(forTimeInterval: 0.05) }
            if task.isRunning { _ = Darwin.kill(task.processIdentifier, SIGKILL) }
        }
        task.waitUntilExit()
        try handle.synchronize()
        let data = try Data(contentsOf: output, options: .mappedIfSafe)
        sizeLimited = sizeLimited || data.count > 512 * 1024
        let limited = data.prefix(512 * 1024)
        let text = String(decoding: limited, as: UTF8.self)
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        try Data(text.utf8).write(to: output)
        let partial = timedOut || sizeLimited || task.terminationStatus != 0 ||
            text.contains("Can't examine") || text.contains("incomplete") || text.contains("Unable to")
        return DiagnosticResult(pid: process.pid, outputPath: output.path, exitCode: task.terminationStatus,
            timedOut: timedOut, partial: partial)
    }
}
