import Foundation
import Darwin
import CNative

/// Transient UI evidence. Deliberately not Codable or attached to persisted samples.
public struct MemoryToolRuntimeContext: Sendable {
    public let arguments: [String]?
    public let commandIssue: String?
    public let workingDirectory: String?
    public let directoryIssue: String?
    public let projectPath: String?
    public let projectEvidence: String
    public let capturedAt: Date
    public var command: String? { arguments.map(ProcessCommandReader.format) }

    public init(arguments: [String]?, commandIssue: String? = nil, workingDirectory: String?,
                directoryIssue: String? = nil, projectPath: String? = nil,
                projectEvidence: String = "无法确认项目归属", capturedAt: Date = Date()) {
        self.arguments = arguments; self.commandIssue = commandIssue; self.workingDirectory = workingDirectory
        self.directoryIssue = directoryIssue; self.projectPath = projectPath
        self.projectEvidence = projectEvidence; self.capturedAt = capturedAt
    }
}

public enum MemoryToolContextReader {
    public static func read(_ process: ProcessSample) -> MemoryToolRuntimeContext {
        let arguments: [String]?, commandIssue: String?
        do { arguments = try ProcessCommandReader.arguments(process); commandIssue = nil }
        catch { arguments = nil; commandIssue = (error as? MemoryError)?.description ?? error.localizedDescription }
        var directory: String?, directoryIssue: String?
        if process.pid > 1 && process.pid <= Int(Int32.max), process.ownership == "process_tree", !process.rootKey.isEmpty {
            var buffer = [CChar](repeating: 0, count: 4096)
            let count = gpt_read_working_directory(Int32(process.pid), ProcessControl.birth(process), process.executable, &buffer, buffer.count)
            if count > 0 { directory = String(cString: buffer) }
            else { directoryIssue = "工作目录未知：进程已变化、目录不可读或系统限制。" }
        } else { directoryIssue = "工作目录未知：进程归属未确认。" }
        let attribution = project(process: process, arguments: arguments, directory: directory)
        return .init(arguments: arguments, commandIssue: commandIssue, workingDirectory: directory,
                     directoryIssue: directoryIssue, projectPath: attribution.path, projectEvidence: attribution.evidence)
    }

    /// Explicit worker working directory or nearest Git root; service installation paths are not projects.
    public static func project(process: ProcessSample, arguments: [String]?, directory: String?, knownProjects: [String] = [],
                               repository: (String) -> String? = repositoryRoot) -> (path: String?, evidence: String) {
        func indexedProject(_ directory: String) -> String? {
            let canonical = normalized(directory)
            return knownProjects.filter { canonical == $0 || canonical.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        }
        if process.role == .toolWorker, let arguments {
            let scripts = arguments.filter { ["kernel.js", "trusted-worker.js"].contains(URL(fileURLWithPath: $0).lastPathComponent) }
            if !scripts.isEmpty {
                var paths: [String] = []
                for (index, value) in arguments.enumerated() {
                    if value == "--working-dir", arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") {
                        paths.append(arguments[index + 1])
                    } else if value.hasPrefix("--working-dir=/") { paths.append(String(value.dropFirst("--working-dir=".count))) }
                }
                if Set(paths).count == 1, let path = paths.first, !isToolRuntime(path) {
                    if let known = indexedProject(path) {
                        return (known, "工具工作目录匹配已有会话索引的项目路径；不是具体会话关联")
                    }
                    return (normalized(repository(path) ?? path), "工具启动参数 --working-dir（优先使用所在 Git 仓库根目录）；不能证明当前任务或会话")
                }
            }
        }
        if let directory, directory.hasPrefix("/"), !isToolRuntime(directory) {
            if let known = indexedProject(directory) {
                return (known, "实际工作目录匹配已有会话索引的项目路径；不是具体会话关联")
            }
            if let root = repository(directory) { return (normalized(root), "工作目录所在 Git 仓库；不能证明当前任务或会话") }
        }
        return (nil, directory.map { isToolRuntime($0) ? "工具安装目录，无法据此关联工作项目" : "工作目录没有可确认的 Git 项目" } ?? "工作目录不可读，项目归属未知")
    }

    public static func normalized(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resolved = standardized.withCString({ realpath($0, nil) }) else { return standardized }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    public static func isToolRuntime(_ path: String) -> Bool {
        if path.contains(".app/Contents/") || path.hasSuffix(".app/Contents") { return true }
        let markers = ["/.codex/plugins", "/.codex/skills", "/.codex/code-review-plugin", "/.agents/skills"]
        return markers.contains { path.hasSuffix($0) || path.contains($0 + "/") }
    }
    public static func repositoryRoot(_ directory: String) -> String? {
        var current = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
        guard !isToolRuntime(current.path) else { return nil }
        for _ in 0..<32 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) { return normalized(current.path) }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }
}

public struct MemoryToolInstanceGroup: Identifiable, Sendable {
    public let candidates: [MemoryOptimizationCandidate]
    public let projectPath: String?
    public let isComparable: Bool
    public var id: String { candidates[0].id }
    public var isRepeated: Bool { isComparable && candidates.count > 1 }
    public var footprintBytes: UInt64? {
        var total: UInt64 = 0
        for candidate in candidates {
            let sum = total.addingReportingOverflow(candidate.process.footprintBytes)
            guard !sum.overflow else { return nil }; total = sum.partialValue
        }
        return total
    }
}

public struct MemoryToolProjectGroup: Identifiable, Sendable {
    public let path: String?
    public let groups: [MemoryToolInstanceGroup]
    public var id: String { path ?? "unknown" }
    public var instanceCount: Int { groups.reduce(0) { $0 + $1.candidates.count } }
    public var footprintBytes: UInt64? {
        var total: UInt64 = 0
        for group in groups {
            guard let value = group.footprintBytes else { return nil }
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }; total = sum.partialValue
        }
        return total
    }
}

public enum MemoryToolGrouping {
    private struct Key: Hashable {
        let root: String
        let role: ProcessRole
        let executable: String
        let arguments: [String]
        let directory: String
        let project: String?
        let uncomparableInstance: String?
    }
    public static func groups(candidates: [MemoryOptimizationCandidate], contexts: [String: MemoryToolRuntimeContext]) -> [MemoryToolInstanceGroup] {
        var buckets: [Key: [MemoryOptimizationCandidate]] = [:]
        for candidate in candidates {
            let context = contexts[candidate.id]
            let comparable = context?.arguments?.isEmpty == false && context?.workingDirectory?.hasPrefix("/") == true
            let key = Key(root: candidate.process.rootKey, role: candidate.process.role, executable: candidate.process.executable,
                          arguments: context?.arguments ?? [], directory: context?.workingDirectory ?? "",
                          project: context?.projectPath, uncomparableInstance: comparable ? nil : candidate.id)
            buckets[key, default: []].append(candidate)
        }
        return buckets.map { key, values in
            .init(candidates: values.sorted { $0.process.pid < $1.process.pid }, projectPath: key.project, isComparable: key.uncomparableInstance == nil)
        }.sorted {
            let a = $0.footprintBytes ?? 0, b = $1.footprintBytes ?? 0
            return a == b ? $0.id < $1.id : a > b
        }
    }
    public static func projects(groups: [MemoryToolInstanceGroup]) -> [MemoryToolProjectGroup] {
        let buckets = Dictionary(grouping: groups, by: { $0.projectPath })
        return buckets.map { .init(path: $0.key, groups: $0.value) }.sorted {
            if $0.path == nil { return false }; if $1.path == nil { return true }
            return $0.path! < $1.path!
        }
    }
}
