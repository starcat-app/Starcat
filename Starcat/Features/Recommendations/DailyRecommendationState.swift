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
    let cursor: String?

    init(positiveRepoIDs: [Int64], cursor: String? = nil) {
        self.positiveRepoIDs = positiveRepoIDs
        self.cursor = cursor
    }

    enum CodingKeys: String, CodingKey {
        case positiveRepoIDs = "positive_repo_ids"
        case limit
        case cursor
    }
}

/// 多仓接口与单仓分页 DTO 分开，避免要求服务端返回不存在的 repo_id / has_more。
struct DailyRecommendationResponse: Decodable, Sendable {
    let modelVersion: String
    let items: [RepoRecommendationItem]
    let hasMore: Bool
    let nextCursor: String?

    init(modelVersion: String, items: [RepoRecommendationItem], hasMore: Bool = false, nextCursor: String? = nil) {
        self.modelVersion = modelVersion
        self.items = items
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case modelVersion = "model_version"
        case items
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    /// 分页是接口的增量字段；未提供分页元信息的响应只能作为一个完整候选页使用
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelVersion = try values.decode(String.self, forKey: .modelVersion)
        items = try values.decode([RepoRecommendationItem].self, forKey: .items)
        hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

/// 可重建的候选池与分页位置；同一查询的未用候选跨天保留，推荐历史独立于此池
struct DailyRecommendationCandidatePool: Codable, Sendable {
    var seedIDs: [Int64]
    var serviceScope: String
    var modelVersion: String
    var checkedDay: String
    var items: [RepoRecommendationItem]
    var hasMore: Bool
    var nextCursor: String?
}

/// 账号级每日快照；历史与反馈仅为数据库投影，不从批次文件导入或双写。
struct DailyRecommendationState: Codable, Sendable {
    var day = ""
    var serviceScope = ""
    var modelVersion = ""
    var generatedAt: Date?
    var items: [RepoRecommendationItem] = []
    /// 区分“真实牌组已全部处理”和“补页暂未找到项目”，前者重开不能自动补牌。
    var hasGeneratedBatch = false
    var revealedIDs: Set<Int64> = []
    var dismissedIDs: Set<Int64> = []
    var autoPresentedDay = ""
    var showsOnLaunch = true
    /// key 使用仓库 ID 的十进制字符串，保持账号文件是可直接检查的 JSON 对象
    var recommendedDays: [String: String] = [:]
    var candidatePool: DailyRecommendationCandidatePool?

    init() {}

    enum CodingKeys: String, CodingKey {
        case day, serviceScope, modelVersion, generatedAt, items, hasGeneratedBatch, revealedIDs
        case autoPresentedDay, showsOnLaunch, candidatePool
    }

    /// 批次严格解码；历史和反馈由账号数据库恢复，不能从旧开发 JSON 创建残缺记录。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        day = try values.decode(String.self, forKey: .day)
        serviceScope = try values.decode(String.self, forKey: .serviceScope)
        modelVersion = try values.decode(String.self, forKey: .modelVersion)
        generatedAt = try values.decodeIfPresent(Date.self, forKey: .generatedAt)
        items = try values.decode([RepoRecommendationItem].self, forKey: .items)
        revealedIDs = try values.decode(Set<Int64>.self, forKey: .revealedIDs)
        autoPresentedDay = try values.decode(String.self, forKey: .autoPresentedDay)
        showsOnLaunch = try values.decode(Bool.self, forKey: .showsOnLaunch)
        candidatePool = try values.decodeIfPresent(DailyRecommendationCandidatePool.self, forKey: .candidatePool)
        hasGeneratedBatch = try values.decode(Bool.self, forKey: .hasGeneratedBatch)
    }

    /// 长期历史和反馈的唯一持久化来源已迁到 SQLite；本文件仅保留批次、进度与偏好。
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(day, forKey: .day)
        try values.encode(serviceScope, forKey: .serviceScope)
        try values.encode(modelVersion, forKey: .modelVersion)
        try values.encodeIfPresent(generatedAt, forKey: .generatedAt)
        try values.encode(items, forKey: .items)
        try values.encode(hasGeneratedBatch, forKey: .hasGeneratedBatch)
        try values.encode(revealedIDs, forKey: .revealedIDs)
        try values.encode(autoPresentedDay, forKey: .autoPresentedDay)
        try values.encode(showsOnLaunch, forKey: .showsOnLaunch)
        try values.encodeIfPresent(candidatePool, forKey: .candidatePool)
    }

    var recommendedIDs: Set<Int64> { Set(recommendedDays.keys.compactMap(Int64.init)) }

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
    static func candidates(
        _ items: [RepoRecommendationItem], excluding ids: Set<Int64>, limit: Int = 10
    ) -> [RepoRecommendationItem] {
        var seen = ids
        return Array(items.filter {
            $0.repoID > 0 && !$0.archived && $0.fullName.split(separator: "/").count == 2
                && seen.insert($0.repoID).inserted
        }.prefix(limit))
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
