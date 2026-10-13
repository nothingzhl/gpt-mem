import Foundation
import CoreFoundation
import Darwin

/// Ported format knowledge from Sessions Viewer's Codex adapter, with bounded
/// Swift value models and explicit partial/unknown usage instead of invented counts.
struct CodexRolloutParser {
    private let fileURL: URL
    private let fileUpdatedAt: Date
    private let isArchived: Bool
    private let limits: SessionReadLimits
    private let retainsMessages: Bool
    private var sessionID: String?
    private var projectPath: String?
    private var startedAt: Date?
    private var model: String?
    private var renamedTitle: String?
    private var entries: [Entry] = []
    private var acceptedEntryCount = 0
    private var messageCount = 0
    private var toolCallCount = 0
    private var firstMessageTimestamp: Date?
    private var firstUserTitle: String?
    private var searchText = ""
    private var searchCharacters = 0
    private var searchTruncated = false
    private var warnings: [String] = []
    private var latestCumulative: CodexTokenUsage?
    private var incremental: [String: CodexTokenUsage] = [:]
    private var incrementalMissingIdentity = false
    private var currentTurnID: String?
    private var toolNames: [String: String] = [:]
    private var knownItemIDs: Set<String> = []
    private var dateFormatter = ISO8601DateFormatter()
    private var fallbackDateFormatter = ISO8601DateFormatter()

