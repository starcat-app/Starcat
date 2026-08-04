//
//  RepoRepositoryProtocol.swift
//  Starcat
//
//  Repo 持久化协议（D-01 引入）。
//
//  存在意义：把 `GRDBRepoRepository` 抽象为协议，让 `HomeViewModel` / `SyncManager` 等
//  调用方依赖协议而非具体 struct，从而能写"完全脱离数据库"的单元测试
//  （把 Mock 实现塞到测试 target 即可，不需要起 GRDB writer）。
//
//  设计取舍：
//  - 9 个方法纳入协议：covers HomeViewModel + SyncManager 所有依赖路径
//  - **不纳入协议**：
//    - `topStarred(limit:)` — 调试/快速验证用，无生产调用方
//    - static `repoFromDTO(_:starredAt:cachedAt:)` — DTO → Model 静态工厂，
//      与 Repository 实例状态无关，调用方应直接走 `GRDBRepoRepository.repoFromDTO`
//      或 P1-1 完成后改为 DTO extension（D-06）
//  - `Sendable`：struct + value type 自动 Sendable；mock 实现需注意 isolation
//
//  Mock 落地（D-14 配套后续）：测试 target 写 `struct MockRepoRepository: RepoRepositoryProtocol`，
//  每个 method 用闭包 / 静态 fixture 控制返回值。
//
//  文件命名：与 GitHubAPIClientProtocol 同风格独立成文件；
//  具体实现 `GRDBRepoRepository` 保留在 `RepoRepository.swift`（文件名不改，
//  避免大幅触动 .pbxproj；详见 RepoRepository.swift 头注释）。
//

import Foundation

protocol RepoRepositoryProtocol: Sendable {

    // MARK: - Upsert / 取消 Star 标记

    /// 批量 upsert 一组 starred repos。
    func upsertStarred(_ dtos: [StarredRepoDTO], userID: Int64, syncedAt: Date) async throws

    /// 将本地存在但不在远端集合中的 repo 标记为 is_starred = false。
    func markUnstarredExcept(remoteRepoIDs: Set<Int64>, userID: Int64) async throws

    /// W4 B1：把单个 repo 标记为 is_starred = false。
    /// 同时清理 starred_repos 中对应行。
    /// 不删除 repo / 笔记 / 标签 —— 用户后续若 re-star 仍能拿回原数据。
    func markUnstarred(repoId: Int64, userID: Int64) async throws

    /// 将外部来源 repo 元数据写入 `repos`，但不创建 GitHub star 关系。
    ///
    /// 用于 Search Center / Discovery / Trending 等“未 star 也可加入知识库”的路径。
    /// 该方法只维护 repo metadata；真正的知识库归属写在 `repo_notes.library_state`。
    func upsertExternalRepoForLibrary(repoDTO: GitHubRepoDTO, syncedAt: Date) async throws -> Repo

    /// 将当前详情页已有的 `Repo` 元数据写入 `repos`，但不创建 GitHub star 关系。
    ///
    /// 用于 Trending / Weekly / Activity 等已经构造出 `Repo` 的详情页直接入库。
    /// 即便传入 repo 的 `isStarred` 为 true，本方法也以数据库已有 star 事实为准，
    /// 避免“加入知识库”路径误写 GitHub Star 语义。
    func upsertRepoMetadataForLibrary(repo: Repo, syncedAt: Date) async throws -> Repo

    /// 更新 repo 的远程访问状态。该状态只服务 UI 标记和后台降级，不改变 Star 或知识库归属。
    func updateAccessState(repoId: Int64, state: RepoAccessState, reason: String?, checkedAt: Date) async throws

    // MARK: - 查询

    /// 当前用户已 star 的 repo 总数。
    func starredCount() async throws -> Int

    /// Starcat 私有知识库 repo 总数（`repo_notes.library_state = in_library`）。
    func knowledgeCount() async throws -> Int

    /// 全部已 star 的 repo（按 starred_at 倒序）。
    func fetchAllStarred() async throws -> [Repo]

    /// 全部已入库 repo；允许包含 `is_starred = 0` 的私有知识库 repo。
    func fetchKnowledgeRepos() async throws -> [Repo]

    /// 最近 star 的 repo（`ORDER BY starred_at DESC LIMIT ?`）。
    ///
    /// Activity 首屏 prime 用：避免 `fetchAllStarred()` 全表扫描挡首屏。
    /// Manage 仍走 `fetchAllStarred()`。
    func fetchRecentStarred(limit: Int) async throws -> [Repo]

