//
//  StarringSubsystem.swift
//  Starcat
//
//  R-01「三场景共用架构」核心 subsystem —— Star 状态的统一权威。
//
//  本文件承载三个紧密协作的类型：
//    1. `StarredRegistry`               —— 内存中「已 star repo id」集合 + 只读 API
//    2. `StarActionService`             —— 唯一允许写入 registry 的 service（star / unstar）
//    3. `StarredRegistryBootstrapper`   —— 启动 / 全量同步完成后重建 registry 的 helper
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⚠️  为什么三个类型放一个文件？（v1.2 dong4j review R1：双 Source of Truth 风险）
//  ────────────────────────────────────────────────────────────────────────────
//
//  Swift 没有 `friend class` 概念。要强制「写入 registry 的路径唯一」必须靠
//  `fileprivate` 写方法 + 三类型同文件。任何 View / ViewModel 试图调
//  `registry._add(...)` 会**编译报错**。
//
//  这是「DB 与 Registry 漂移」风险的根治方案 —— Registry 内存集合若漏
//  invalidate 会与 SQLite 不一致。靠纪律不可靠，靠编译器才稳。
//
//  ⚠️  绝对禁止：把 `_add` / `_remove` / `_replace` 的 `fileprivate` 放宽为
//  `internal`，或者把这三个类型拆到不同文件。两者其一发生即破坏「写入路径唯一」契约。
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⚠️  已知扩展点：Snapshot 机制（达到阈值再做，详见详细设计 §4.3.2 + §9.2）
//  ────────────────────────────────────────────────────────────────────────────
//
//  当前规模（< 2K starred）下启动期 `SELECT id FROM repos WHERE is_starred = 1`
//  在 ~5-10ms 完成，对首屏渲染无感。
//
//  触发 Snapshot 机制阈值：
//    - 任一用户 starred 仓库数 > 5000 → 启动 SELECT 可能 > 30ms
//    - 或长尾 enrich 队列 > 1000 个 repo（trending API 后端方案触发）
//
//  届时实现思路：
//    ① 每次 `_add/_remove` 同步写入
//       `~/Library/Application Support/Starcat/registry.snapshot`
//       （文本格式：一行一个 Int64，~50K 行 → 数百 KB，毫秒级 IO）
//    ② 启动期先 `_replace(with: 读 snapshot)`，立刻 emit 让 UI 渲染；
//       后台异步 SELECT 校验 + 修正漂移
//    ③ 写 snapshot 失败不致命，下次启动重建即可
//
//  实施时把本注释升级为完整方案 + 注释引用 PR 号。
//
//  ────────────────────────────────────────────────────────────────────────────
//  跨场景联动机制（设计 §3.3）
//  ────────────────────────────────────────────────────────────────────────────
//
//  `StarredRegistry.ids` 是 `@Observable` 跟踪的属性。SwiftUI Observation
//  框架自动让任何**读** `registry.ids` / `registry.contains(...)` 的 View
//  在 ids 变更时刷新。所以：
//
//      用户在 Trending 详情点 ☆
//        → StarActionService.star(...)
//          → registry._add(ghRepoId)
//            → 所有列表里同名卡片绿勾**自动**出现，不需要手动 reload
//
//  这是 R-01 取代旧 `TrendingViewModel.subscribedRepoIDs`（仅会话级）的核心收益。
//
//  ────────────────────────────────────────────────────────────────────────────
//  线程模型
//  ────────────────────────────────────────────────────────────────────────────
//
//  三个类型全部 `@MainActor` —— Star 操作是 UI 驱动（用户点击触发），不是高并发后台任务。
//  v1.1 dong4j review 决议：actor → @MainActor final class（消除 actor → MainActor → actor
//  无意义 hop；GRDB DatabaseWriter 自身串行化已在更底层保证）。
//

import Foundation
import Observation

// MARK: - HomeRefreshing 协议

