import Foundation

public enum ProcessRole: String, Codable, CaseIterable, Sendable {
    case appMain = "app_main"
    case renderer, gpu
    case appService = "app_service"
    case codexBackend = "codex_backend"
    case mcpApp = "mcp_app"
    case mcpCodeReview = "mcp_code_review"
    case mcpMySQL = "mcp_mysql"
    case mcpCUA = "mcp_cua"
    case repl
    case toolWorker = "tool_worker"
    case unknownNode = "unknown_node"
    case other

    public var label: String {
        switch self {
        case .appMain: return "应用主进程"
        case .renderer: return "页面渲染"
        case .gpu: return "GPU/图形"
        case .appService: return "应用服务"
        case .codexBackend: return "Codex 后台"
        case .mcpApp: return "MCP 应用工具"
        case .mcpCodeReview: return "MCP 代码审查"
        case .mcpMySQL: return "MCP MySQL"
        case .mcpCUA: return "MCP 电脑操作"
        case .repl: return "REPL"
        case .toolWorker: return "工具执行器"
        case .unknownNode: return "未识别 Node"
        case .other: return "其他子进程"
        }
    }
}

public struct ProcessSample: Codable, Equatable, Identifiable, Sendable {
    public var bootID: String
    public var pid: Int
    public var parentPID: Int
    public var startTimeTicks: UInt64
    public var absoluteStartTimeMicroseconds: UInt64?
    public var startedAt: Date
    public var executable: String
    public var role: ProcessRole
    public var roleHint: String
    public var rootKey: String
    public var footprintBytes: UInt64
    public var rssBytes: UInt64
    public var peakFootprintBytes: UInt64
    public var cpuPercent: Double?
    public var ownership: String

    public var key: String {
        // Native birth timestamps are absolute epoch microseconds, stable even if
        // one client can read the boot UUID and another runs in a restricted sandbox.
        if let birth = absoluteStartTimeMicroseconds { return "birth:\(pid):\(birth)" }
        return "\(bootID):\(pid):\(startTimeTicks)"
    }
    public var id: String { key }

    public init(bootID: String, pid: Int, parentPID: Int, startTimeTicks: UInt64,
                startedAt: Date, executable: String, role: ProcessRole, roleHint: String = "",
                rootKey: String = "", footprintBytes: UInt64, rssBytes: UInt64 = 0,
                peakFootprintBytes: UInt64 = 0, cpuPercent: Double? = nil,
                ownership: String = "process_tree", absoluteStartTimeMicroseconds: UInt64? = nil) {
        self.bootID = bootID; self.pid = pid; self.parentPID = parentPID
        self.startTimeTicks = startTimeTicks; self.startedAt = startedAt
        self.absoluteStartTimeMicroseconds = absoluteStartTimeMicroseconds
        self.executable = executable; self.role = role; self.roleHint = roleHint
        self.rootKey = rootKey; self.footprintBytes = footprintBytes; self.rssBytes = rssBytes
        self.peakFootprintBytes = peakFootprintBytes; self.cpuPercent = cpuPercent
        self.ownership = ownership
    }
}

public struct SystemMemorySample: Codable, Equatable, Sendable {
    public var physicalBytes: UInt64
    public var compressedPhysicalBytes: UInt64?
    public var swapUsedBytes: UInt64?
    public var pressureLevel: Int?

    public init(physicalBytes: UInt64 = 0, compressedPhysicalBytes: UInt64? = nil,
                swapUsedBytes: UInt64? = nil, pressureLevel: Int? = nil) {
        self.physicalBytes = physicalBytes; self.compressedPhysicalBytes = compressedPhysicalBytes
        self.swapUsedBytes = swapUsedBytes; self.pressureLevel = pressureLevel
    }
}

public struct MemorySnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var capturedAt: Date
    public var processes: [ProcessSample]
    public var observer: ProcessSample?
    public var system: SystemMemorySample
    public var unavailablePIDs: [Int]
    public var warnings: [String]
    public var totalFootprintBytes: UInt64 { processes.reduce(0) { $0 + $1.footprintBytes } }

    public init(id: String = UUID().uuidString, capturedAt: Date = Date(),
                processes: [ProcessSample], observer: ProcessSample? = nil,
                system: SystemMemorySample = .init(), unavailablePIDs: [Int] = [], warnings: [String] = []) {
        self.id = id; self.capturedAt = capturedAt; self.processes = processes
        self.observer = observer; self.system = system
        self.unavailablePIDs = unavailablePIDs; self.warnings = warnings
    }
}

public enum MemoryError: Error, CustomStringConvertible {
    case message(String)
    case monitorBusy
    public var description: String {
        switch self {
        case .message(let s): return s
        case .monitorBusy: return "已有采集器持有监控锁。不会停止现有进程。"
        }
    }
}

public enum MemoryJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
