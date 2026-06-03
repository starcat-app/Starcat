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
}

struct GRDBAISummaryRepository: AISummaryRepositoryProtocol {

    private let writer: any DatabaseWriter

    init(database: any DatabaseManaging) {
        self.writer = database.writer
    }

    func find(repoId: Int64, model: String) async throws -> AISummaryRecord? {
        try await writer.read { db in
            try AISummaryRecord.fetchOne(db, sql: """
                SELECT * FROM ai_summaries
                WHERE repo_id = ? AND model = ?
                """, arguments: [repoId, model])
        }
    }

    func upsert(_ record: AISummaryRecord) async throws {
        try await writer.write { db in
            var copy = record
            try copy.save(db)
        }
    }
}
