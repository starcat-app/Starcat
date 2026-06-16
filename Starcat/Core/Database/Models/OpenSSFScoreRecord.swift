//
//  OpenSSFScoreRecord.swift
//  Starcat
//
//  OpenSSF Scorecard 本地缓存记录。
//
//  设计约束：
//  - 只缓存已 star 仓库的公开安全评分，repo 取消 star 后随 repos 外键 cascade 清理。
//  - fetchedAt 表示“最近一次尝试时间”，成功、404、网络失败、解析失败都会更新；
//    这样失败状态也能进入冷却期，避免详情页或后台任务连续重打同一个端点。
//  - checksJSON 保留 OpenSSF 原始 payload，雷达图当前只消费 checks，但后续 UI
//    要展示 version / commit / documentation 时不需要重新拉历史数据。
//

import Foundation
import GRDB

/// OpenSSF 拉取状态。
enum OpenSSFScoreFetchStatus: String, Codable, Sendable, CaseIterable {
    case success
    case notIndexed
    case networkError
    case parseError
}

/// `open_ssf_scores` 表行映射。
struct OpenSSFScoreRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    static let databaseTableName = "open_ssf_scores"

    var repoId: Int64
    var fetchStatus: OpenSSFScoreFetchStatus
    var aggregateScore: Double?
    var checksJSON: Data?
    var scoreDate: String?
    var fetchedAt: String
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case fetchStatus = "fetch_status"
        case aggregateScore = "aggregate_score"
        case checksJSON = "checks_json"
        case scoreDate = "score_date"
        case fetchedAt = "fetched_at"
        case lastError = "last_error"
    }

    var fetchedDate: Date? {
        ISO8601DateFormatter.shared.date(from: fetchedAt)
    }

    var badgeData: OpenSSFScoreBadgeData? {
        guard fetchStatus == .success, let aggregateScore else { return nil }
        return OpenSSFScoreBadgeData(score: aggregateScore)
    }

    static func success(repoId: Int64, payload: OpenSSFScorePayload, rawData: Data, fetchedAt: Date) -> OpenSSFScoreRecord {
        OpenSSFScoreRecord(
            repoId: repoId,
            fetchStatus: .success,
            aggregateScore: payload.score,
            checksJSON: rawData,
            scoreDate: payload.date,
            fetchedAt: ISO8601DateFormatter.shared.string(from: fetchedAt),
            lastError: nil
        )
    }

    static func failure(
        repoId: Int64,
        status: OpenSSFScoreFetchStatus,
        message: String?,
        fetchedAt: Date
    ) -> OpenSSFScoreRecord {
        OpenSSFScoreRecord(
            repoId: repoId,
            fetchStatus: status,
            aggregateScore: nil,
            checksJSON: nil,
            scoreDate: nil,
            fetchedAt: ISO8601DateFormatter.shared.string(from: fetchedAt),
            lastError: message
        )
    }
}

/// Row / header 共用的小型评分视图数据。
struct OpenSSFScoreBadgeData: Hashable, Sendable {
    let score: Double

    var formattedScore: String {
        String(format: "%.1f", score)
    }
}
