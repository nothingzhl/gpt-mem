import Foundation

public enum SessionSearchScope: String, CaseIterable, Sendable {
    case all, user, assistant, tools, errors, code
    public var title: String {
        switch self {
        case .all: return "所有消息"
        case .user: return "用户提问"
        case .assistant: return "助手回答"
        case .tools: return "工具调用与结果"
        case .errors: return "报错线索"
        case .code: return "代码片段"
        }
    }
    public func includes(_ message: SessionMessage) -> Bool {
        switch self {
        case .all: return true
        case .user: return message.kind == .user
        case .assistant: return message.kind == .assistant
        case .tools: return message.kind == .toolCall || message.kind == .toolResult
        case .errors:
            return ["error", "exception", "failed", "失败", "报错", "错误"].contains {
                message.text.localizedCaseInsensitiveContains($0)
            }
        case .code: return message.text.contains("```") || message.kind == .toolCall
        }
    }
}

public struct SessionSearchHit: Identifiable, Sendable {
    public var id: String { summary.id + ":" + messageID }
    public let summary: CodexSessionSummary
    public let messageID: String
    public let kind: SessionMessageKind
    public let timestamp: Date?
    public let excerpt: String
}

public struct SessionSearchResult: Sendable {
    public let hits: [SessionSearchHit]
    public let scannedSessions: Int
    public let totalSessions: Int
    public let skippedSessions: Int
    public let incompleteSessions: Int
    public let stoppedAtLimit: Bool
}

/// Explicit, cancellable sequential reads. Retains excerpts rather than whole transcripts.
public enum SessionFullTextSearch {
    public static func search(sessions: [CodexSessionSummary], query: String, scope: SessionSearchScope,
                              maximumHits: Int = 200, maximumBytes: Int = 128 * 1_024 * 1_024,
                              progress: @Sendable (Int, Int) -> Void = { _, _ in },
                              loader: (CodexSessionSummary) throws -> SessionTranscript) throws -> SessionSearchResult {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else {
            return .init(hits: [], scannedSessions: 0, totalSessions: sessions.count, skippedSessions: 0,
                         incompleteSessions: 0, stoppedAtLimit: false)
        }
        var hits: [SessionSearchHit] = [], scanned = 0, skipped = 0, incomplete = 0, bytes = 0, limited = false
        for summary in sessions {
            try Task.checkCancellation()
            let size = (try? summary.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let cost = max(0, size)
            guard cost <= max(0, maximumBytes) - bytes else { limited = true; break }
            bytes += cost
            do {
                let transcript = try loader(summary)
                guard transcript.summary.id == summary.id else { skipped += 1; continue }
                scanned += 1
                if !transcript.warnings.isEmpty { incomplete += 1 }
                for message in transcript.messages {
                    try Task.checkCancellation()
                    guard scope.includes(message), terms.allSatisfy({ message.text.localizedCaseInsensitiveContains($0) }) else { continue }
                    guard hits.count < max(1, maximumHits) else { limited = true; break }
                    hits.append(.init(summary: transcript.summary, messageID: message.id, kind: message.kind,
                                      timestamp: message.timestamp, excerpt: excerpt(message.text, term: terms[0])))
                }
                progress(scanned + skipped, sessions.count)
                if limited { break }
            } catch is CancellationError { throw CancellationError() }
            catch { skipped += 1; progress(scanned + skipped, sessions.count) }
        }
        return .init(hits: hits, scannedSessions: scanned, totalSessions: sessions.count,
                     skippedSessions: skipped, incompleteSessions: incomplete, stoppedAtLimit: limited)
    }

    private static func excerpt(_ text: String, term: String) -> String {
        guard let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { return String(text.prefix(360)) }
        let start = text.index(match.lowerBound, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 360, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}

public enum SessionHandoff {
    /// Quoted evidence, not inferred completion. Users edit the task/status fields before reuse.
    public static func draft(transcript: SessionTranscript, note: String = "") -> String {
        let summary = transcript.summary
        let users = transcript.messages.filter { $0.kind == .user }
        let assistants = transcript.messages.filter { $0.kind == .assistant }
        func quote(_ messages: [SessionMessage]) -> String {
            messages.map { message in
                let body = String(message.text.prefix(1_600))
                return "消息 \(message.id)\n" + body + (message.text.count > 1_600 ? "\n[原文已截断]" : "")
            }.joined(separator: "\n\n---\n\n")
        }
        let goal = users.last.map { String($0.text.prefix(1_600)) } ?? "[未记录用户需求，请填写]"
        let recentAnswers = Array(assistants.suffix(2))
        func lines(containing markers: [String]) -> String {
            var matches: [String] = []
            for message in recentAnswers {
                for line in message.text.split(separator: "\n") {
                    guard markers.contains(where: { line.localizedCaseInsensitiveContains($0) }) else { continue }
                    matches.append("- " + String(line.prefix(500)) + "（来源消息：" + message.id + "）")
                    if matches.count == 8 { return matches.joined(separator: "\n") }
                }
            }
            return matches.isEmpty ? "[日志中未提取到明确线索，请补充]" : matches.joined(separator: "\n")
        }
        let progress = lines(containing: ["已完成", "已修复", "已实现", "通过", "测试", "验证"])
        let nextSteps = lines(containing: ["下一步", "待办", "后续", "接下来", "尚未", "未完成"])
        return """
        # 继续工作交接稿

        项目：\(summary.projectPath ?? "未记录")
        来源会话：\(summary.title)
        会话 ID：\(summary.sessionID)
        来源文件：\(summary.fileURL.path)

        ## 当前目标
        最近用户要求（请确认是否为当前目标）：
        \(goal)

        ## 已完成与验证
        按关键词提取的进展线索，助手原文不等于已验证事实：
        \(progress)
        [请核实并补充已确认的结果]

        ## 下一步与限制
        按关键词提取的下一步线索：
        \(nextSteps)
        [请确认待办、约束与需要重新验证的内容]

        ## 本地备注
        \(note.isEmpty ? "无" : String(note.prefix(4_000)))

        ## 最近用户需求（最多 4 条原文）
        \(quote(Array(users.suffix(4))))

        ## 最近助手答复（最多 2 条原文）
        \(quote(Array(assistants.suffix(2))))

        以上为本地日志摘录，请结合当前代码与运行状态确认。\(transcript.warnings.isEmpty ? "" : "来源存在读取提示，摘录可能不完整。")
        """
    }
}
