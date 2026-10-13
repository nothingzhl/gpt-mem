import Foundation
import Darwin
import GPTMemoryCore

private struct Options {
    var command = "status"
    var json = false
    var database: URL
    var since: TimeInterval = 1800
    var interval: TimeInterval = 5
    var duration: TimeInterval?
    var output: URL?
    var pid: Int?
    var help = false

    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let home: URL
        if let override = environment["GPT_MEM_HOME"], !override.isEmpty {
            home = Self.fileURL(override)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/gpt-mem", isDirectory: true)
        }
        database = home.appendingPathComponent("history.sqlite3")
        var args = arguments
        if let first = args.first, !first.hasPrefix("-") { command = args.removeFirst() }
        if command == "help" { help = true }
        guard ["status", "watch", "explain", "report", "diagnose", "help"].contains(command) else {
            throw MemoryError.message("未知命令：\(command)。运行 gpt-mem --help 查看用法。")
        }
        if command == "report" { since = 7200 }
        var seen = Set<String>()
        while !args.isEmpty {
            let flag = args.removeFirst()
            guard !seen.contains(flag) else { throw MemoryError.message("参数重复：\(flag)") }
            seen.insert(flag)
            switch flag {
            case "--help", "-h": help = true
            case "--json": json = true
            case "--db": database = Self.fileURL(try Self.takeValue(flag, args: &args))
            case "--since":
                guard command == "explain" || command == "report" else {
                    throw MemoryError.message("--since 仅用于 explain 或 report。")
                }
                since = try Self.parseSpan(Self.takeValue(flag, args: &args))
            case "--interval":
                guard command == "watch" else { throw MemoryError.message("--interval 仅用于 watch。") }
                let raw = try Self.takeValue(flag, args: &args)
                guard let value = Double(raw), value.isFinite, value >= 1 else {
                    throw MemoryError.message("--interval 必须为大于等于 1 的秒数。")
                }
                interval = value
            case "--duration":
                guard command == "watch" else { throw MemoryError.message("--duration 仅用于 watch。") }
                let raw = try Self.takeValue(flag, args: &args)
                guard let value = Double(raw), value.isFinite, value > 0 else {
                    throw MemoryError.message("--duration 必须为大于 0 的秒数。")
                }
                duration = value
            case "--output":
                guard command == "report" || command == "diagnose" else { throw MemoryError.message("--output 仅用于 report 或 diagnose。") }
                output = Self.fileURL(try Self.takeValue(flag, args: &args))
            case "--pid":
                guard command == "diagnose" else { throw MemoryError.message("--pid 仅用于 diagnose。") }
                let raw = try Self.takeValue(flag, args: &args)
                guard let value = Int(raw), value > 0, value <= Int(Int32.max) else {
                    throw MemoryError.message("--pid 必须为有效的正整数。")
                }
                pid = value
            case "--capture":
                throw MemoryError.message("本版不自动运行 vmmap 等重型诊断；采样仅使用原生只读接口。")
            default: throw MemoryError.message("未知参数：\(flag)")
            }
        }
        if command == "diagnose", !help, pid == nil || output == nil {
            throw MemoryError.message("diagnose 需要同时提供 --pid 和 --output。")
        }
    }

    private static func takeValue(_ flag: String, args: inout [String]) throws -> String {
        guard let value = args.first, !value.hasPrefix("--"), !value.isEmpty else {
            throw MemoryError.message("\(flag) 缺少值。")
        }
        args.removeFirst()
        return value
    }

    private static func parseSpan(_ raw: String) throws -> TimeInterval {
        let multipliers: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        let suffix = raw.last
        let multiplier = suffix.flatMap { multipliers[$0] } ?? 1
        let number = suffix.flatMap { multipliers[$0] } == nil ? raw : String(raw.dropLast())
        guard let value = Double(number), value.isFinite, value > 0,
              (value * multiplier).isFinite, value * multiplier <= 366 * 86400 else {
            throw MemoryError.message("--since 必须为 0 到 366 天内的正时长，例如 30m、2h、7d。")
        }
        return value * multiplier
    }

    static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}

private struct RoleTotal: Codable {
    var role: ProcessRole
    var label: String
    var count: Int
    var footprintBytes: UInt64
}