    /// 读取指定时间之后新增的 Star。Agent Weekly 用它冻结最近 7 天业务上下文，
    /// 不能用“最近 N 条”冒充时间窗口。
    func fetchStarred(since: Date, limit: Int) async throws -> [Repo]

    /// 按 GitHub repo id 查找。HOM-47 ReleaseMonitor 巡检每个订阅时需要拿 owner/name。
    /// 不存在返回 nil（不抛错），调用方决定后续行为（如跳过该次巡检）。
    func findById(_ repoId: Int64) async throws -> Repo?

    /// 按 owner / name 查找单条 repo 记录。
    ///
    /// 用途：Weekly 详情页（2026-06-08）需要"先查本地，命中则直接用本地 Repo 走 Manage 同款详情面板，
    /// 没命中再调 GitHub API 拉一份临时 Repo"。同样可用于"判断这个仓库是不是已经 star 过"等场景。
    ///
    /// 实现约束：
    /// - 查询命中"该 fullName 在 repos 表里有行"即返回，不限制 `is_starred = true`——
    ///   用户可能 star 过又取消，本地仍保留行；调用方根据 `repo.isStarred` 决定 UI 行为。
    /// - 用 `full_name` 列匹配（已建唯一索引），效率比 owner+name 两列 AND 高。
    /// - 不存在返回 nil，不抛错。
    func findByOwnerName(owner: String, name: String) async throws -> Repo?

    /// 未打标签的 repo。
    func fetchUntagged() async throws -> [Repo]

    /// 按语言筛选 repo（nil 表示无语言）。
    func fetchByLanguage(_ language: String?) async throws -> [Repo]

    /// 语言聚合统计。
    func languageStats() async throws -> [LanguageStat]

    /// 知识库范围语言聚合统计，允许包含未 star 但已入库的 repo。
    func knowledgeLanguageStats() async throws -> [LanguageStat]

    /// FTS5 全文搜索（空 query 退化为 fetchAllStarred）。
    func searchFTS(query: String) async throws -> [Repo]

    /// 知识库范围 FTS5 全文搜索；空 query 退化为 fetchKnowledgeRepos。
    func searchKnowledgeFTS(query: String) async throws -> [Repo]

    /// Manage 大数据量列表分页查询。
    ///
    /// 该接口用于替代 UI 主路径的 `fetchAllStarred() -> in-memory filter/sort/page`。
    /// `limit` 由 ViewModel 传入“单页大小 + 1”，`offset` 是已加载行数。
    /// Repository 只返回下一小段数据，让滚动追加成本与单页大小相关，而不是随已加载行数增长。
    func fetchListPage(
        scope: RepoListScope,
        filters: RepoListFilters,
        sort: RepoSortOption,
        limit: Int,
        offset: Int
    ) async throws -> [Repo]

    /// 当前 Manage 查询下的真实总数。
    ///
    /// 列表 UI 采用分页加载后，`items.count / filteredSorted.count` 只代表已加载前缀；
    /// 标题、副标题这类总量展示必须走 `COUNT(*)`，否则 1800+ 仓库只显示 20 / 40。
    func fetchListCount(
        scope: RepoListScope,
        filters: RepoListFilters
    ) async throws -> Int

    /// 当前 Manage 查询下的全部 repo id。
    ///
    /// 仅用于 Cmd+A / 少数全集语义；只投影 `id`，避免加载完整 `Repo` 行。
    func fetchListIDs(
        scope: RepoListScope,
        filters: RepoListFilters,
        sort: RepoSortOption
    ) async throws -> [Int64]

    /// 当前 Manage 查询下的全部多选快照。
    ///
    /// 只投影批量操作需要的 `id / owner / name`，供 Cmd+A 保持“当前筛选全集”语义。
    func fetchListSelectionSnapshots(
        scope: RepoListScope,
        filters: RepoListFilters,
        sort: RepoSortOption
    ) async throws -> [SelectionSnapshot]

    /// 当前用户项目关系中可供筛选菜单使用的组织、可见性和权限枚举。
    func fetchProjectFilterOptions(userID: Int64) async throws -> ProjectFilterOptions

    /// 当前项目页已展示 Repo 的关系元数据，供卡片一次批量装配。
    func fetchProjectRelations(userID: Int64, repoIDs: [Int64]) async throws -> [Int64: UserProject]

    /// 从本机 Star History 缓存批量计算 30 天增长；历史不足时不返回该 repo。
    func fetchLocalStarGrowth30Days(repoIDs: [Int64], now: Date) async throws -> [Int64: Int]

    // MARK: - Manage Repo Pin

