//
//  ReadmePrefetchStateRecord.swift
//  Starcat
//
//  README 后台预拉调度状态，对应 `readme_prefetch_states` 表。
//
//  模块级说明：
//  - 本表只记录后台任务的调度状态、失败冷却和最后错误类别；
//  - README 正文仍由 `readmes` 与 `readme_contents` 管理，避免调度状态污染缓存正文模型；
//  - 404 / 网络失败必须持久化冷却，否则后台任务会在每轮重复请求同一个失败仓库。
//

import Foundation
import GRDB

/// README 预拉单个子任务的持久化状态。
enum ReadmePrefetchContentStatus: String, Codable, Sendable {
    case pending
    case succeeded
    case notFound
    case failed
    case skipped
}

/// README 预拉调度状态记录。
///
/// `htmlStatus` 和 `markdownStatus` 分开存，是因为 HTML 是详情页显示主路径，
/// Markdown 是 AI / 搜索纯文本消费路径；二者可能独立成功或失败。
struct ReadmePrefetchStateRecord: FetchableRecord, MutablePersistableRecord, Equatable, Sendable {

    static let databaseTableName = "readme_prefetch_states"

    var repoId: Int64
    var htmlStatus: ReadmePrefetchContentStatus
    var markdownStatus: ReadmePrefetchContentStatus
    var lastAttemptAt: String?
    var nextRetryAt: String?
    var failureCount: Int
    var lastErrorKind: String?

    init(
        repoId: Int64,
        htmlStatus: ReadmePrefetchContentStatus,
        markdownStatus: ReadmePrefetchContentStatus,
        lastAttemptAt: String?,
        nextRetryAt: String?,
        failureCount: Int,
        lastErrorKind: String?
    ) {
        self.repoId = repoId
        self.htmlStatus = htmlStatus
        self.markdownStatus = markdownStatus
        self.lastAttemptAt = lastAttemptAt
        self.nextRetryAt = nextRetryAt
        self.failureCount = failureCount
        self.lastErrorKind = lastErrorKind
    }

    init(row: Row) {
        repoId = row["repo_id"]
        htmlStatus = ReadmePrefetchContentStatus(rawValue: row["html_status"] as String) ?? .pending
        markdownStatus = ReadmePrefetchContentStatus(rawValue: row["markdown_status"] as String) ?? .pending
        lastAttemptAt = row["last_attempt_at"]
        nextRetryAt = row["next_retry_at"]
        failureCount = row["failure_count"]
        lastErrorKind = row["last_error_kind"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["repo_id"] = repoId
        container["html_status"] = htmlStatus.rawValue
        container["markdown_status"] = markdownStatus.rawValue
        container["last_attempt_at"] = lastAttemptAt
        container["next_retry_at"] = nextRetryAt
        container["failure_count"] = failureCount
        container["last_error_kind"] = lastErrorKind
    }
}
