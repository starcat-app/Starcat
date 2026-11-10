//
//  DailyRecommendationState.swift
//  Starcat
//
//  每日抽卡的值模型与持久化。批次可重建，屏蔽反馈属于用户选择；
//  两者存入独立 Application Support 文件，不混入可清理的相似推荐缓存。
//

import Foundation

/// 既有多仓接口的最小查询；负种子和排除集合均留在本地。
struct DailyRecommendationQuery: Encodable {
    let positiveRepoIDs: [Int64]
    let limit = 100

    enum CodingKeys: String, CodingKey {
        case positiveRepoIDs = "positive_repo_ids"
        case limit
    }
}

/// 多仓接口与单仓分页 DTO 分开，避免要求服务端返回不存在的 repo_id / has_more。
struct DailyRecommendationResponse: Decodable, Sendable {
    let modelVersion: String
    let items: [RepoRecommendationItem]

    enum CodingKeys: String, CodingKey {
        case modelVersion = "model_version"
        case items
    }
}

/// 账号级每日快照；不将屏蔽项目视为负向种子上传。
struct DailyRecommendationState: Codable, Sendable {
    var day = ""
    var serviceScope = ""
    var modelVersion = ""
    var generatedAt: Date?
    var items: [RepoRecommendationItem] = []
    var revealedIDs: Set<Int64> = []
    var dismissedIDs: Set<Int64> = []
    var autoPresentedDay = ""
    var showsOnLaunch = true

    /// 内部日期身份固定 Gregorian，展示日期另用视图 locale 格式化。
    static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    /// 近期与长期语言分桶轮转各取一部分，输入排序固定时输出稳定。
    /// MVP 不推断私人标签/笔记兴趣，私有、归档和重复 ID 不作种子。
    static func seeds(from repos: [Repo]) -> [Int64] {
        var seen: Set<Int64> = []
        let eligible = repos.sorted {
            if $0.starredAt != $1.starredAt { return ($0.starredAt ?? "") > ($1.starredAt ?? "") }
            return $0.id < $1.id
        }.filter { $0.id > 0 && $0.isStarred && !$0.isPrivate && !$0.isArchived && seen.insert($0.id).inserted }
        var result = Array(eligible.prefix(10).map(\.id))
        var selected = Set(result)
        let buckets = Dictionary(grouping: eligible, by: { $0.language ?? "" })
        let keys = buckets.keys.sorted()
        var index = 0
        while result.count < 20 {
            var added = false
            for key in keys {
                guard let bucket = buckets[key], index < bucket.count else { continue }
                let id = bucket[index].id
                if selected.insert(id).inserted {
                    result.append(id)
                    added = true
                    if result.count == 20 { break }
                }
            }
            index += 1
            if !added && index >= (buckets.values.map(\.count).max() ?? 0) { break }
        }
        return result
    }

    /// 完整集合本地过滤，不受服务端 500 个排除 ID 限制；重复或无效候选不占卡槽。
    static func candidates(_ items: [RepoRecommendationItem], excluding ids: Set<Int64>) -> [RepoRecommendationItem] {
        var seen = ids
        return Array(items.filter {
            $0.repoID > 0 && !$0.archived && $0.fullName.split(separator: "/").count == 2
                && seen.insert($0.repoID).inserted
        }.prefix(10))
    }
}

/// 在独立 actor 内完成原子文件 I/O，避免翻牌动画被磁盘写入阻塞。
/// revision 拒绝迟到的旧写入；账户文件隔离，注销不删除屏蔽反馈。
actor DailyRecommendationDiskStore {
    private let root: URL
    private var revisions: [Int64: UInt64] = [:]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppConstants.bundleIdentifier)
            .appendingPathComponent("daily-recommendations", isDirectory: true)
    }

    func load(accountID: Int64) throws -> DailyRecommendationState {
        let url = root.appendingPathComponent("\(accountID).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return DailyRecommendationState() }
        // 损坏文件必须报错，不能以空状态覆盖用户“不感兴趣”反馈。
        return try JSONDecoder().decode(DailyRecommendationState.self, from: Data(contentsOf: url))
    }

    func save(_ state: DailyRecommendationState, accountID: Int64, revision: UInt64) throws {
        guard revision >= (revisions[accountID] ?? 0) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("\(accountID).json"), options: .atomic)
        revisions[accountID] = revision
    }
}