/// Home 场景刷新接口（弱引用注入到 `StarActionService`）。
///
/// star / unstar 完成后，`HomeViewModel` 需要刷新 sidebar 计数 + 当前列表 items
/// （因为 `repos` 表已写入新行 / 标记 unstar 行）。
///
/// 用 weak 持有避免「Service 强引用 HomeView」带来的循环。
@MainActor
protocol HomeRefreshing: AnyObject {
    /// star / unstar 后的轻刷新。允许并发安全 cancel（HomeView 可能正在重新加载）。
    func refreshAfterStarChange() async
}

// MARK: - StarredRegistry

/// 全局已 star 仓库集合（内存视图）。
///
/// 单一信任源：本地 `repos` 表（is_starred = 1）的派生视图，由
/// `StarredRegistryBootstrapper.reload()` 装载，由 `StarActionService`
/// 维护变更。**禁止任何其他路径写入**（编译期由 `fileprivate` 保证）。
///
/// 数据结构：`Set<Int64>` of `gh_repo_id` —— 查询 O(1)，1.8K 行规模毫秒级全量加载。
///
/// 为什么不用 fullName：GitHub repo rename 后 fullName 变 → 列表 / 详情匹配会丢；
/// gh_repo_id 永不变。详细论证见详细设计 §4.4。
@MainActor
@Observable
final class StarredRegistry {

    /// 当前已 star 的 gh_repo_id 集合。
    ///
    /// 对外只读（`private(set)`）；SwiftUI Observation 监听这个字段即可触发跨场景刷新。
    private(set) var ids: Set<Int64> = []

    /// 本次会话里 star / unstar 后的展示用星标数。
    ///
    /// Explore / Activity / 搜索等列表拿的是接口快照，`starsCount` 不会跟着 GitHub
    /// 写操作变。这里存「点完之后用户应立刻看到的数字」，详情 chip 和
    /// `asCardData(registry:)` 都读它；没有记录时退回快照/DB 原值。
    /// 用绝对值而不是 delta，避免 Manage 已把 DB 减 1 后再叠加一次。
    private(set) var sessionStarsCounts: [Int64: Int] = [:]

    init() {}

    // MARK: - 公开只读 API

    /// 查询某个 gh_repo_id 是否已 star。
    /// - parameter ghRepoId: GitHub 数字 id；nil（极少数 enricher 未补全场景）一律返 false
    func contains(ghRepoId: Int64?) -> Bool {
        guard let id = ghRepoId else { return false }
        return ids.contains(id)
    }

    /// 当前已 star 数量（外部展示 / 调试用）。
    var count: Int { ids.count }

    /// 列表 / hero 展示用星标数：本次会话写过则用会话值，否则用调用方快照。
    func displayedStarsCount(base: Int, ghRepoId: Int64) -> Int {
        sessionStarsCounts[ghRepoId] ?? base
    }

    /// 把当前会话的 star 状态和展示星标数覆到一份 Repo 上。
    ///
    /// Explore / Activity 详情的 `displayRepo` 来自接口快照，star/unstar 后
    /// `resolveRepo()` 还会用快照重建。调用方必须用本方法收口，避免只改 ✓
    /// 不改数字，也避免每个 shell 自己抄一遍。
    func applyingDisplayState(to repo: Repo) -> Repo {
        var updated = repo
        updated.isStarred = contains(ghRepoId: repo.id)
        updated.starsCount = displayedStarsCount(base: repo.starsCount, ghRepoId: repo.id)
        return updated
    }

    // MARK: - fileprivate 写 API（仅同文件 StarActionService / Bootstrapper 可调）

    // ⚠️ 不要把 fileprivate 改成 internal，否则会破坏「写入路径唯一」契约。
    // 详见文件头说明。

    fileprivate func _add(_ ghRepoId: Int64) {
        ids.insert(ghRepoId)
    }

