//
//  AISummaryRecord.swift
//  Starcat
//
//  单仓 AI 智能化结果缓存模型。
//
//  模块职责：
//  - 对应 `ai_summaries` 表，缓存某个 repo 在某个 chat model 下生成的结构化 JSON。
//  - 保存 `source_hash`，用于判断 repo 元数据 / README 变化后缓存是否仍可复用。
//
//  关键约束：
//  - AI 输出只作为建议缓存，不直接修改 tags / notes / status。
//  - 用户确认标签后才写入 `tags` / `repo_tags` 表，避免 AI 自动污染用户数据。
//

import Foundation
import GRDB

struct AISummaryRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {

    static let databaseTableName = "ai_summaries"

    var repoId: Int64
    var model: String
    var sourceHash: String
    var summaryJson: String
    var generatedAt: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case model
        case sourceHash = "source_hash"
        case summaryJson = "summary_json"
        case generatedAt = "generated_at"
    }
}
