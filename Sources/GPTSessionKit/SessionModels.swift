import Foundation

/// Recorded counts only. Cached input is included in input; reasoning is included in output.
public struct CodexTokenUsage: Codable, Equatable, Sendable {
    public let input: Int?
    public let cachedInput: Int?
    public let output: Int?
    public let reasoningOutput: Int?
    public let total: Int?
    private let deriveTotalIfMissing: Bool
    fileprivate let aggregationOverflowMask: UInt8

    /// Aggregated counters disable derivation: partial components can come from different sessions.
    public init(input: Int? = nil, cachedInput: Int? = nil, output: Int? = nil,
                reasoningOutput: Int? = nil, total: Int? = nil,
                deriveTotalIfMissing: Bool = true) {
        self.input = input; self.cachedInput = cachedInput; self.output = output
        self.reasoningOutput = reasoningOutput; self.total = total
        self.deriveTotalIfMissing = deriveTotalIfMissing
        aggregationOverflowMask = 0
    }

    fileprivate init(aggregatedInput: Int?, cachedInput: Int?, output: Int?,
                     reasoningOutput: Int?, total: Int?, overflowMask: UInt8) {
        input = aggregatedInput; self.cachedInput = cachedInput; self.output = output
        self.reasoningOutput = reasoningOutput; self.total = total
        deriveTotalIfMissing = false
        aggregationOverflowMask = overflowMask
    }

    public var hasRecordedUsage: Bool {
        [input, cachedInput, output, reasoningOutput, total].contains { $0 != nil }
    }

    /// The provider's total takes precedence. Never add subset counters twice.
    public var effectiveTotal: Int? {
        if let total { return total >= 0 ? total : nil }
        guard deriveTotalIfMissing else { return nil }
        guard let input, let output, input >= 0, output >= 0 else { return nil }
        let sum = input.addingReportingOverflow(output)
        return sum.overflow ? nil : sum.partialValue
    }

    /// A nil field may mean either no record or an arithmetic overflow. Consumers
    /// that aggregate these values must preserve that distinction across layers.
    public func hasOverflow(for keyPath: KeyPath<CodexTokenUsage, Int?>) -> Bool {
        let mask: UInt8
        switch keyPath {
        case \.input: mask = 1
        case \.cachedInput: mask = 2
        case \.output: mask = 4
        case \.reasoningOutput: mask = 8
        case \.total: mask = 16
        case \.effectiveTotal:
            if aggregationOverflowMask & 16 != 0 { return true }
            guard total == nil, deriveTotalIfMissing, let input, let output,
                  input >= 0, output >= 0 else { return false }
            return input.addingReportingOverflow(output).overflow
        default: return false
        }
        return aggregationOverflowMask & mask != 0
    }

    public static func aggregate(_ values: [CodexTokenUsage]) -> CodexTokenUsage {
        var accumulator = CodexTokenUsageAccumulator()
        for value in values { accumulator.add(value) }
        return accumulator.value
    }
}

/// Keep each known field while preventing aggregate input/output from inventing a missing total.
internal struct CodexTokenUsageAccumulator {
    private var input = CheckedTokenCount()
    private var cachedInput = CheckedTokenCount()
    private var output = CheckedTokenCount()
    private var reasoning = CheckedTokenCount()
    private var total = CheckedTokenCount()

    mutating func add(_ usage: CodexTokenUsage) {
        // The parser can aggregate incremental records before catalog/project aggregation.
        // Preserve each overflow through those layers rather than replacing it with a later value.
        if usage.aggregationOverflowMask & 1 != 0 { input.markOverflow() }
        if usage.aggregationOverflowMask & 2 != 0 { cachedInput.markOverflow() }
        if usage.aggregationOverflowMask & 4 != 0 { output.markOverflow() }
        if usage.aggregationOverflowMask & 8 != 0 { reasoning.markOverflow() }
        if usage.aggregationOverflowMask & 16 != 0 { total.markOverflow() }
        input.add(usage.input)
        cachedInput.add(usage.cachedInput)
        output.add(usage.output)
        reasoning.add(usage.reasoningOutput)
        total.add(usage.effectiveTotal)
        if usage.total == nil, let input = usage.input, let output = usage.output,
           input >= 0, output >= 0, input.addingReportingOverflow(output).overflow {
            total.markOverflow()
        }
    }

    var hasOverflow: Bool {
        input.overflowed || cachedInput.overflowed || output.overflowed || reasoning.overflowed || total.overflowed
    }

    var value: CodexTokenUsage {
        var mask: UInt8 = 0
        if input.overflowed { mask |= 1 }
        if cachedInput.overflowed { mask |= 2 }
        if output.overflowed { mask |= 4 }
        if reasoning.overflowed { mask |= 8 }
        if total.overflowed { mask |= 16 }
        return .init(aggregatedInput: input.total, cachedInput: cachedInput.total, output: output.total,
                     reasoningOutput: reasoning.total, total: total.total, overflowMask: mask)
    }
}

private struct CheckedTokenCount {
    var total: Int?
    var overflowed = false

    mutating func add(_ count: Int?) {
        guard let count, count >= 0, !overflowed else { return }
        let sum = (total ?? 0).addingReportingOverflow(count)
        if sum.overflow { markOverflow() }
        else { total = sum.partialValue }
    }

    mutating func markOverflow() { total = nil; overflowed = true }
}

