import Foundation

/// Summary-only aggregation. Recorded token totals describe whole sessions, not daily spend.
public struct SessionAnalytics: Equatable, Sendable {
    public let projects: [SessionProjectSummary]
    public let models: [SessionModelSummary]
    public let activity: [SessionActivityPoint]
    /// A lower bound from available recorded counters; missing values are never estimated.
    public let tokens: CodexTokenUsage
    /// Sessions with a known or safely derivable total, including a recorded zero.
    public let sessionsWithUsage: Int
    public let totalSessionCount: Int
    public let missingStartDateCount: Int
    public let activityWindowExcludedSessionCount: Int
    public let hasTokenOverflow: Bool

    /// The activity window ends at the most recent recorded session start in the input.
    /// Filtering by archive state, project, or text belongs to the caller.
    public init(sessions: [CodexSessionSummary], activityDayLimit: Int = 30) {
        var projectGroups: [String: ProjectAccumulator] = [:]
        var modelGroups: [String: ModelAccumulator] = [:]
        var usage = CodexTokenUsageAccumulator()
        var sessionsWithUsage = 0
        var missingStartDateCount = 0
        var dates: [Date: Int] = [:]
        let calendar = Self.activityCalendar

        for session in sessions {
            usage.add(session.tokens)
            if session.tokens.effectiveTotal != nil { sessionsWithUsage += 1 }
            let path = Self.nonempty(session.projectPath)
            let projectID = path ?? SessionProjectSummary.unknownID
            projectGroups[projectID, default: ProjectAccumulator(path: path)].add(session)

            let modelName = Self.nonempty(session.model)
            let modelID = modelName.map { "model:\($0)" } ?? SessionModelSummary.unknownID
            modelGroups[modelID, default: ModelAccumulator(name: modelName)].add(session)

            if let startedAt = session.startedAt, startedAt.timeIntervalSinceReferenceDate.isFinite {
                let day = calendar.startOfDay(for: startedAt)
                dates[day, default: 0] += 1
            } else {
                missingStartDateCount += 1
            }
        }

        projects = projectGroups.values.map(\.summary).sorted {
            if $0.lastActivity != $1.lastActivity {
                return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
            }
            return $0.id < $1.id
        }
        models = modelGroups.values.map(\.summary).sorted {
            if $0.sessionCount != $1.sessionCount { return $0.sessionCount > $1.sessionCount }
            return $0.id < $1.id
        }
        tokens = usage.value
        hasTokenOverflow = usage.hasOverflow
        self.sessionsWithUsage = sessionsWithUsage
        totalSessionCount = sessions.count
        self.missingStartDateCount = missingStartDateCount

        var points: [SessionActivityPoint] = []
        if let lastDay = dates.keys.max(), let firstRecordedDay = dates.keys.min() {
            // Bound output even when an arbitrary limit is supplied.
            let limit = min(366, max(1, activityDayLimit))
            let firstAllowed = calendar.date(byAdding: .day, value: -(limit - 1), to: lastDay) ?? lastDay
            var day = max(firstAllowed, firstRecordedDay)
            while day <= lastDay {
                points.append(.init(id: Self.dayID(day, calendar: calendar), date: day,
                                    sessionCount: dates[day, default: 0]))
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        }
        activity = points
        activityWindowExcludedSessionCount = sessions.count - missingStartDateCount - points.reduce(0) { $0 + $1.sessionCount }
    }

    private static var activityCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static func dayID(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    fileprivate static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

public struct SessionProjectSummary: Identifiable, Equatable, Sendable {
    /// NUL is invalid in a filesystem path, so a real project can never collide with this group.
    public static let unknownID = "\u{0}unknown-project"
    public let id: String
    public let projectPath: String?
    public let displayName: String
    public let sessionCount: Int
    public let messageCount: Int
    public let toolCallCount: Int
    public let tokens: CodexTokenUsage
    /// Sessions whose effective total is unknown, even when one component was recorded.
    public let missingUsageSessionCount: Int
    public let lastActivity: Date?
    /// Distinct recorded model names; the unknown model group is excluded.
    public let modelCount: Int
    public let hasTokenOverflow: Bool
}

public struct SessionModelSummary: Identifiable, Equatable, Sendable {
    public static let unknownID = "\u{0}unknown-model"
    public let id: String
    public let name: String
    public let sessionCount: Int
    public let tokens: CodexTokenUsage
    /// Sessions whose effective total is unknown, even when one component was recorded.
    public let missingUsageSessionCount: Int
    public let hasTokenOverflow: Bool
}

public struct SessionActivityPoint: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    /// Sessions that started on this date in Asia/Shanghai. This is not token usage by day.
    public let sessionCount: Int
}

private struct ProjectAccumulator {
    let path: String?
    var count = 0
    var messageCount = 0
    var toolCallCount = 0
    var missingUsageCount = 0
    var latest: Date?
    var modelNames: Set<String> = []
    var usage = CodexTokenUsageAccumulator()

    mutating func add(_ session: CodexSessionSummary) {
        count += 1
        messageCount = saturatedAdd(messageCount, max(0, session.messageCount))
        toolCallCount = saturatedAdd(toolCallCount, max(0, session.toolCallCount))
        usage.add(session.tokens)
        if session.tokens.effectiveTotal == nil { missingUsageCount += 1 }
        if session.updatedAt.timeIntervalSinceReferenceDate.isFinite {
            latest = latest.map { max($0, session.updatedAt) } ?? session.updatedAt
        }
        if let name = SessionAnalytics.nonempty(session.model) { modelNames.insert(name) }
    }

    var summary: SessionProjectSummary {
        let displayName = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未知项目"
        return .init(id: path ?? SessionProjectSummary.unknownID, projectPath: path,
                     displayName: displayName.isEmpty ? (path ?? "未知项目") : displayName,
                     sessionCount: count, messageCount: messageCount, toolCallCount: toolCallCount,
                     tokens: usage.value, missingUsageSessionCount: missingUsageCount,
                     lastActivity: latest, modelCount: modelNames.count, hasTokenOverflow: usage.hasOverflow)
    }
}

private struct ModelAccumulator {
    let name: String?
    var count = 0
    var missingUsageCount = 0
    var usage = CodexTokenUsageAccumulator()

    mutating func add(_ session: CodexSessionSummary) {
        count += 1
        usage.add(session.tokens)
        if session.tokens.effectiveTotal == nil { missingUsageCount += 1 }
    }

    var summary: SessionModelSummary {
        .init(id: name.map { "model:\($0)" } ?? SessionModelSummary.unknownID,
              name: name ?? "未知模型", sessionCount: count, tokens: usage.value,
              missingUsageSessionCount: missingUsageCount, hasTokenOverflow: usage.hasOverflow)
    }
}

private func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? .max : result.partialValue
}