    fileprivate func _remove(_ ghRepoId: Int64) {
        ids.remove(ghRepoId)
    }

    fileprivate func _replace(with snapshot: Set<Int64>) {
        ids = snapshot
    }

    fileprivate func _setSessionStarsCount(_ count: Int, ghRepoId: Int64) {
        var next = sessionStarsCounts
        next[ghRepoId] = max(0, count)
        sessionStarsCounts = next
    }

    fileprivate func _clearSessionStarsCounts() {
        sessionStarsCounts = [:]
    }
}

// MARK: - StarActionService

/// Star / Unstar 的唯一权威服务（v1.2 R1：fileprivate 强制写入路径唯一）。
///
/// 调用链（star）：
/// ```
/// 1. apiClient.star(owner: "alice", repo: "foo")
///    → PUT /user/starred/alice/foo （GitHub 204 No Content）
/// 2. apiClient.repo(owner: "alice", repo: "foo")
///    → GET /repos/alice/foo （拉完整字段，含 ghRepoId / starsCount / topics 等）
/// 3. repoRepository.upsertSingleStarred(...)
///    → 写入 `repos` 表 + `starred_repos` 表（一个事务）
/// 4. registry._add(saved.id)
///    → 所有列表 / 详情自动响应（@Observable）
/// 5. homeRefresher?.refreshAfterStarChange()
///    → HomeViewModel 刷新 sidebar 计数 / 当前列表
/// ```
///
/// 失败语义：任意一步 throw，service 直接把 error 上抛。UI 层（详情页 chip）负责
/// 把 chip 抖动 + 短暂红色（~600ms）；**registry 不写入**，DB 没有半截状态。
///
/// 为什么不做乐观 UI：API 200 才变 UI 是 v1.0 Q1 决策——简化状态机，避免回滚动画抖动。
@MainActor
final class StarActionService {

    private let apiClient: any GitHubAPIClientProtocol
    private let repoRepository: any RepoRepositoryProtocol
    private let registry: StarredRegistry
    /// Undo Star 历史记录仓储（unstar 时写入，star 时移除）。
    private let undoStarHistory: any UndoStarHistoryRepositoryProtocol
    /// 当前用户 Star / Unstar 账本。通知时间线混排用；单测可不传。
    private let activityRepository: (any UserRepoActivityRepositoryProtocol)?

    /// 当前登录用户 ID 提供者。注入闭包而非直接持有 AuthSession 是为了：
    /// ① 单测注入 stub `{ 42 }` 即可，不用 mock AuthSession；
    /// ② AuthSession 状态变化时 Service 不需要 KVO，每次操作时取最新值。
    private let userIDProvider: @MainActor () -> Int64?
    /// GitHub `login`，写入账本 `user_name`。没有 login 就不记账本，避免匿名行。
    private let userNameProvider: @MainActor () -> String?

    /// HomeView 刷新协议（weak）。注入时机：HomeView `.task` 时通过
    /// `dependencies.starActionService.attachHomeRefresher(homeViewModel)` 挂接。
    private weak var homeRefresher: (any HomeRefreshing)?

    init(
        apiClient: any GitHubAPIClientProtocol,
        repoRepository: any RepoRepositoryProtocol,
        registry: StarredRegistry,
        undoStarHistory: any UndoStarHistoryRepositoryProtocol,
        userIDProvider: @escaping @MainActor () -> Int64?,
        userNameProvider: @escaping @MainActor () -> String? = { nil },
        homeRefresher: (any HomeRefreshing)? = nil,
        activityRepository: (any UserRepoActivityRepositoryProtocol)? = nil
    ) {
        self.apiClient = apiClient
        self.repoRepository = repoRepository
        self.registry = registry
        self.undoStarHistory = undoStarHistory
        self.userIDProvider = userIDProvider
        self.userNameProvider = userNameProvider
        self.homeRefresher = homeRefresher
        self.activityRepository = activityRepository
    }

