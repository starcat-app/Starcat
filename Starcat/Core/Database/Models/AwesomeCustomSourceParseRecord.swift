//
//  AwesomeCustomSourceParseRecord.swift
//  Starcat
//
//  自定义 Awesome 来源解析进度的 GRDB 行映射。
//
//  source_id 外键级联删除，确保用户移除自定义来源时不会留下孤立进度；进度与来源条目
//  位于同一账户数据库，因此账户切换天然隔离。
//

import Foundation
import GRDB

struct AwesomeCustomSourceParseRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "awesome_custom_source_parse_states"

    var sourceID: String
    var phase: String
    var processedCount: Int
    var totalCount: Int?
    var errorMessage: String?
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case phase
        case processedCount = "processed_count"
        case totalCount = "total_count"
        case errorMessage = "error_message"
        case updatedAt = "updated_at"
    }
}
