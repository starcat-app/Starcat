//
//  AIUsageStatistics.swift
//  Starcat
//
//  AI 用量面板的筛选条件与只读聚合快照。
//

import Foundation

enum AIUsageTimeRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays = "seven_days"
    case thirtyDays = "thirty_days"
    case all

    var id: String { rawValue }

    func lowerBound(now: Date, calendar: Calendar) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return startOfToday
        case .sevenDays:
            return calendar.date(byAdding: .day, value: -6, to: startOfToday)
        case .thirtyDays:
            return calendar.date(byAdding: .day, value: -29, to: startOfToday)
        case .all:
            return nil
        }
    }
}

struct AIUsageFilter: Equatable, Sendable {
    var timeRange: AIUsageTimeRange = .sevenDays
    var feature: AIUsageFeature?
    var providerID: String?
    var model: String?
}

struct AIUsageSummary: Equatable, Sendable {
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int
    var callCount: Int
    var successfulCallCount: Int
    var callsWithUsage: Int
    var estimatedCostUSD: Double
    var callsWithEstimatedCost: Int
    var embeddingItemCount: Int

    var successRate: Double {
        callCount == 0 ? 0 : Double(successfulCallCount) / Double(callCount)
    }

    var usageAvailabilityRate: Double {
        callCount == 0 ? 0 : Double(callsWithUsage) / Double(callCount)
    }

    var pricingCoverageRate: Double {
        callsWithUsage == 0 ? 0 : Double(callsWithEstimatedCost) / Double(callsWithUsage)
    }

    static let empty = AIUsageSummary(
        totalTokens: 0,
        inputTokens: 0,
        outputTokens: 0,
        callCount: 0,
        successfulCallCount: 0,
        callsWithUsage: 0,
        estimatedCostUSD: 0,
        callsWithEstimatedCost: 0,
        embeddingItemCount: 0
    )
}

struct AIUsageDailyPoint: Equatable, Identifiable, Sendable {
    var day: String
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    var callCount: Int
    var estimatedCostUSD: Double

    var id: String { day }
}

struct AIUsageDimensionPoint: Equatable, Identifiable, Sendable {
    var key: String
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    var callCount: Int
    var estimatedCostUSD: Double

    var id: String { key }
}

struct AIUsageFilterOptions: Equatable, Sendable {
    var providerIDs: [String]
    var models: [String]

    static let empty = AIUsageFilterOptions(providerIDs: [], models: [])
}

struct AIUsageStatisticsSnapshot: Equatable, Sendable {
    var summary: AIUsageSummary
    var daily: [AIUsageDailyPoint]
    var byFeature: [AIUsageDimensionPoint]
    var byProvider: [AIUsageDimensionPoint]
    var byModel: [AIUsageDimensionPoint]
    var recentEvents: [AIUsageEvent]
    var filterOptions: AIUsageFilterOptions

    static let empty = AIUsageStatisticsSnapshot(
        summary: .empty,
        daily: [],
        byFeature: [],
        byProvider: [],
        byModel: [],
        recentEvents: [],
        filterOptions: .empty
    )
}