    /// 给 HomeView 在 `.task` 里挂接 refresher。
    func attachHomeRefresher(_ refresher: any HomeRefreshing) {
        self.homeRefresher = refresher
    }

    /// 账本必须同时有 GitHub id 和 login，否则推荐侧无法标识「谁」。
    private func currentActivityActor() -> UserRepoActivityActor? {
        guard let userID = userIDProvider() else { return nil }
        let actor = UserRepoActivityActor(userID: userID, userName: userNameProvider() ?? "")
        return actor.isIdentified ? actor : nil
    }

    // MARK: - 操作

    /// Star 一个 repo。
    ///
    /// - returns: 写入本地后的完整 `Repo`（含 cachedAt / starredAt）
    /// - throws:  `StarActionError.notAuthenticated` 未登录 / 网络层 `NetworkError` /
    ///            DB 错误。任意一步失败都不会污染 registry / DB（只有最后步骤命中才写）。
    func star(owner: String, repo: String, displayedStarsCount: Int? = nil) async throws -> Repo {
        guard let userID = userIDProvider() else {
            throw StarActionError.notAuthenticated
        }

        // 1. PUT /user/starred/{o}/{r}
        try await apiClient.star(owner: owner, repo: repo)

        // 2. GET /repos/{o}/{r} 拉完整字段
        let repoDTO = try await apiClient.repo(owner: owner, repo: repo)

        // 3. DB upsert + mark starred
        let saved = try await repoRepository.upsertSingleStarred(
            repoDTO: repoDTO,
            starredAt: nil,                    // PUT 无响应体，用 syncedAt 兜底
            userID: userID,
            syncedAt: Date()
        )

        // 4. registry._add（fileprivate 同文件可见）
        let alreadyStarred = registry.contains(ghRepoId: saved.id)
        registry._add(saved.id)
        if !alreadyStarred {
            // 详情/列表点 star 时带上当前展示数，避免 GitHub GET 仍返回旧计数。
            // 批量 star 没有展示数时退回 GET 结果。
            let nextCount = displayedStarsCount.map { $0 + 1 } ?? saved.starsCount
            registry._setSessionStarsCount(nextCount, ghRepoId: saved.id)
        }
        NotificationCenter.default.post(
            name: .repositorySpotlightSourceDidChange,
            object: nil,
            userInfo: ["repoId": saved.id]
        )

        // 5. 从 Undo Star 历史中移除（如果存在）
        do {
            try await undoStarHistory.remove(ghRepoId: saved.id)
            NotificationCenter.default.post(
                name: .undoStarHistoryDidChange,
                object: nil,
                userInfo: ["starredGhRepoId": saved.id]
            )
        } catch {
            AppLog.sync.error("UndoStar remove failed: \(error.localizedDescription, privacy: .public)")
            DiagnosticLogStore.record(
                level: .error,
                visibility: .issue,
                category: "database",
                operation: "undoStar.remove",
                message: "Undo Star history could not remove a restored repository",
                underlying: DiagnosticEvent.summarize(error),
                context: ["repoID": String(saved.id)]
            )
        }

        // 6. 通知时间线账本。失败不影响 star 本身。
        if let actor = currentActivityActor() {
            do {
                try await activityRepository?.recordStar(
                    repo: saved,
                    source: .starcat,
                    actor: actor,
                    occurredAt: UserRepoActivityRecord.timestamp()
                )
            } catch {
                AppLog.sync.error("UserRepoActivity star failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 7. HomeView 刷新
        await homeRefresher?.refreshAfterStarChange()

        AppLog.sync.info("Star OK \(saved.fullName, privacy: .public) (id=\(saved.id, privacy: .public))")
        return saved
    }

    /// Unstar 一个 repo。
    ///
    /// 数据语义（v1.0 §3.2.3）：只置 `is_starred=false`，**保留** tags / notes /
    /// release 订阅 / AI 摘要等用户私有数据。用户后续重新 star 时自动恢复
    /// （因索引 = `gh_repo_id` 不变）。
    ///
    /// - throws: 同 star。失败不修改 registry。
    func unstar(repo: Repo) async throws {
        try await unstar(
            ghRepoId: repo.id,
            owner: repo.owner,
            name: repo.name,
            displayedStarsCount: registry.displayedStarsCount(
                base: repo.starsCount,
                ghRepoId: repo.id
            )
        )
    }

    /// Unstar 入口的 by-id overload（W12 toolbar 专项 PR-4 引入）。
    ///
    /// 与 `unstar(repo:)` 等价；存在动机：trending / weekly 多选项是 ephemeral —
    /// 列表里没有完整 `Repo` 实例，但 `ghRepoId` + `owner` + `name` 三元组一定齐全。
    /// 让 BatchStarService 直接调本 overload，避免在 ephemeral 路径上构造 dummy
    /// Repo 充入大量 sentinel 字段。
    ///
    /// **同文件依赖**：访问 `registry._remove` 是 fileprivate，必须留在本文件内，
    /// 与 StarringSubsystem 的「写入路径唯一」契约一致（详见文件头注释）。
    func unstar(ghRepoId: Int64, owner: String, name: String, displayedStarsCount: Int? = nil) async throws {
        guard let userID = userIDProvider() else {
            throw StarActionError.notAuthenticated
        }

        let baseline: Int?
        if let displayedStarsCount {
            baseline = displayedStarsCount
        } else if let sessionCount = registry.sessionStarsCounts[ghRepoId] {
            baseline = sessionCount
        } else {
            baseline = try await repoRepository.findById(ghRepoId)?.starsCount
        }

        try await apiClient.unstar(owner: owner, repo: name)
        try await repoRepository.markUnstarred(repoId: ghRepoId, userID: userID)

        registry._remove(ghRepoId)
        // Explore / Activity 快照路径上 registry 可能还没含这个 id（启动期 reload
        // 未完成），但用户已经从详情页点了取消。只要本次 unstar 成功，就必须写下
        // 展示数；不能因为 wasStarred == false 就让列表继续停在接口快照。
        if let baseline {
            registry._setSessionStarsCount(max(0, baseline - 1), ghRepoId: ghRepoId)
        }
        NotificationCenter.default.post(
            name: .repositorySpotlightSourceDidChange,
            object: nil,
            userInfo: ["repoId": ghRepoId]
        )
        await homeRefresher?.refreshAfterStarChange()

        // 记录到 Undo Star 历史（去重：同 ghRepoId 更新 unstarred_at）
        do {
            let record = UndoStarRecord(
                ghRepoId: ghRepoId,
                owner: owner,
                name: name,
                fullName: "\(owner)/\(name)",
                repoDescription: nil,
                language: nil,
                starsCount: 0,
                forksCount: 0,
                watchersCount: 0,
                htmlUrl: "https://github.com/\(owner)/\(name)",
                unstarredAt: ISO8601DateFormatter.shared.string(from: Date())
            )
            try await undoStarHistory.record(record)
            NotificationCenter.default.post(name: .undoStarHistoryDidChange, object: nil)
        } catch {
            AppLog.sync.error("UndoStar record failed: \(error.localizedDescription, privacy: .public)")
            DiagnosticLogStore.record(
                level: .error,
                visibility: .issue,
                category: "database",
                operation: "undoStar.record",
                message: "Undo Star history could not persist an unstarred repository",
                underlying: DiagnosticEvent.summarize(error),
                context: ["repoID": String(ghRepoId)]
            )
        }

        // 通知时间线账本。和 undo_star_history 分开：那边每个仓库只留一行，这边可追加。
        if let actor = currentActivityActor() {
            do {
                try await activityRepository?.recordUnstar(
                    repoID: ghRepoId,
                    fullName: "\(owner)/\(name)",
                    htmlURL: "https://github.com/\(owner)/\(name)",
                    source: .starcat,
                    actor: actor,
                    occurredAt: UserRepoActivityRecord.timestamp()
                )
            } catch {
                AppLog.sync.error("UserRepoActivity unstar failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        AppLog.sync.info("Unstar OK \(owner, privacy: .public)/\(name, privacy: .public) (id=\(ghRepoId, privacy: .public))")
    }

    // ────────────────────────────────────────────────────────────────────────
    // v1.7 引入 / **v2.0 修订**(2026-06-10, dong4j 真机反馈后回归):
    // 4 详情页统一 toggle 入口
    // ────────────────────────────────────────────────────────────────────────
    //
    // ## 背景演化
    //
    // - **v1.4 / v1.5 修订前**:4 个详情页(Manage / Trending / Weekly / Activity)
    //   各自实现 `onStarTapped`,行为契约散落在场景层(Manage 写死 unstar、
    //   Trending 按 repo.isStarred 二分、Weekly 按 isLocalHit 三段...)。
    //
    // - **v1.7 改用 `registry.contains(ghRepoId:)` 二分**:本意是绑「写权限锁死的
    //   单一信任源」,避免 ephemeral repo `isStarred=false` 但 registry 已 add 的
    //   stale 误判。但 dong4j 真机回归发现 Manage 已 star 的 repo 点 ⭐ 居然走
    //   star 而不是 unstar。根因:`StarredRegistry.reload()` 是异步的(在
    //   `AppDependencies.init` 末尾 `Task { await bootstrapper.reload() }`),且
    //   `SyncManager` 304 ETag 命中早退路径直接 `return`,**不触发 onSyncCompleted
    //   hook**(v2.0 已补上),任一路径未跑完 → registry.ids 空集 → contains
    //   永远 false → 本就 starred 的 Manage repo 被当成未 star 重新走 star 分支。
    //
    // ## v2.0 折中策略:`repo.isStarred || registry.contains(ghRepoId:)` 任一为 true 走 unstar
    //
    // 这是个既稳又不漏的「双信任源 OR」组合:
    //
    // - **`repo.isStarred`(主路径)**:本地 DB `is_starred` 列的内存镜像,在
    //   `Repo` 对象构造时一次性读出,**同步可信**:
    //     - Manage:`fetchAllStarred` 已 filter is_starred=true → 真值 true
    //     - Trending 本地命中:`findByOwnerName` 返回的 row 含 is_starred 真值
    //     - Trending ephemeral:`makeEphemeralRepo()` 显式 `isStarred = false`
    //     - Weekly 本地命中 / ephemeral:同 Trending
    //     - Activity:`item.repo` 来自 ActivityRepository 的 Repo 表查询 → 真值
    //
    // - **`registry.contains(ghRepoId:)`(兜底)**:解决「刚 star 完瞬间」的 stale,
    //   user 在 Trending 详情页第一次 star → `star(...)` 写入 DB + registry add →
    //   refreshSidebar / reloadItems → 但 displayRepo 可能还是旧 ephemeral
    //   `isStarred=false`(若 resolveRepo 还没跑完),用户立即再点 ⭐ 应该是
    //   unstar 但只看 repo.isStarred 会错走 star。registry 此时已含 ghRepoId,
    //   兜得住。
    //
    // 任一条件 true 即 unstar 的合理性:
    //   - DB true & registry true → 已 star,unstar(主路径)
    //   - DB true & registry false → 启动期 registry 未 reload,信 DB(v2.0 修复点)
    //   - DB false & registry true → 刚 star 完 displayRepo 还是 stale,信 registry
    //   - DB false & registry false → 真未 star,star
    //
    // ## 调用方模板(4 个详情页)
    //
    // ```swift
    // guard isAuthenticated else { signIn(); return }
    // try await dependencies.starActionService.toggle(repo: repo)
    // await homeViewModel.refreshAfterExternalStarChange()
    // ```
    //
    // ## 关键约束
    //   - `repo.id` 等价于 `ghRepoId`(R-01 终稿后 repos.id == GitHub repo id),
    //     trending / weekly ephemeral repo 也走同一字段;
    //   - 失败语义不变(任意一步抛错都直接上抛,UI 层 chip 抖动 + 短暂红色);
    //   - view 层守卫(`trailingActions` / `RepoLocalSections.isVisible` /
    //     `starHelpKey`)**只用 `repo.isStarred`,不再调 registry**——
    //     view 层不需要兜「刚 star 完」corner case(此时 displayRepo 重解析后
    //     就是真值),保留单信任源避免 UI 闪烁。
    func toggle(repo: Repo) async throws {
        // 点之前用户看见的数字（含本次会话 overlay）。Explore 快照不会跟着变，
        // 不能直接信 `repo.starsCount`，否则 star 100→101 后再 unstar 会减成 99。
        let displayed = registry.displayedStarsCount(base: repo.starsCount, ghRepoId: repo.id)
        if repo.isStarred || registry.contains(ghRepoId: repo.id) {
            try await unstar(
                ghRepoId: repo.id,
                owner: repo.owner,
                name: repo.name,
                displayedStarsCount: displayed
            )
        } else {
            _ = try await star(
                owner: repo.owner,
                repo: repo.name,
                displayedStarsCount: displayed
            )
        }
    }
}

/// `StarActionService` 抛出的领域错误。
enum StarActionError: Error, LocalizedError {
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return String.l10n("starAction.error.notAuthenticated")
        }
    }
}

// MARK: - StarredRegistryBootstrapper

/// 全量重建 `StarredRegistry` 的 helper。
///
/// 调用时机：
///   1. App 启动期（`AppDependencies.init` 内 Task 内异步调，不阻塞构造）
///   2. 全量同步完成后（`SyncManager.runSync` 末尾）
///   3. 登入成功后（`AuthSession` 切到 `.authenticated`）
///   4. CloudKit 同步进来新数据（W5 接入；本期预留接口）
///
/// 失败策略：失败**不清空** registry，避免漂移；下次操作时 single-write 路径
/// 仍然能维持一致性。
@MainActor
final class StarredRegistryBootstrapper {

    private let registry: StarredRegistry
    private let repoRepository: any RepoRepositoryProtocol

    init(registry: StarredRegistry, repoRepository: any RepoRepositoryProtocol) {
        self.registry = registry
        self.repoRepository = repoRepository
    }

    /// 全量重建 registry。
    ///
    /// SQL: `SELECT id FROM repos WHERE is_starred = 1`
    /// 1.8K 行规模 ~5ms 完成；详见文件头 Snapshot 扩展点占位说明。
    func reload() async {
        do {
            let snapshot = try await repoRepository.fetchStarredRepoIDs()
            registry._replace(with: Set(snapshot))
            AppLog.sync.info("StarredRegistry reloaded: \(snapshot.count, privacy: .public) ids")
        } catch {
            // 失败不清空 registry，避免「正在用着用着突然全变未 star」的体验崩塌
            AppLog.sync.error("StarredRegistryBootstrapper.reload failed: \(error.localizedDescription, privacy: .public)")
            DiagnosticLogStore.record(
                level: .error,
                visibility: .issue,
                category: "database",
                operation: "starredRegistry.reload",
                message: "The local starred repository registry could not be rebuilt",
                underlying: DiagnosticEvent.summarize(error)
            )
        }
    }

    /// 登出时清空 registry。
    func clearOnSignOut() {
        registry._replace(with: [])
        registry._clearSessionStarsCounts()
        AppLog.sync.info("StarredRegistry cleared on sign out")
    }
}
