//
//  RepoHealthSnapshot.swift
//  Starcat
//
//  Repo Health 本地缓存记录。
//
//  设计约束：
//  - 健康度是派生缓存，不是用户数据；可以随 repo 缓存重建。
//  - 第一版只服务已 star repo，repo 删除时通过外键 cascade 清理。
//  - payload_json 保存维度证据，UI 解释分数时不需要重新计算。
//

import Foundation
import GRDB

/// Repo Health 计算状态。
enum RepoHealthFetchStatus: String, Codable, Sendable, CaseIterable {
    case success
    case partial
    case failed
}

/// `repo_health_snapshots` 表行映射。
struct RepoHealthSnapshot: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    static let databaseTableName = "repo_health_snapshots"

    var repoId: Int64
    var overallScore: Double
    var grade: String
    var maintenanceScore: Double
    var popularityScore: Double
    var qualityScore: Double
    var securityScore: Double
    var payloadJSON: String
    var computedAt: String
    var staleAfter: String
    var fetchStatus: RepoHealthFetchStatus
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case overallScore = "overall_score"
        case grade
        case maintenanceScore = "maintenance_score"
        case popularityScore = "popularity_score"
        case qualityScore = "quality_score"
        case securityScore = "security_score"
        case payloadJSON = "payload_json"
        case computedAt = "computed_at"
        case staleAfter = "stale_after"
        case fetchStatus = "fetch_status"
        case lastError = "last_error"
    }

    var staleDate: Date? {
        ISO8601DateFormatter.shared.date(from: staleAfter)
    }

    var computedDate: Date? {
        ISO8601DateFormatter.shared.date(from: computedAt)
    }

    var badgeData: RepoHealthBadgeData? {
        guard fetchStatus != .failed else { return nil }
        return RepoHealthBadgeData(score: overallScore, grade: grade)
    }
}

/// 详情页与列表共用的小型健康度视图数据。
struct RepoHealthBadgeData: Hashable, Sendable {
    let score: Double
    let grade: String

    var roundedScore: Int {
        Int(score.rounded())
    }
}
