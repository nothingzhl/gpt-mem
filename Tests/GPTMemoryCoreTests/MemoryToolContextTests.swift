import XCTest
import Foundation
import Darwin
import CNative
@testable import GPTMemoryCore

final class MemoryToolContextTests: XCTestCase {
    private func process(_ pid: Int, role: ProcessRole = .mcpApp, bytes: UInt64 = 40 * 1024 * 1024) -> ProcessSample {
        .init(bootID: "fixture", pid: pid, parentPID: 5000, startTimeTicks: UInt64(pid), startedAt: Date(),
              executable: "/runtime/node", role: role, rootKey: "fixture:5000:1", footprintBytes: bytes)
    }
    private func candidates(_ processes: [ProcessSample]) -> [MemoryOptimizationCandidate] {
        let root = ProcessSample(bootID: "fixture", pid: 5000, parentPID: 1, startTimeTicks: 1, startedAt: Date(),
            executable: "/Applications/Codex.app/Contents/MacOS/Codex", role: .appMain, rootKey: "fixture:5000:1", footprintBytes: 0)
        return MemoryOptimizationPlanner.candidates(snapshot: .init(processes: [root] + processes), protectedPIDs: [], minimumBytes: 0)
    }

    func testProjectEvidenceDoesNotGuessFromPluginOrSessionArguments() {
        let tool = process(5001, role: .toolWorker)
        let explicit = MemoryToolContextReader.project(process: tool,
            arguments: ["node", "/tmp/kernel.js", "--working-dir", "/projects/a/sub/.."], directory: "/tmp", repository: { _ in nil })
        XCTAssertEqual(explicit.path, "/projects/a")
        XCTAssertTrue(explicit.evidence.contains("启动参数"))
        XCTAssertEqual(MemoryToolContextReader.project(process: tool, arguments: ["node", "kernel.js", "--working-dir", "/projects/a/sub"],
            directory: "/tmp", repository: { _ in "/projects/a" }).path, "/projects/a")
        let service = MemoryToolContextReader.project(process: process(5002),
            arguments: ["node", "server.mjs", "--working-dir", "/projects/fake", "--session-id", "opaque"],
            directory: "/Users/test/.codex/plugins/cache/server", repository: { _ in "/projects/incorrect" })
        XCTAssertNil(service.path)
        XCTAssertTrue(service.evidence.contains("安装目录"))
        XCTAssertNil(MemoryToolContextReader.project(process: process(5002), arguments: ["node", "server.mjs"],
            directory: "/Users/test/.codex/code-review-plugin", repository: { _ in "/Users/test/.codex/code-review-plugin" }).path)
        let repository = MemoryToolContextReader.project(process: process(5003), arguments: ["node", "tool.js"],
            directory: "/projects/a/sub", repository: { _ in "/projects/a" })
        XCTAssertEqual(repository.path, "/projects/a")
        XCTAssertTrue(repository.evidence.contains("Git 仓库"))
        XCTAssertNil(MemoryToolContextReader.project(process: tool,
            arguments: ["node", "kernel.js", "--working-dir", "/projects/a", "--working-dir", "/projects/b"],
            directory: nil, repository: { _ in nil }).path)
    }

    func testIndexedWorkspaceMatchesBoundaryAndNearestProjectWithoutGuessingSessions() {
        let tool = process(5001, role: .repl)
        let projects = ["/workspaces/multi", "/workspaces/multi/child"]
        let matched = MemoryToolContextReader.project(process: tool, arguments: ["node_repl", "--session-id", "opaque"],
            directory: "/workspaces/multi/child/src", knownProjects: projects, repository: { _ in nil })
        XCTAssertEqual(matched.path, "/workspaces/multi/child")
        XCTAssertTrue(matched.evidence.contains("不是具体会话关联"))
        XCTAssertNil(MemoryToolContextReader.project(process: tool, arguments: [], directory: "/workspaces/multi-other",
            knownProjects: projects, repository: { _ in nil }).path)
        XCTAssertNil(MemoryToolContextReader.project(process: tool, arguments: [], directory: "/Users/test/.codex/plugins/mcp",
            knownProjects: ["/Users/test/.codex/plugins/mcp"], repository: { _ in nil }).path)
    }