private struct StatusOutput: Codable {
    var command: String
    var snapshot: MemorySnapshot
    var roleTotals: [RoleTotal]
    var currentTop: [ProcessSample]
    var growthSincePrevious: MemoryAnalysis?
    var sessionAttribution = "unknown"
}

private struct ReportOutput: Codable {
    var command = "report"
    var generatedAt = Date()
    var output: String?
    var analysis: MemoryAnalysis
    var endSnapshot: MemorySnapshot
    var roleTotals: [RoleTotal]
    var trend: [TrendPoint]
    var sessionAttribution = "unknown"
}

private struct TrendPoint: Codable {
    var capturedAt: Date
    var footprintBytes: UInt64
    var processCount: Int
}

private let usage = """
gpt-mem：macOS ChatGPT / Codex 内存观察器（只读）

用法：
  gpt-mem [status] [--json] [--db path]
  gpt-mem watch [--interval 5] [--duration 60] [--json] [--db path]
  gpt-mem explain [--since 30m] [--json] [--db path]
  gpt-mem report [--since 2h] [--output report.html] [--json] [--db path]
  gpt-mem diagnose --pid PID --output vmmap-summary.txt [--json]

watch 默认持续运行，Ctrl-C / SIGTERM 结束；--interval 最小 1 秒。
watch --json 每次采样输出一行 JSON；其他 --json 命令输出一个 JSON 对象。
explain / report 需要至少两份 watch 历史样本；status 不写历史数据库。
默认数据库：~/Library/Application Support/gpt-mem/history.sqlite3
GPT_MEM_HOME 可覆盖默认数据库所在目录，--db 可指定具体文件。
report --output 生成离线 HTML；报告文件包含 PID 和时间，分享前请自行检查。
占用口径为 physical footprint，观察器自身单列，不计入 GPT 总占用。
diagnose 只对当前 GPT 目标进程手动运行有界的 vmmap -summary，不停止目标进程。
本版不会读取聊天或凭据、自动启用 launchd，也不自动运行 vmmap。
"""