    /// 返回全局置顶仓库及其置顶时间。HomeViewModel 只缓存这份轻量映射，供右键菜单状态
    /// 和无法下推 SQLite 的 Smart Collections 内存排序使用。
    func fetchPinnedRepoTimestamps() async throws -> [Int64: TimeInterval]

    /// 写入或删除一个仓库的全局 Pin 状态。传 nil 表示取消置顶。
    func setPinned(repoId: Int64, pinnedAt: Date?) async throws

    // MARK: - 同步状态

    /// 更新 sync_state 表中当前用户的同步统计。
    func updateSyncState(userID: Int64, starredCount: Int, syncedCount: Int, status: String) async throws

    // MARK: - W4-4 C2：Stars ETag

    /// 读取上次同步保存的 `/user/starred?page=1` ETag。
    /// 没有记录或字段为 NULL 时返回 nil（首次同步无条件请求）。
    func fetchStarsETag(userID: Int64) async throws -> String?

    /// 持久化最新一次 page 1 ETag；nil 表示清空。
    /// 这里独立成方法，不与 updateSyncState 合并 — 因为 ETag 写入时机比 stats 早
    /// （拿到响应后立刻保存），合并会迫使 SyncManager 在中间状态持久化"半截 stats"。
    func updateStarsETag(userID: Int64, etag: String?) async throws

    // MARK: - W4-4 C3：增量同步切分点

    /// 上次任何同步成功完成的 ISO8601 时间戳。增量同步用作 `starred_at` 切分点。
    /// 没有记录或字段为 NULL 时返回 nil（首次同步必走全量路径）。
    func fetchLastSyncAt(userID: Int64) async throws -> String?

    // MARK: - R-01：StarredRegistry 派生 + 单 repo star 写入

    /// R-01：一次性拉取「当前已 star」的所有 GitHub repo id（is_starred = 1）。
    ///
    /// 用途：`StarredRegistryBootstrapper.reload()` 启动 / 全量同步完成后重建内存 Set。
    /// 当前规模（< 2K starred）下 SELECT 应在 < 10ms 完成；> 5000 时按 §4.3.2
    /// Snapshot 扩展点占位实现 `~/Library/Application Support/Starcat/registry.snapshot`。
    func fetchStarredRepoIDs() async throws -> [Int64]

    /// 当前已入库 repo id 集合，供知识库 registry / AI 范围候选使用。
    func fetchKnowledgeRepoIDs() async throws -> [Int64]

    /// R-01：单个 repo 「重新 / 首次 star」时把字段写入 `repos` + `starred_repos`。
    ///
    /// 与 `upsertStarred(_ dtos:userID:syncedAt:)` 的区别：批量版在 SyncManager 全量同步走，
    /// 此处单次版给 `StarActionService.star(owner:repo:)` 调用——用户在详情页点 ☆ 后，
    /// 拉一次 GitHub `/repos/{o}/{r}` 拿完整字段，立刻落地。
    ///
    /// - 复用 `repoFromDTO(_:starredAt:cachedAt:isStarred:)` 静态工厂；`isStarred` 必为 true
    /// - 维护 `starred_repos` 行（user-repo 关系，便于后续 SyncManager 增量同步识别）
    /// - 返回写入后的 `Repo`，调用方拿 `repo.id` 直接喂 `StarredRegistry._add`
    func upsertSingleStarred(
        repoDTO: GitHubRepoDTO,
        starredAt: String?,
        userID: Int64,
        syncedAt: Date
    ) async throws -> Repo
}

extension RepoRepositoryProtocol {
    /// 测试替身和轻量实现可复用的兼容实现；生产 GRDB 会用 SQL 下推时间过滤。
    func fetchStarred(since: Date, limit: Int) async throws -> [Repo] {
        let formatter = ISO8601DateFormatter()
        return try await fetchAllStarred()
            .filter { repo in
                guard let value = repo.starredAt, let date = formatter.date(from: value) else { return false }
                return date >= since
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    /// 兼容只关心普通 Repo 查询的测试替身；生产 GRDB 实现会返回真实项目维度。
    func fetchProjectFilterOptions(userID: Int64) async throws -> ProjectFilterOptions {
        .empty
    }

    func fetchProjectRelations(userID: Int64, repoIDs: [Int64]) async throws -> [Int64: UserProject] {
        [:]
    }

    func fetchLocalStarGrowth30Days(repoIDs: [Int64], now: Date) async throws -> [Int64: Int] {
        [:]
    }
}

// MARK: - Conformance

/// `GRDBRepoRepository` 已实现所有要求的方法，这里空 conformance 即可。
extension GRDBRepoRepository: RepoRepositoryProtocol {}