    func testRepositoryDiscoveryHandlesNestedDirectoriesAndWorktreeGitFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("src/nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("gitdir: fixture".utf8).write(to: root.appendingPathComponent(".git"))
        XCTAssertEqual(MemoryToolContextReader.repositoryRoot(child.path), MemoryToolContextReader.normalized(root.path))
        XCTAssertNil(MemoryToolContextReader.repositoryRoot("/Applications/Example.app/Contents/Resources"))
    }

    func testGroupingRequiresExactConfigurationAndKnownDirectory() {
        let tools = candidates([process(5001), process(5002), process(5003), process(5004, role: .repl), process(5005)])
        let shared = MemoryToolRuntimeContext(arguments: ["node", "./server.mjs"], workingDirectory: "/plugins/a")
        let other = MemoryToolRuntimeContext(arguments: ["node", "./server.mjs"], workingDirectory: "/plugins/b")
        let missing = MemoryToolRuntimeContext(arguments: ["node", "./server.mjs"], workingDirectory: nil)
        let contexts = [tools[0].id: shared, tools[1].id: shared, tools[2].id: other, tools[3].id: shared, tools[4].id: missing]
        let groups = MemoryToolGrouping.groups(candidates: tools, contexts: contexts)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.filter(\.isRepeated).count, 1)
        XCTAssertEqual(groups.first?.candidates.count, 2)
        XCTAssertEqual(groups.first?.footprintBytes, 80 * 1024 * 1024)
        XCTAssertEqual(groups.filter { !$0.isComparable }.count, 1)
        let project = MemoryToolGrouping.projects(groups: groups)
        XCTAssertEqual(project.count, 1)
        XCTAssertNil(project.first?.path)
        XCTAssertEqual(project.first?.instanceCount, 5)
        XCTAssertEqual(project.first?.footprintBytes, 200 * 1024 * 1024)
    }

    func testMissingContextsNeverBecomeRepeatedAndProjectsStaySeparate() {
        let tools = candidates([process(5001), process(5002)])
        XCTAssertTrue(MemoryToolGrouping.groups(candidates: tools, contexts: [:]).allSatisfy { !$0.isRepeated })
        let contextA = MemoryToolRuntimeContext(arguments: ["node", "tool.js"], workingDirectory: "/projects/a", projectPath: "/projects/a")
        let contextB = MemoryToolRuntimeContext(arguments: ["node", "tool.js"], workingDirectory: "/projects/b", projectPath: "/projects/b")
        let groups = MemoryToolGrouping.groups(candidates: tools, contexts: [tools[0].id: contextA, tools[1].id: contextB])
        XCTAssertEqual(MemoryToolGrouping.projects(groups: groups).map(\.path), ["/projects/a", "/projects/b"])
        var reuse = tools[0].process; reuse.startTimeTicks += 1
        let changed = candidates([reuse, tools[1].process])
        XCTAssertEqual(MemoryToolGrouping.groups(candidates: changed, contexts: [tools[0].id: contextA]).filter { !$0.isComparable }.count, 2)
    }

    func testNativeWorkingDirectoryChecksIdentityAndReadsNoEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        child.currentDirectoryURL = directory; child.environment = ["PWD": "/fake/environment/path"]
        try child.run(); defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        var info = gpt_process_info()
        XCTAssertEqual(gpt_read_process(child.processIdentifier, &info), 0)
        let path = withUnsafePointer(to: &info.executable) { $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) } }
        var target = process(Int(child.processIdentifier)); target.startTimeTicks = info.start_ticks; target.executable = path
        let context = MemoryToolContextReader.read(target)
        XCTAssertEqual(context.workingDirectory, MemoryToolContextReader.normalized(directory.path))
        XCTAssertTrue(context.command?.contains("sleep") == true)
        XCTAssertFalse(context.command?.contains("/fake/environment/path") == true)
        target.startTimeTicks += 1
        XCTAssertNil(MemoryToolContextReader.read(target).workingDirectory)
    }
}
