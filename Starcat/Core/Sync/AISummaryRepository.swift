//
//  AISummaryRepository.swift
//  Starcat
//
//  单仓 AI 智能化缓存 Repository。
//
//  模块职责：
//  - 读写 `ai_summaries` 表；
//  - 按 `(repo_id, model)` 保存最新 AI 分析结果；
//  - 由上层用 `source_hash` 判断缓存是否仍匹配当前 repo 上下文。
//
//  关键约束：
//  - 本仓库只保存 AI 输出 JSON，不解释 JSON 内容；
//  - 不负责标签落库，标签确认流由 AI Insight ViewModel 显式调用标签仓库。
//

import Foundation
import GRDB

protocol AISummaryRepositoryProtocol: Sendable {
    func find(repoId: Int64, model: String) async throws -> AISummaryRecord?
    func upsert(_ record: AISummaryRecord) async throws

    /// 批量返回每个 repo 最新生成的一条 AI 摘要记录。
    ///
    /// 同一 repo 可能因用户切换过 (provider+model) 组合而存在多条 (repo_id, model) 记录；
    /// 导出 / 分享场景下不希望强绑当前 `cacheModelKey()`，否则用户切换模型后旧摘要无法导出。
    /// 这里按 `generated_at` 倒序取每个 repo 第一条命中即返回（一次表扫，离线表通常 < 几千条，O(N) 可接受）。
    ///
    /// 返回 dict：repoId → 该 repo 最近一次生成的 `AISummaryRecord`。无摘要的 repo 不在 dict 中。
    func fetchLatestPerRepo() async throws -> [Int64: AISummaryRecord]
}

struct GRDBAISummaryRepository: AISummaryRepositoryProtocol {

    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func find(repoId: Int64, model: String) async throws -> AISummaryRecord? {
        try await database.writer.read { db in
            try AISummaryRecord.fetchOne(db, sql: """
                SELECT * FROM ai_summaries
                WHERE repo_id = ? AND model = ?
                """, arguments: [repoId, model])
        }
    }

    func upsert(_ record: AISummaryRecord) async throws {
        try await database.writer.write { db in
            var copy = record
            try copy.save(db)
        }
        NotificationCenter.default.post(
            name: .aiSummaryDidChange,
            object: nil,
            userInfo: ["repoId": record.repoId]
        )
    }

    /// 一次性查所有 repo 最新摘要——按 `generated_at DESC` 拉全表，遍历时按 repo_id 去重保留首条。
    /// 不在 SQL 里做 `MAX(generated_at) GROUP BY repo_id` 是因为 SQLite 老版本上 `SELECT *` 配
    /// `GROUP BY` 的字段是 undefined behavior（GROUP BY 行内非聚合字段取值不保证来自 MAX 行）。
    /// 用应用层去重虽然多读几行字符串，但语义更稳。
    func fetchLatestPerRepo() async throws -> [Int64: AISummaryRecord] {
        try await database.writer.read { db in
            let records = try AISummaryRecord.fetchAll(db, sql: """
                SELECT * FROM ai_summaries ORDER BY generated_at DESC
                """)
            var result: [Int64: AISummaryRecord] = [:]
            result.reserveCapacity(records.count)
            for record in records where result[record.repoId] == nil {
                result[record.repoId] = record
            }
            return result
        }
    }
}