private func err(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func emit<T: Encodable>(_ value: T, pretty: Bool = true) throws {
    let encoded = try MemoryJSON.encoder().encode(value)
    let object = try JSONSerialization.jsonObject(with: encoded)
    let sanitized = sanitizeJSON(object)
    let data = try JSONSerialization.data(withJSONObject: sanitized,
                                         options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

// Reports do not expose executable paths. No command line or environment is collected.
private func sanitizeJSON(_ object: Any) -> Any {
    if let values = object as? [Any] { return values.map(sanitizeJSON) }
    guard let dictionary = object as? [String: Any] else { return object }
    return dictionary.mapValues(sanitizeJSON).reduce(into: [String: Any]()) { result, entry in
        if entry.key == "executable", let value = entry.value as? String {
            result[entry.key] = basename(value)
        } else { result[entry.key] = entry.value }
    }
}

private func basename(_ value: String) -> String {
    value.isEmpty ? "未知" : URL(fileURLWithPath: value).lastPathComponent
}

private func size(_ bytes: UInt64) -> String {
    let divisor = bytes >= 1_073_741_824 ? 1_073_741_824.0 : 1_048_576.0
    return String(format: "%.1f %@", Double(bytes) / divisor, bytes >= 1_073_741_824 ? "GiB" : "MiB")
}

private func delta(_ bytes: Int64) -> String {
    String(format: "%+.1f MiB", Double(bytes) / 1_048_576)
}

private func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date) + " +08:00"
}

private func roleTotals(_ snapshot: MemorySnapshot) -> [RoleTotal] {
    ProcessRole.allCases.compactMap { role in
        let processes = snapshot.processes.filter { $0.role == role }
        guard !processes.isEmpty else { return nil }
        return RoleTotal(role: role, label: role.label, count: processes.count,
                         footprintBytes: processes.reduce(0) { $0 + $1.footprintBytes })
    }.sorted { $0.footprintBytes > $1.footprintBytes }
}

private func statusOutput(_ snapshot: MemorySnapshot, previous: MemorySnapshot?, command: String = "status") -> StatusOutput {
    StatusOutput(command: command, snapshot: snapshot, roleTotals: roleTotals(snapshot),
                 currentTop: Array(snapshot.processes.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(10)),
                 growthSincePrevious: previous.map { MemoryAnalyzer.analyze([$0, snapshot]) })
}

private func printStatus(_ output: StatusOutput) {
    let s = output.snapshot
    print("\(timestamp(s.capturedAt))  GPT 合计 \(size(s.totalFootprintBytes))，\(s.processes.count) 个进程")
    if s.processes.isEmpty { print("当前未找到可识别的 ChatGPT / Codex 进程。") }
    print("角色\t进程数\tFootprint")
    for row in output.roleTotals { print("\(row.label)\t\(row.count)\t\(size(row.footprintBytes))") }
    if let observer = s.observer {
        print("观察器自身（不计入合计）\tPID \(observer.pid)\t\(size(observer.footprintBytes))")
    } else { print("观察器自身：本次指标不可用") }
    let pressure: String
    switch s.system.pressureLevel {
    case 1: pressure = "正常"
    case 2: pressure = "警告"
    case 4: pressure = "严重"
    case let level?: pressure = "原始级别 \(level)"
    default: pressure = "未知"
    }
    print("系统物理内存 \(size(s.system.physicalBytes))，压力 \(pressure)，压缩 \(s.system.compressedPhysicalBytes.map(size) ?? "未知")，交换 \(s.system.swapUsedBytes.map(size) ?? "未知")")
    if !output.currentTop.isEmpty {
        print("当前占用最高进程：")
        for p in output.currentTop {
            print("  PID \(p.pid) / PPID \(p.parentPID)  \(p.role.label)  \(basename(p.executable))  \(size(p.footprintBytes))  启动 \(timestamp(p.startedAt))")
        }
    }
    if let analysis = output.growthSincePrevious {
        print("相对上一份历史采样（\(analysis.start.map(timestamp) ?? "未知")）：\(delta(analysis.totalChangeBytes))")
        print("  新增 \(delta(analysis.addedContributionBytes))，退出 \(delta(analysis.exitedContributionBytes))，存量 \(delta(analysis.existingChangeBytes))，无法归因 \(delta(analysis.unresolvedContributionBytes))")
        printExplanation(analysis.explanation)
    }
    printWarnings(s.warnings)
    if !s.unavailablePIDs.isEmpty { print("缺少内存指标的 PID：\(s.unavailablePIDs.map(String.init).joined(separator: ", "))。本次合计可能偏低。") }
    print("聊天 / 会话归属：未知；进程常驻或增长均不能单独证明泄漏。")
}

private func printWarnings(_ values: [String]) {
    for value in values { print("提示：\(value)") }
}

private func printAnalysis(_ a: MemoryAnalysis) {
    printExplanation(a.explanation)
    print("\(a.start.map(timestamp) ?? "未知") → \(a.end.map(timestamp) ?? "未知")；\(a.sampleCount) 份样本")
    print("GPT 占用 \(size(a.startTotalBytes)) → \(size(a.endTotalBytes))，变化 \(delta(a.totalChangeBytes))")
    print("增长归因：新增进程 \(delta(a.addedContributionBytes))；退出进程 \(delta(a.exitedContributionBytes))；已有进程 \(delta(a.existingChangeBytes))；无法归因 \(delta(a.unresolvedContributionBytes))")
    if !a.isComplete { print("样本时间不足或指标缺失，本次归因不完整。") }
    if !a.topChanges.isEmpty {
        print("占用变化最高的进程：")
        for p in a.topChanges.prefix(15) {
            print("  PID \(p.pid)  \(p.role.label)  \(basename(p.executable))  \(p.kind)  \(p.deltaBytes.map(delta) ?? "指标缺失")")
        }
    }
    if a.sustainedGrowthCandidates.isEmpty { print("当前窗口未达到持续增长候选规则；这不能排除长期泄漏。") }
    else {
        print("持续增长候选（需进一步定位，未确认泄漏）：")
        for p in a.sustainedGrowthCandidates {
            print("  PID \(p.pid)  \(p.role.label)  \(basename(p.executable))  增加 \(delta(p.netGrowthBytes))，\(p.sampleCount) 份样本")
        }
    }
    print("窗口内事件 \(a.events.count) 条；聊天 / 会话归属未知。")
    printWarnings(a.warnings)
}

private func printExplanation(_ explanation: AnalysisExplanation?) {
    guard let explanation else { return }
    print("分析结论：\(explanation.headline)")
    print(explanation.summary)
    for evidence in explanation.evidence { print("依据：\(evidence)") }
    if !explanation.findings.isEmpty {
        print("重点发现：")
        for finding in explanation.findings { print("  \(finding.title)：\(finding.detail)") }
    }
    if !explanation.nextSteps.isEmpty {
        print("下一步检查：")
        for (index, step) in explanation.nextSteps.enumerated() { print("  \(index + 1). \(step)") }
    }
}

private func escapeHTML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func cell(_ value: String) -> String { "<td>\(escapeHTML(value))</td>" }
private func row(_ values: [String]) -> String { "<tr>\(values.map(cell).joined())</tr>" }
private func table(_ headers: [String], _ rows: [[String]]) -> String {
    let head = headers.map { "<th>\(escapeHTML($0))</th>" }.joined()
    return "<div class=scroll><table><thead><tr>\(head)</tr></thead><tbody>\(rows.map(row).joined())</tbody></table></div>"
}

private func explanationHTML(_ explanation: AnalysisExplanation?) -> String {
    guard let explanation else { return "" }
    let evidence = explanation.evidence.map { "<li>\(escapeHTML($0))</li>" }.joined()
    let findings = explanation.findings.map {
        "<li><strong>\(escapeHTML($0.title))</strong><br>\(escapeHTML($0.detail))</li>"
    }.joined()
    let steps = explanation.nextSteps.map { "<li>\(escapeHTML($0))</li>" }.joined()
    return """
    <section class="card"><h2>分析结论</h2><h3>\(escapeHTML(explanation.headline))</h3>
    <p>\(escapeHTML(explanation.summary))</p><h3>判断依据</h3><ul>\(evidence)</ul>
    \(findings.isEmpty ? "" : "<h3>重点发现</h3><ul>\(findings)</ul>")
    \(steps.isEmpty ? "" : "<h3>下一步检查</h3><ol>\(steps)</ol>")</section>
    """
}

private func htmlReport(_ output: ReportOutput) -> String {
    let a = output.analysis, s = output.endSnapshot
    let roles = table(["角色", "进程数", "结束时 Footprint"], output.roleTotals.map { [$0.label, String($0.count), size($0.footprintBytes)] })
    let changes = table(["PID", "角色", "程序", "变化类型", "起始", "结束", "变化"], a.topChanges.map {
        [String($0.pid), $0.role.label, basename($0.executable), $0.kind.rawValue,
         $0.startBytes.map(size) ?? "不可用", $0.endBytes.map(size) ?? "不可用", $0.deltaBytes.map(delta) ?? "不可用"]
    })
    let processes = table(["PID", "PPID", "角色", "程序", "启动时间", "Footprint", "峰值 Footprint", "RSS"], s.processes.sorted { $0.footprintBytes > $1.footprintBytes }.map {
        [String($0.pid), String($0.parentPID), $0.role.label, basename($0.executable), timestamp($0.startedAt),
         size($0.footprintBytes), size($0.peakFootprintBytes), size($0.rssBytes)]
    })
    let events = table(["时间", "类型", "PID", "角色", "说明"], a.events.map {
        [timestamp($0.capturedAt), $0.kind.rawValue, $0.pid.map(String.init) ?? "—", $0.role?.label ?? "—", $0.message]
    })
    let candidates = table(["PID", "角色", "程序", "增长", "样本数"], a.sustainedGrowthCandidates.map {
        [String($0.pid), $0.role.label, basename($0.executable), delta($0.netGrowthBytes), String($0.sampleCount)]
    })
    let warnings = Array(Set(a.warnings + s.warnings)).sorted().map { "<li>\(escapeHTML($0))</li>" }.joined()
    let observer = s.observer.map { "PID \($0.pid)，Footprint \(size($0.footprintBytes))" } ?? "指标不可用"
    let compression = s.system.compressedPhysicalBytes.map(size) ?? "未知"
    let swap = s.system.swapUsedBytes.map(size) ?? "未知"
    let trend = trendSVG(output.trend)
    return """
    <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>GPT 内存观察报告</title><style>
    :root{color-scheme:light dark}body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;max-width:1120px;margin:32px auto;padding:0 20px;line-height:1.65;color:#20303c;background:#f5f7fa}h1{font-size:28px}h2{font-size:19px;margin-top:30px}.cards{display:flex;gap:12px;flex-wrap:wrap}.card{background:white;padding:16px;border-radius:10px;min-width:190px;flex:1}.large{font-size:24px;font-weight:700}table{border-collapse:collapse;width:100%;background:white;font-size:13px}th,td{padding:9px 12px;border-bottom:1px solid #e2e8ee;text-align:left;white-space:nowrap}th{background:#e8eef4}.scroll{overflow:auto}.muted{color:#536773}.notice{padding:12px 16px;background:#e8eef4;border-radius:8px}@media(prefers-color-scheme:dark){body{background:#131b22;color:#e0e8ee}.card,table{background:#1f2932}th,.notice{background:#2d3944}th,td{border-color:#3a4854}.muted{color:#b6c7d4}}
    </style><main><h1>GPT 内存观察报告</h1>
    <p class="muted">生成：\(escapeHTML(timestamp(output.generatedAt)))<br>窗口：\(escapeHTML(a.start.map(timestamp) ?? "未知")) → \(escapeHTML(a.end.map(timestamp) ?? "未知"))；\(a.sampleCount) 份样本，结束时 \(s.processes.count) 个进程。</p>
    \(explanationHTML(a.explanation))
    <div class="cards"><div class="card">起始占用<div class="large">\(escapeHTML(size(a.startTotalBytes)))</div></div><div class="card">结束占用<div class="large">\(escapeHTML(size(a.endTotalBytes)))</div></div><div class="card">总变化<div class="large">\(escapeHTML(delta(a.totalChangeBytes)))</div></div></div>
    <h2>占用时间线</h2>\(trend)
    <h2>增长归因</h2>\(table(["来源", "贡献"], [["新增进程", delta(a.addedContributionBytes)], ["退出进程", delta(a.exitedContributionBytes)], ["已有进程", delta(a.existingChangeBytes)], ["无法归因", delta(a.unresolvedContributionBytes)]]))
    <p class="notice">\(a.isComplete ? "窗口内归因完整。" : "样本时间不足或指标缺失，归因不完整。") 会话归属未知。持续增长仅为候选，常驻时间和内存上涨均不能单独证明泄漏。总占用为已识别进程的 physical footprint 合计，观察器自身单列。</p>
    <h2>结束时角色占用</h2>\(roles)
    <h2>进程变化</h2>\(changes)
    <h2>持续增长候选</h2>\(candidates)<p class="muted">规则未命中也不能排除其他窗口中的增长或泄漏。</p>
    <h2>进程事件</h2>\(events)
    <h2>结束时进程明细</h2>\(processes)
    <h2>系统与观察器</h2><p>物理内存：\(escapeHTML(size(s.system.physicalBytes)))；压缩：\(escapeHTML(compression))；交换：\(escapeHTML(swap))；压力原始级别：\(s.system.pressureLevel.map(String.init) ?? "未知")。<br>观察器自身：\(escapeHTML(observer))，不计入 GPT 总占用。</p>
    <h2>缺失数据与限制</h2><ul>\(warnings)</ul><p>结束时不可用 PID：\(escapeHTML(s.unavailablePIDs.map(String.init).joined(separator: ", ")))。报告只显示程序文件名，包含 PID 和运行时间；不会包含聊天正文、令牌或原始命令行。所有资源均内嵌，可离线打开。</p>
    </main></html>
    """
}

private func trendSVG(_ points: [TrendPoint]) -> String {
    guard let first = points.first, let last = points.last else { return "<p>没有趋势样本。</p>" }
    let width = 900.0, height = 230.0
    let left = 72.0, right = 24.0, top = 25.0, bottom = 40.0
    let span = max(1, last.capturedAt.timeIntervalSince(first.capturedAt))
    let maximum = max(1, Double(points.map(\.footprintBytes).max() ?? 0) * 1.05)
    // Bound SVG output independently of history length; every bucket retains its peak.
    let bucketSize = max(1, Int(ceil(Double(points.count) / 900.0)))
    var reduced: [TrendPoint] = []
    for offset in stride(from: 0, to: points.count, by: bucketSize) {
        let bucket = points[offset..<min(points.count, offset + bucketSize)]
        if let maximum = bucket.max(by: { $0.footprintBytes < $1.footprintBytes }) { reduced.append(maximum) }
    }
    if reduced.first?.capturedAt != first.capturedAt { reduced.insert(first, at: 0) }
    if reduced.last?.capturedAt != last.capturedAt { reduced.append(last) }
    let coordinates = reduced.map { point -> String in
        let x = left + point.capturedAt.timeIntervalSince(first.capturedAt) / span * (width - left - right)
        let y = height - bottom - Double(point.footprintBytes) / maximum * (height - top - bottom)
        return String(format: "%.2f,%.2f", x, y)
    }.joined(separator: " ")
    return """
    <div class="card"><svg viewBox="0 0 900 230" width="100%" role="img" aria-label="GPT footprint 时间线，从 \(escapeHTML(size(first.footprintBytes))) 到 \(escapeHTML(size(last.footprintBytes)))">
    <line x1="72" y1="25" x2="72" y2="190" stroke="currentColor" opacity=".35"/><line x1="72" y1="190" x2="876" y2="190" stroke="currentColor" opacity=".35"/>
    <text x="4" y="31" fill="currentColor" font-size="12">\(escapeHTML(size(UInt64(maximum))))</text><text x="42" y="190" fill="currentColor" font-size="12">0</text>
    <polyline points="\(coordinates)" fill="none" stroke="#1e94ca" stroke-width="2.5"/>
    <text x="72" y="218" fill="currentColor" font-size="11">\(escapeHTML(timestamp(first.capturedAt)))</text><text x="876" y="218" text-anchor="end" fill="currentColor" font-size="11">\(escapeHTML(timestamp(last.capturedAt)))</text>
    </svg><p class="muted">仅连接成功采样点；休眠或缺失期间不代表连续测量。长窗口按桶保留峰值以控制图表大小。</p></div>
    """
}

// Only this trivial signal handler touches signal-safe scalar state.
private var stopRequested: sig_atomic_t = 0
private func stopHandler(_ signal: Int32) { stopRequested = 1 }

private let continuousTimeScale: Double = {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}()
private func monotonicSeconds() -> Double {
    // mach_continuous_time includes sleep; wall-clock corrections cannot extend duration.
    Double(mach_continuous_time()) * continuousTimeScale
}

private func watch(_ options: Options) throws {
    try FileManager.default.createDirectory(at: options.database.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lock = try MonitorLock(url: options.database.deletingLastPathComponent().appendingPathComponent("monitor.lock"))
    defer { withExtendedLifetime(lock) {} }
    let store = try MemoryStore(url: options.database, readOnly: false)
    let oldInterrupt = signal(SIGINT, stopHandler)
    let oldTerminate = signal(SIGTERM, stopHandler)
    defer { signal(SIGINT, oldInterrupt); signal(SIGTERM, oldTerminate) }
    stopRequested = 0
    let collector = NativeCollector()
    let started = monotonicSeconds()
    let deadline = options.duration.map { started + $0 }
    var nextTick = started
    var nextMaintenance = started
    var previous: MemorySnapshot?
    var samples = 0
    if !options.json { err("开始只读采样，每 \(options.interval) 秒一次；Ctrl-C 结束。数据库：\(options.database.path)") }
    while stopRequested == 0 {
        let now = monotonicSeconds()
        if let deadline, now >= deadline { break }
        if now < nextTick {
            let until = min(nextTick, deadline ?? nextTick)
            Thread.sleep(forTimeInterval: max(0, min(0.1, until - now)))
            continue
        }
        let snapshot = try collector.sample()
        try store.save(snapshot)
        samples += 1
        if options.json { try emit(statusOutput(snapshot, previous: previous, command: "watch"), pretty: false) }
        else {
            let change = previous.map { delta(Int64(snapshot.totalFootprintBytes) - Int64($0.totalFootprintBytes)) } ?? "基线"
            print("\(timestamp(snapshot.capturedAt))  \(size(snapshot.totalFootprintBytes))  \(snapshot.processes.count) 个进程  \(change)  自身 \(snapshot.observer.map { size($0.footprintBytes) } ?? "未知")")
            fflush(stdout)
            for warning in snapshot.warnings { err("提示：\(warning)") }
        }
        previous = snapshot
        let afterSample = monotonicSeconds()
        if afterSample >= nextMaintenance {
            try store.maintenance(now: snapshot.capturedAt)
            nextMaintenance = afterSample + 60
        }
        // Skip missed ticks after suspend or slow sampling instead of issuing catch-up bursts.
        nextTick = afterSample + options.interval
    }
    if !options.json { err("采样结束，共保存 \(samples) 份样本。") }
}

private func history(_ options: Options) throws -> ([MemorySnapshot], MemoryAnalysis) {
    guard FileManager.default.fileExists(atPath: options.database.path) else {
        throw MemoryError.message("没有历史数据库，请先运行 gpt-mem watch --duration 60。")
    }
    let store = try MemoryStore(url: options.database, readOnly: true)
    let snapshots = try store.load(since: Date().addingTimeInterval(-options.since))
    guard snapshots.count >= 2 else {
        throw MemoryError.message("所选窗口只有 \(snapshots.count) 份样本，至少需要 2 份；先运行 watch 或扩大 --since。")
    }
    return (snapshots, MemoryAnalyzer.analyze(snapshots))
}

private func validateReportDestination(_ output: URL, database: URL) throws {
    let databasePath = database.resolvingSymlinksInPath().path
    let lockPath = database.deletingLastPathComponent().appendingPathComponent("monitor.lock").resolvingSymlinksInPath().path
    let path = output.resolvingSymlinksInPath().path
    guard ![databasePath, databasePath + "-wal", databasePath + "-shm", lockPath].contains(path) else {
        throw MemoryError.message("报告输出不能覆盖历史数据库、SQLite 附属文件或监控锁。")
    }
}

private func run() throws {
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
    if options.help { print(usage); return }
    switch options.command {
    case "status":
        let snapshot = try NativeCollector().sample()
        var previous: MemorySnapshot?
        if FileManager.default.fileExists(atPath: options.database.path) {
            do { previous = try MemoryStore(url: options.database, readOnly: true).latest() }
            catch { err("提示：历史基线读取失败：\(error)。当前原生采样仍可用。") }
        }
        let result = statusOutput(snapshot, previous: previous)
        if options.json { try emit(result) } else { printStatus(result) }
    case "watch": try watch(options)
    case "explain":
        let (_, analysis) = try history(options)
        if options.json { try emit(analysis) } else { printAnalysis(analysis) }
    case "report":
        if let output = options.output { try validateReportDestination(output, database: options.database) }
        let (snapshots, analysis) = try history(options)
        guard let last = snapshots.last else { throw MemoryError.message("历史样本为空。") }
        let result = ReportOutput(output: options.output?.path, analysis: analysis,
                                  endSnapshot: last, roleTotals: roleTotals(last),
                                  trend: snapshots.map { TrendPoint(capturedAt: $0.capturedAt, footprintBytes: $0.totalFootprintBytes, processCount: $0.processes.count) })
        if let destination = options.output {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try htmlReport(result).write(to: destination, atomically: true, encoding: .utf8)
        }
        if options.json { try emit(result) }
        else {
            printAnalysis(analysis)
            if let destination = options.output { print("HTML 报告已保存：\(destination.path)") }
            else { print("使用 --output report.html 生成包含角色、事件和进程明细的离线报告。") }
        }
    case "diagnose":
        guard let pid = options.pid, let output = options.output else {
            throw MemoryError.message("diagnose 需要同时提供 --pid 和 --output。")
        }
        let snapshot = try NativeCollector().sample()
        guard let process = snapshot.processes.first(where: { $0.pid == pid }) else {
            throw MemoryError.message("PID \(pid) 不是当前可识别且可读的 GPT 目标进程；未运行诊断。")
        }
        let result = try DiagnosticCapture.capture(process: process, output: output)
        if options.json { try emit(result) }
        else { print("PID \(pid) 的 vmmap 摘要已保存：\(result.outputPath)；退出码 \(result.exitCode)，超时 \(result.timedOut)，部分结果 \(result.partial)。") }
        if result.exitCode != 0 || result.timedOut || result.partial { exit(2) }
    default: print(usage)
    }
}

do { try run() }
catch {
    err("gpt-mem：\(error)")
    exit(1)
}