    init(fileURL: URL, updatedAt: Date, isArchived: Bool, limits: SessionReadLimits, retainsMessages: Bool = true) {
        self.fileURL = fileURL; self.fileUpdatedAt = updatedAt; self.isArchived = isArchived; self.limits = limits
        self.retainsMessages = retainsMessages
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    mutating func warn(_ text: String) {
        guard warnings.count < 30, !warnings.contains(text) else { return }
        warnings.append(text)
    }

    mutating func consume(_ data: Data, line: Int, isFinalLine: Bool) {
        // Foundation JSON bridging creates autoreleased temporary objects. Drain
        // them per record instead of retaining a whole catalog read's temporaries.
        // Strings stored in entries/summary fields remain owned by Swift values.
        autoreleasepool { consumeRecord(data, line: line, isFinalLine: isFinalLine) }
    }

    private mutating func consumeRecord(_ data: Data, line: Int, isFinalLine: Bool) {
        guard !data.isEmpty else { return }
        if data.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { return }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            warn(isFinalLine ? "末行尚未完整写入或格式无效，已保留之前的记录。" : "存在无法解析的 JSONL 记录，已跳过。")
            return
        }
        guard let type = value["type"] as? String else { warn("存在缺少类型的记录，已跳过。"); return }
        let payload = value["payload"] as? [String: Any] ?? [:]
        let subtype = payload["type"] as? String ?? ""
        let timestampString = value["timestamp"] as? String
        let timestamp = date(timestampString)
        switch type {
        case "session_meta":
            if let id = boundedString(payload["id"], limit: 256), !id.isEmpty { sessionID = id }
            projectPath = boundedString(payload["cwd"], limit: 4_096) ?? projectPath
            startedAt = date(payload["timestamp"] as? String) ?? timestamp ?? startedAt
            model = boundedString(payload["model"], limit: 256) ?? model
        case "turn_context":
            model = boundedString(payload["model"], limit: 256) ?? model
            projectPath = boundedString(payload["cwd"], limit: 4_096) ?? projectPath
            currentTurnID = boundedString(payload["turn_id"], limit: 256)
        case "response_item":
            switch subtype {
            case "message":
                let role = payload["role"] as? String ?? ""
                let kind: SessionMessageKind = role == "user" ? .user : role == "assistant" ? .assistant : .system
                let text = contentText(payload["content"])
                add(kind: kind, text: text, source: .response, timestamp: timestamp, line: line,
                    itemID: payload["id"] as? String)
            case "function_call", "custom_tool_call":
                let callID = boundedString(payload["call_id"], limit: 512)
                let name = boundedString(payload["name"], limit: 256) ?? "tool"
                if let callID, toolNames.count < limits.maximumMessages { toolNames[callID] = name }
                add(kind: .toolCall, text: retainsMessages ? displayValue(payload["arguments"] ?? payload["input"]) : "", source: .response,
                    timestamp: timestamp, line: line, toolName: name, callID: callID, itemID: payload["id"] as? String)
            case "function_call_output", "custom_tool_call_output":
                let callID = boundedString(payload["call_id"], limit: 512)
                add(kind: .toolResult, text: retainsMessages ? displayValue(payload["output"]) : "", source: .response,
                    timestamp: timestamp, line: line, toolName: callID.flatMap { toolNames[$0] }, callID: callID,
                    itemID: payload["id"] as? String)
            case "web_search_call":
                let callID = boundedString(payload["id"], limit: 512)
                if let callID, toolNames.count < limits.maximumMessages { toolNames[callID] = "web_search" }
                add(kind: .toolCall, text: retainsMessages ? displayValue(payload["action"]) : "", source: .response,
                    timestamp: timestamp, line: line, toolName: "web_search", callID: callID,
                    itemID: payload["id"] as? String)
            case "reasoning":
                // Only recorded plaintext summaries are displayed. encrypted_content
                // is intentionally never read, decoded, or treated as token usage.
                let text = contentText(payload["summary"])
                if !text.isEmpty {
                    add(kind: .reasoning, text: text, source: .response, timestamp: timestamp, line: line,
                        itemID: payload["id"] as? String)
                }
            default: break
            }
        case "event_msg":
            switch subtype {
            case "user_message", "agent_message", "agent_reasoning":
                let kind: SessionMessageKind = subtype == "user_message" ? .user : subtype == "agent_message" ? .assistant : .reasoning
                add(kind: kind, text: payload["message"] as? String ?? payload["text"] as? String ?? "",
                    source: .event, timestamp: timestamp, line: line, itemID: payload["id"] as? String)
            case "item_completed":
                guard let item = payload["item"] as? [String: Any] else { return }
                switch item["type"] as? String {
                case "UserMessage":
                    add(kind: .user, text: contentText(item["content"]), source: .event, timestamp: timestamp,
                        line: line, itemID: item["id"] as? String)
                case "AgentMessage":
                    add(kind: .assistant, text: contentText(item["content"]), source: .event, timestamp: timestamp,
                        line: line, itemID: item["id"] as? String)
                case "Plan", "plan":
                    add(kind: .assistant, text: item["text"] as? String ?? "", source: .event, timestamp: timestamp, line: line)
                default: break
                }
            case "thread_name_updated":
                if let title = boundedString(payload["thread_name"], limit: 140), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    renamedTitle = title
                }
            case "token_count": consumeUsage(payload, timestampString: timestampString)
            default: break
            }
        case "compacted":
            if let text = payload["message"] as? String {
                add(kind: .system, text: text, source: .response, timestamp: timestamp, line: line)
                warn("日志包含上下文压缩；当前文件不保证保留完整的原始对话。")
            }
        default: break
        }
    }

    mutating func finish() -> SessionTranscript {
        if sessionID == nil { warn("缺少有效 session_meta；使用文件名作为会话标识。") }
        // Results can precede their corresponding recorded call in older exports.
        let messages = retainsMessages ? entries.map { entry -> SessionMessage in
            let message = entry.message
            return SessionMessage(id: message.id, timestamp: message.timestamp, kind: message.kind, text: message.text,
                                  toolName: message.toolName ?? message.callID.flatMap { toolNames[$0] }, callID: message.callID)
        } : []
        for entry in entries { recordSummary(of: entry.message) }
        let title = renamedTitle ?? firstUserTitle ?? "未命名 Codex 会话"
        let identifier = sessionID ?? fileURL.deletingPathExtension().lastPathComponent
        if searchTruncated { warn("用户提示过多，搜索索引只保留有界的前段内容。") }
        var tokens: CodexTokenUsage
        if let cumulative = latestCumulative { tokens = cumulative }
        else if !incremental.isEmpty, !incrementalMissingIdentity {
            tokens = .aggregate(Array(incremental.values))
            warn("未记录累计 Token；此处按有时间标识的 last_token_usage 去重累加，不能保证完整。")
        } else {
            tokens = .init()
            if incrementalMissingIdentity { warn("仅有缺少时间标识的增量 Token，无法可靠去重；累计用量未知。") }
        }
        let summary = CodexSessionSummary(id: fileURL.standardizedFileURL.path, sessionID: identifier,
                                         fileURL: fileURL, title: title, projectPath: projectPath,
                                         startedAt: startedAt ?? firstMessageTimestamp,
                                         updatedAt: fileUpdatedAt, model: model,
                                         messageCount: messageCount,
                                         toolCallCount: toolCallCount,
                                         tokens: tokens, isArchived: isArchived, searchText: searchText)
        return SessionTranscript(summary: summary, messages: messages, warnings: warnings)
    }

    private mutating func add(kind: SessionMessageKind, text raw: String, source: Source, timestamp: Date?, line: Int,
                              toolName: String? = nil, callID: String? = nil, itemID: String? = nil) {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind == .toolCall || kind == .toolResult else { return }
        let text = String(raw.prefix(64 * 1_024))
        if text.count < raw.count { warn("部分消息超过 64 KiB 字符展示上限，已截断展示。") }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKind = kind == .user && isInjectedContext(normalized) ? .system : kind
        let safeItemID = itemID.map { String($0.prefix(512)) }
        if let safeItemID, !safeItemID.isEmpty {
            if knownItemIDs.contains("\(source.rawValue):\(safeItemID)") { return }
            if knownItemIDs.count < limits.maximumMessages {
                knownItemIDs.insert("\(source.rawValue):\(safeItemID)")
            }
        }
        if effectiveKind == .user || effectiveKind == .assistant || effectiveKind == .reasoning {
            // Only pair opposite representations near one another. Identical prompts
            // sent in separate turns must remain separate messages.
            let lower = max(0, entries.count - 24)
            for index in (lower..<entries.count).reversed() {
                let prior = entries[index]
                guard !prior.paired, prior.source != source, prior.message.kind == effectiveKind, line - prior.line <= 24 else { continue }
                if let priorTurn = prior.turnID, let currentTurnID, priorTurn != currentTurnID { continue }
                if let oldDate = prior.message.timestamp, let timestamp, abs(oldDate.timeIntervalSince(timestamp)) > 5 { continue }
                let sameID = safeItemID != nil && safeItemID == prior.itemID
                if sameID || prior.message.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized {
                    let chosen = source == .event
                        ? SessionMessage(id: prior.message.id, timestamp: timestamp ?? prior.message.timestamp, kind: effectiveKind, text: text)
                        : prior.message
                    entries[index] = Entry(message: chosen, source: source == .event ? source : prior.source,
                                           line: prior.line, itemID: safeItemID ?? prior.itemID, paired: true,
                                           turnID: currentTurnID ?? prior.turnID)
                    return
                }
            }
        }
        guard acceptedEntryCount < limits.maximumMessages else {
            warn("消息达到 \(limits.maximumMessages) 条展示上限；后续消息省略，仍读取有界范围内的 Token 记录。")
            return
        }
        entries.append(Entry(message: SessionMessage(id: "\(fileURL.path)#\(line)", timestamp: timestamp,
                                                      kind: effectiveKind, text: text, toolName: toolName, callID: callID),
                             source: source, line: line, itemID: safeItemID, paired: false, turnID: currentTurnID))
        acceptedEntryCount += 1
        // Only the last 24 accepted entries can participate in mirror pairing.
        // Catalog mode finalizes older entries into bounded summary fields rather
        // than retaining every assistant/tool body until the file finishes.
        if !retainsMessages, entries.count > 24 {
            recordSummary(of: entries.removeFirst().message)
        }
    }

    private mutating func recordSummary(of message: SessionMessage) {
        if firstMessageTimestamp == nil { firstMessageTimestamp = message.timestamp }
        if message.kind == .user || message.kind == .assistant { messageCount += 1 }
        if message.kind == .toolCall { toolCallCount += 1 }
        guard message.kind == .user, !isInjectedContext(message.text) else { return }
        if firstUserTitle == nil { firstUserTitle = cleanTitle(message.text) }
        let remaining = limits.maximumSearchCharacters - searchCharacters
        guard remaining > 0 else { searchTruncated = true; return }
        let retained = String(message.text.prefix(remaining))
        let retainedCount = retained.count
        searchText += retained
        searchCharacters += retainedCount
        if retainedCount < message.text.count { searchTruncated = true }
        if retainedCount < remaining { searchText += "\n"; searchCharacters += 1 }
    }

    private mutating func consumeUsage(_ payload: [String: Any], timestampString: String?) {
        guard let info = payload["info"] as? [String: Any] else { return }
        if let dictionary = info["total_token_usage"] as? [String: Any] {
            let value = usage(dictionary)
            if value.hasRecordedUsage {
                if let oldTotal = latestCumulative?.effectiveTotal, let newTotal = value.effectiveTotal, newTotal < oldTotal {
                    warn("累计 Token 在日志中发生重置；显示最后一次累计值，不能视为跨重置的完整总量。")
                }
                latestCumulative = value
            }
            if value.hasRecordedUsage { return }
        }
        guard let dictionary = info["last_token_usage"] as? [String: Any] else { return }
        let value = usage(dictionary)
        guard value.hasRecordedUsage else { return }
        guard let timestampString, date(timestampString) != nil else { incrementalMissingIdentity = true; return }
        let identity = [timestampString, currentTurnID ?? "", payload["request_id"] as? String ?? ""].joined(separator: "|")
        guard incremental.count < limits.maximumMessages || incremental[identity] != nil else {
            incrementalMissingIdentity = true; warn("增量 Token 事件超过索引上限，累计用量未知。"); return
        }
        if let prior = incremental[identity], prior != value {
            incrementalMissingIdentity = true
            warn("同一时间标识存在冲突的增量 Token，累计用量未知。")
        }
        incremental[identity] = value
    }

    private mutating func usage(_ dictionary: [String: Any]) -> CodexTokenUsage {
        func count(_ key: String) -> Int? {
            guard let number = dictionary[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = Int(number.stringValue), value >= 0 else { return nil }
            return value
        }
        let input = count("input_tokens"), output = count("output_tokens")
        var cached = count("cached_input_tokens"), reasoning = count("reasoning_output_tokens")
        if let input, let value = cached, value > input { cached = nil; warn("缓存 Token 大于输入 Token，该异常子项已忽略。") }
        if let output, let value = reasoning, value > output { reasoning = nil; warn("推理 Token 大于输出 Token，该异常子项已忽略。") }
        let keys = ["input_tokens", "output_tokens", "cached_input_tokens", "reasoning_output_tokens", "total_tokens"]
        if keys.contains(where: { dictionary[$0] != nil && count($0) == nil }) { warn("存在无效 Token 数值；未知字段不会按零计算。") }
        return CodexTokenUsage(input: input, cachedInput: cached, output: output, reasoningOutput: reasoning, total: count("total_tokens"))
    }

    private func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let value = Self.utcDate(text) { return value }
        if let value = dateFormatter.date(from: text) { return value }
        return fallbackDateFormatter.date(from: text)
    }

    /// The UTC RFC3339 form emitted by Codex is much cheaper to decode directly
    /// than running an ICU formatter for every JSONL record. Other valid ISO8601
    /// forms keep their existing formatter path.
    private static func utcDate(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20, bytes.count <= 30, bytes.last == 90,
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58 else { return nil }
        func number(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for byte in bytes[start..<(start + count)] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard let year = number(0, 4), year > 0, let month = number(5, 2), (1...12).contains(month),
              let day = number(8, 2), let hour = number(11, 2), hour < 24,
              let minute = number(14, 2), minute < 60, let second = number(17, 2), second < 60 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day > 0, day <= monthDays[month - 1] else { return nil }
        var fraction = 0.0
        if bytes.count > 20 {
            guard bytes[19] == 46, bytes.count >= 22,
                  let digits = number(20, bytes.count - 21) else { return nil }
            fraction = Double(digits) / pow(10.0, Double(bytes.count - 21))
        }
        var calendar = tm()
        calendar.tm_year = Int32(year - 1900); calendar.tm_mon = Int32(month - 1); calendar.tm_mday = Int32(day)
        calendar.tm_hour = Int32(hour); calendar.tm_min = Int32(minute); calendar.tm_sec = Int32(second)
        return Date(timeIntervalSince1970: Double(timegm(&calendar)) + fraction)
    }

    private func boundedString(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }

    private func contentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let parts = value as? [[String: Any]] else { return "" }
        let known = ["input_text", "output_text", "text", "Text", "summary_text"]
        return parts.compactMap { item in
            guard known.contains(item["type"] as? String ?? "") else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
    }

    private func displayValue(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        if let values = value as? [[String: Any]] {
            let text = contentText(values)
            if !text.isEmpty { return text }
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[无文本输出]" }
        return text
    }

    private func isInjectedContext(_ text: String) -> Bool {
        let prefixes = ["# AGENTS.md instructions", "<environment_context>", "<permissions instructions>",
                        "<collaboration_mode>", "<system_reminder>", "<developer_instructions>"]
        return prefixes.contains { text.hasPrefix($0) }
    }

    private func cleanTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
    }

    private enum Source: String { case response, event }
    private struct Entry {
        let message: SessionMessage; let source: Source; let line: Int; let itemID: String?; let paired: Bool; let turnID: String?
    }
}