public struct CodexSessionSummary: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    /// Absent when the parser had to fall back to a file name. Management uses
    /// a real recorded ID across archive moves, and a path for unidentified logs.
    public let metadataSessionID: String?
    public let fileURL: URL
    public let title: String
    public let projectPath: String?
    public let startedAt: Date?
    public let updatedAt: Date
    public let model: String?
    public let messageCount: Int
    public let toolCallCount: Int
    public let tokens: CodexTokenUsage
    public let isArchived: Bool
    public let searchText: String

    public var managementID: String {
        if let metadataSessionID { return "session:\(metadataSessionID)" }
        return "file:\(fileURL.standardizedFileURL.path)"
    }

    public init(id: String, sessionID: String, fileURL: URL, title: String,
                projectPath: String? = nil, startedAt: Date? = nil, updatedAt: Date = Date(),
                model: String? = nil, messageCount: Int = 0, toolCallCount: Int = 0,
                tokens: CodexTokenUsage = .init(), isArchived: Bool = false, searchText: String = "",
                metadataSessionID: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.fileURL = fileURL; self.title = title
        self.metadataSessionID = metadataSessionID
        self.projectPath = projectPath; self.startedAt = startedAt; self.updatedAt = updatedAt
        self.model = model; self.messageCount = messageCount; self.toolCallCount = toolCallCount
        self.tokens = tokens; self.isArchived = isArchived; self.searchText = searchText
    }

    public func matches(query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        // Terms cannot contain newlines, so searching individual fields preserves
        // semantics without copying the potentially 64 KiB prompt index per keypress.
        return terms.allSatisfy { term in
            let value = String(term)
            return title.localizedCaseInsensitiveContains(value)
                || (projectPath?.localizedCaseInsensitiveContains(value) ?? false)
                || sessionID.localizedCaseInsensitiveContains(value)
                || searchText.localizedCaseInsensitiveContains(value)
        }
    }
}

public struct SessionCatalog: Equatable, Sendable {
    public let sessions: [CodexSessionSummary]
    public let warnings: [String]
    public init(sessions: [CodexSessionSummary] = [], warnings: [String] = []) {
        self.sessions = sessions; self.warnings = warnings
    }
    /// A sum of the available recorded fields; missing session usage remains unknown.
    public var aggregateTokens: CodexTokenUsage { .aggregate(sessions.map(\.tokens)) }
    public var sessionsWithRecordedUsage: Int { sessions.filter { $0.tokens.hasRecordedUsage }.count }
}

public enum SessionMessageKind: String, CaseIterable, Sendable {
    case user, assistant, toolCall, toolResult, reasoning, system, other
}

public struct SessionMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date?
    public let kind: SessionMessageKind
    public let text: String
    public let toolName: String?
    public let callID: String?
    public init(id: String, timestamp: Date? = nil, kind: SessionMessageKind, text: String,
                toolName: String? = nil, callID: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.kind = kind; self.text = text
        self.toolName = toolName; self.callID = callID
    }
}

public struct SessionTranscript: Equatable, Sendable {
    public let summary: CodexSessionSummary
    public let messages: [SessionMessage]
    public let warnings: [String]
    public init(summary: CodexSessionSummary, messages: [SessionMessage] = [], warnings: [String] = []) {
        self.summary = summary; self.messages = messages; self.warnings = warnings
    }
}

/// A source boundary for future Claude/other local transcript adapters.
public protocol SessionRepository: Sendable {
    func loadCatalog() throws -> SessionCatalog
    func loadTranscript(for summary: CodexSessionSummary) throws -> SessionTranscript
}

public struct SessionReadLimits: Sendable {
    public var maximumFiles: Int
    public var maximumScanEntries: Int
    public var maximumFileBytes: Int
    public var maximumLineBytes: Int
    public var maximumMessages: Int
    public var maximumCatalogReadBytes: Int
    public var maximumSearchCharacters: Int
    public var maximumCachedTranscripts: Int
    public var maximumCachedTranscriptBytes: Int
    public init(maximumFiles: Int = 2_000, maximumScanEntries: Int = 20_000,
                maximumFileBytes: Int = 32 * 1_024 * 1_024, maximumLineBytes: Int = 1_024 * 1_024,
                maximumMessages: Int = 10_000, maximumCatalogReadBytes: Int = 128 * 1_024 * 1_024,
                maximumSearchCharacters: Int = 64 * 1_024, maximumCachedTranscripts: Int = 3,
                maximumCachedTranscriptBytes: Int = 8 * 1_024 * 1_024) {
        self.maximumFiles = max(1, maximumFiles); self.maximumScanEntries = max(1, maximumScanEntries)
        self.maximumFileBytes = max(1, maximumFileBytes); self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumMessages = max(1, maximumMessages); self.maximumCatalogReadBytes = max(1, maximumCatalogReadBytes)
        self.maximumSearchCharacters = max(1, maximumSearchCharacters)
        self.maximumCachedTranscripts = max(0, maximumCachedTranscripts)
        self.maximumCachedTranscriptBytes = max(0, maximumCachedTranscriptBytes)
    }
}

/// Diagnostics count bytes returned by local file reads, including EOF probes.
/// They contain no paths or conversation content and are useful for verifying
/// that a refresh or repeated detail open is actually served by the bounded cache.
public struct SessionReadMetrics: Equatable, Sendable {
    public var rolloutBytesRead = 0
    public var titleIndexBytesRead = 0
    public var parsedRolloutFiles = 0
    public var cachedRolloutFiles = 0
    /// Summary hits hydrated from the optional private on-disk index during this read.
    public var persistedRolloutFiles = 0
    public init() {}
}
