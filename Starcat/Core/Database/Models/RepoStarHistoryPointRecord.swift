//
//  RepoStarHistoryPointRecord.swift
//  Starcat
//
//  仓库星标历史点的 GRDB 行映射。主键由 repo、UTC 日期和来源组成，因此同一天
//  的本机精确快照可以幂等更新，同时保留远端估算与 Discovery 精确快照。
//

import Foundation
import GRDB

struct RepoStarHistoryPointRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "repo_star_history_points"

    let repoId: Int64
    let observedOn: String
    let starsCount: Int
    let source: String
    let precision: String
    let fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case observedOn = "observed_on"
        case starsCount = "stars_count"
        case source
        case precision
        case fetchedAt = "fetched_at"
    }
}
