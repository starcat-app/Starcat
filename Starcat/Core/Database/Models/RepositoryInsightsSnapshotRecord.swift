//
//  RepositoryInsightsSnapshotRecord.swift
//  Starcat
//
//  仓库洞察远端数据集的 GRDB 行映射。payload 保持 BLOB，解码职责由缓存仓储承担，
//  这样单个数据集损坏时可以只删除对应主键，而不是让整页缓存失效。
//

import Foundation
import GRDB

struct RepositoryInsightsSnapshotRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "repo_insights_snapshots"

    let repoId: Int64
    let dataset: String
    let rangeKey: String
    let payloadJSON: Data
    let defaultBranchSHA: String?
    let fetchedAt: String
    let staleAfter: String
    let responseETag: String?

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case dataset
        case rangeKey = "range_key"
        case payloadJSON = "payload_json"
        case defaultBranchSHA = "default_branch_sha"
        case fetchedAt = "fetched_at"
        case staleAfter = "stale_after"
        case responseETag = "response_etag"
    }
}
