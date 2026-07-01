//
//  InitialWarmupJobRecord.swift
//  Starcat
//
//  首次数据预热作业状态，对应 `initial_warmup_jobs` 表。
//
//  模块级说明：
//  - 本表按 GitHub user_id 记录 README 预拉 + OpenSSF + Repo Health 首次计算的可恢复状态；
//  - 不保存 repo 队列，避免缓存清理、同步新增、取消 star 后队列失真；
//  - 所有时间字段使用 ISO8601 字符串，和现有 SQLite 模型保持一致。
//

import Foundation
import GRDB

/// 首次预热作业阶段。
enum InitialWarmupPhase: String, Codable, Sendable {
    case waiting
    case readme
    case openSSF
    case health
    case paused
    case completed
    case disabled
}

/// 首次数据预热作业持久化记录。
struct InitialWarmupJobRecord: FetchableRecord, MutablePersistableRecord, Equatable, Sendable {

    static let databaseTableName = "initial_warmup_jobs"

    var userId: Int64
    var phase: InitialWarmupPhase
    var scheduledAt: String?
    var startedAt: String?
    var completedAt: String?
    var nextRetryAt: String?
    var lastErrorKind: String?
    var readmeCovered: Int
    var readmeTotal: Int
    var healthCovered: Int
    var healthTotal: Int
    var updatedAt: String

    init(
        userId: Int64,
        phase: InitialWarmupPhase,
        scheduledAt: String?,
        startedAt: String?,
        completedAt: String?,
        nextRetryAt: String?,
        lastErrorKind: String?,
        readmeCovered: Int,
        readmeTotal: Int,
        healthCovered: Int,
        healthTotal: Int,
        updatedAt: String
    ) {
        self.userId = userId
        self.phase = phase
        self.scheduledAt = scheduledAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.nextRetryAt = nextRetryAt
        self.lastErrorKind = lastErrorKind
        self.readmeCovered = readmeCovered
        self.readmeTotal = readmeTotal
        self.healthCovered = healthCovered
        self.healthTotal = healthTotal
        self.updatedAt = updatedAt
    }

    init(row: Row) {
        userId = row["user_id"]
        phase = InitialWarmupPhase(rawValue: row["phase"] as String) ?? .waiting
        scheduledAt = row["scheduled_at"]
        startedAt = row["started_at"]
        completedAt = row["completed_at"]
        nextRetryAt = row["next_retry_at"]
        lastErrorKind = row["last_error_kind"]
        readmeCovered = row["readme_covered"]
        readmeTotal = row["readme_total"]
        healthCovered = row["health_covered"]
        healthTotal = row["health_total"]
        updatedAt = row["updated_at"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["user_id"] = userId
        container["phase"] = phase.rawValue
        container["scheduled_at"] = scheduledAt
        container["started_at"] = startedAt
        container["completed_at"] = completedAt
        container["next_retry_at"] = nextRetryAt
        container["last_error_kind"] = lastErrorKind
        container["readme_covered"] = readmeCovered
        container["readme_total"] = readmeTotal
        container["health_covered"] = healthCovered
        container["health_total"] = healthTotal
        container["updated_at"] = updatedAt
    }
}
