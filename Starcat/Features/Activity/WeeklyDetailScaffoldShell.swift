//
//  WeeklyDetailScaffoldShell.swift
//  Starcat
//
//  R-01「三场景共用架构」Weekly 详情页外壳（D-28 v3，2026-06-11）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（dong4j 2026-06-11 反馈："4 详情页应该真同构,照搬 trending 模式"）
//  ────────────────────────────────────────────────────────────────────────────
//
//  本 view 是 Weekly 详情页的「外壳 + 解析层」,与 `TrendingScaffoldShell` 完全
//  同款架构。R-01 v1.2 Phase B5 重写时只把 Weekly 渲染层迁到 `RepoDetailScaffold`
//  共用骨架,但**外壳没拆**——`WeeklyDetailView` 自持 `@State displayRepo` /
//  `@State readmeVM`,导致同 weekly 切换 project 时无法走「shell .id 重建」
//  路径,hero 入场动画无法稳定触发。这是 D-28 v1/v2 修复未果的根因。
//
//  D-28 v3 把 Weekly 拆成两层(对齐 Trending 模式):
//  - **WeeklyDetailScaffoldShell**(本文件)— 持有 `@State displayRepo` /
//    `@State readmeVM` / `@State isLocalHit`,输入仅 `let project: WeeklyProject`
//    (非 optional)。外层挂 `.id(project.id)` 时整个 shell 重建,@State 自动
//    重置 + .task(id: project.id) 立即跑 loadAll —— 与 trending 同款行为。
//  - **WeeklyDetailView**(外层简化)— 只处理 project optional 空态分支,挂
//    `.id(project.id)` + `.detailContentTransition()` 让 shell 重建走"轻轻落下"。
//
//  ────────────────────────────────────────────────────────────────────────────
//  关键约束(写入注释作为永久记录)
//  ────────────────────────────────────────────────────────────────────────────
//
//  1. **Shell 重建友好的同步快路径**:Trending shell `resolveRepo` 不调网络,
//     未命中直接 `trending.makeEphemeralRepo()` 同步返回。Weekly shell 必走
//     GitHub `/repos`(weekly 项目大概率本地未命中,必须 API 拉真值),但通过
//     `loadAll` 入口同步推 `makeFallbackRepo(from: project)` 避免空白帧——
//     fallback 字段来自 WeeklyProject 自带数据(owner/name/desc/language/stars),
//     纯字段拷贝零失败,与 makeEphemeralRepo 语义对齐。任何 await 都会拖延
//     第一帧渲染 → 重现 D-27 卡顿症状。
//
//  2. **不复用 HomeView 全局 readmeVM**:与 Activity / Trending shell 同款做法,
//     本地 `@State` 持有,避免周刊详情污染主路径的 README 状态。
//
//  3. **API 调用失败兜底**:网络失败 / 404 时 fallback 到 makeFallbackRepo
//     的"最小 Repo",UI 仍能渲染但部分字段空缺,不至于详情页直接白屏。
//
//  4. **fallback Repo `id=0` + `isStarred=false`**:与原步骤 3 兜底语义一致 →
//     trailingActions / RepoLocalSections 守卫 `repo.isStarred && id != 0`
//     自动隐藏私人面板 / share / ai,与未登录或未命中场景表现完全一致。
//     **绝不能让 fallback Repo 进任何写入路径**(如 DB upsert / 翻译缓存等)。
//
//  ────────────────────────────────────────────────────────────────────────────
//  历史修订全部继承(D-22 / D-24 / D-26 / D-27 修法逻辑全部保留)
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **D-22 全字段 ==**:`Repo` Equatable 全字段比较保证 SwiftUI 平滑 diff。
//  - **D-24 registry-derived isStarred**:`handleStarTapped` toggle 完成后用
//    `starredRegistry.contains(ghRepoId:)` 派生新 isStarred 显式覆值 displayRepo,
//    让 hero star chip 当帧拿到真值。
//  - **D-26 fullName 守卫**:`resolveRepo` 1a `findById` 路径必须校验
//    `displayRepo.fullName.lowercased() == project.fullName.lowercased()`,
//    避免「跨 project 切换时用上一个 project 的 ghRepoId 误命中旧 repo」。
//    注:Shell .id 重建后 displayRepo 会被重置为 nil,1a 守卫 `cached.id > 0`
//    自动跳过,只在「同 shell 内 handleStarTapped 后二次 resolveRepo」路径上命中。
//  - **D-27 同步先行 + 异步升级**:`loadAll` 入口同步推 fallback + 同步触发
//    `readmeVM.loadTrending`(入口同步设 state = .loading),消除 stale 渲染。
//    `resolveRepo` 步骤 2 改 silent upgrade 模式,失败保持 fallback 不变。
//

import SwiftUI
import AppKit

/// Weekly 场景的详情页外壳。
///
/// - Note: 本 view 单独抽到一个文件而非塞进 `WeeklyDetailView.swift`,与
///   `TrendingScaffoldShell` 同款做法 —— Weekly 详情的解析逻辑(local hit /
///   silent upgrade / fallback)与 Weekly 路由解耦,`WeeklyDetailView` 内只剩
///   `WeeklyDetailScaffoldShell(project:)` 一行调用。
struct WeeklyDetailScaffoldShell: View {

    let item: WeeklyFeedItem

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var homeViewModel

    /// 局部 README ViewModel；首次进入时 lazy 构造。
    /// 与 Activity / Trending Shell 同款:Shell 自持 → 不污染主路径 README 状态。
    @State private var readmeVM: ReadmeViewModel?

    /// 当前 project 对应的展示用 `Repo`。
    ///
    /// 加载策略(D-27 修订继承):
    /// 0. **`loadAll` 入口同步推 fallback minimal Repo**(同步快路径,纯字段构造,
    ///    `id=0` / `isStarred=false`,字段来自 `WeeklyProject`,保证 hero 第二帧
    ///    立即有内容);
    /// 1. `resolveRepo` 异步查本地 DB(`findById` 优先 + `findByOwnerName` 兜底)→
    ///    命中即用本地真值替换 fallback,`isLocalHit = true`,开 tags/notes/release;
    /// 2. 本地未命中 → silent upgrade:调 `GET /repos/{owner}/{repo}` → 临时 Repo
    ///    (`id=0`, `isStarred=false`)替换 fallback,`isLocalHit = false`;失败保持
    ///    fallback 不变(hero 不白屏)。
    @State private var displayRepo: Repo?
    /// 详情接口返回的通用来源历史；切 repo 时必须与 displayRepo 同步清空，避免旧事件残留。
    @State private var sourceEvents: [WeeklySourceEvent] = []
    /// 当前 displayRepo 是否来自本地（保留供后续扩展使用,view body 当前不读取此字段）。
    @State private var isLocalHit: Bool = false

    // R-01 §3.2.3 决策（Q2）：unstar **即点即生效，不弹 confirm alert**；
    // API 失败 chip 抖动 + 短暂红色（不弹 toast / alert）。失败仅 AppLog 记日志。
    // → 本 view 不持有 showUnstarConfirm / unstarError 等 @State。

    var body: some View {
        // Group + if-else 与 TrendingScaffoldShell 同款:
        // - displayRepo / readmeVM 都就绪时渲染 RepoDetailScaffold;
        // - 极短瞬间(loadAll 入口同步推 fallback 之前的那一帧)显示 ProgressView。
        //
        // 注:Shell 由外层挂 `.id(project.id)` 重建时,@State 自动重置为 nil →
        // body 第一帧走 ProgressView 分支(显示 spinner,但因外层 `.detailContentTransition()`
        // 的 insertion = opacity 0 + offset y:14 → 用户视觉上几乎看不见 spinner,
        // 直接从「淡入下落」中显出 Scaffold)。
        Group {
            if let displayRepo, let readmeVM {
                scaffold(for: displayRepo, readmeVM: readmeVM)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.id) {
            await loadAll()
        }
    }

    // MARK: - Scaffold 装配

    @ViewBuilder
    private func scaffold(for repo: Repo, readmeVM: ReadmeViewModel) -> some View {
        RepoDetailScaffold(
            repo: repo,
            viewData: RepoDetailViewData(
                hero: RepoDetailHero(repo: repo),
                trailingActions: trailingActions(for: repo),
                // R-01 v1.0 设计 ⑬:翻译按钮覆盖所有 repo 详情。
                // 与 trending 同款:仅本地命中(`displayRepo.id != 0`)才暴露上下文,
                // ephemeral repo(id=0)撞翻译缓存命名空间。
                translation: repo.id != 0 ? ReadmeTranslationContext(fullName: repo.fullName) : nil,
                backendHint: nil,
                headerSourceBadge: RepoDetailHeaderSourceBadge(
                    sources: item.sourceTypes,
                    label: item.shortSourceLabel,
                    url: sourceURL(for: item)
                )
            ),
            fallbackAccentColor: WeeklyVisualStyle.accentColor,
            // R-01 v1.5 / v2.0:tooltip 与 toggle 行为对齐,直接派生自 `repo.isStarred`。
            starHelpKey: starHelpKey(repo: repo),
            onStarTapped: { try await handleStarTapped(repo: repo) },
            body: { onScrollReport in
                WeeklyDetailContent(
                    repo: repo,
                    sourceEvents: sourceEvents,
                    onScrollReport: onScrollReport,
                    readmeVM: readmeVM
                )
            }
        )
    }

    /// 计算 trailingActions。
    ///
    /// Weekly 来源已经在 `full_name` 行用 source badge 展示并负责跳转，右侧 actions
    /// 只保留通用详情动作，避免同一个阮一峰期号在 header 两个位置重复出现。
    private func trailingActions(for repo: Repo) -> [RepoDetailAction] {
        // v2.0（2026-06-16, dong4j）：OpenSSF 入口迁移到 hero `full_name` 同行，
        // 不再放在 trailing actions 数组里。
        var actions: [RepoDetailAction] = []
        if authSession.state.isAuthenticated, repo.isStarred {
            actions.append(.share)
            actions.append(.ai)
        }
        return actions
    }

    private func sourceURL(for item: WeeklyFeedItem) -> URL? {
        if let url = item.sourceEntries.first(where: { $0.sourceURL != nil })?.sourceURL {
            return url
        }
        if let url = item.weekly?.issueURL {
            return url
        }
        if item.zread != nil {
            return URL(string: "https://zread.ai/\(item.owner)/\(item.name)")
        }
        if let hnID = item.discovery?.hnID {
            return URL(string: "https://news.ycombinator.com/item?id=\(hnID)")
        }
        return nil
    }

    /// hero ⭐/☆ chip 的 tooltip 本地化键(v2.0 修订)。
    private func starHelpKey(repo: Repo) -> LocalizedStringKey {
        repo.isStarred ? "repo.unstar" : "trending.star"
    }

    // MARK: - Loading 协调（D-27 修法继承）

    /// 项目切换时一次性触发：fallback displayRepo + README + 后台升级 displayRepo。
    ///
    /// **D-27 修法继承**:严格的同步先行 + 异步升级双段式 ——
    ///
    /// 1) **同步段(同帧立即生效,无 await)**:
    ///    - `displayRepo` 立即推 `makeFallbackRepo(...)`(纯字段构造,零失败可能),
    ///      hero 第二帧切到 fallback,消除"白屏一秒"卡顿。Shell 重建场景下
    ///      `displayRepo` 初始为 nil,该步骤无条件推 fallback。
    ///    - `readmeVM.loadTrending(...)` 同步调用,入口处 `if !isSameRepo
    ///      { state = .loading }` 同帧把 README 区切到 spinner。
    ///
    /// 2) **异步段(后台升级 displayRepo)**:
    ///    - `await resolveRepo(for:)` 走本地 DB 命中(D-26 1a id 精确 + 1b owner/name
    ///      兜底)→ silent upgrade GitHub `/repos`(失败保持 fallback)。
    ///
    /// 这两段必须严格分先后:同步段必须放在 await 之前,任何 await 都会拖延 readme
    /// 切换 → 重现 D-27 卡顿症状。
    private func loadAll() async {
        // ─── 同步段(D-27 修复 1):必须在任何 await 之前完成 ─────────────────
        //
        // Shell 重建后 displayRepo 是 nil(@State 初始值),无条件推 fallback。
        // 同 shell 内 handleStarTapped 后重复 loadAll 不会发生(loadAll 仅由
        // .task(id: project.id) 触发,project.id 不变 task 不重跑),所以无需
        // D-27 时代的 `displayRepo?.fullName != project.fullName` 守卫。
        if displayRepo?.id != item.ghRepoId {
            displayRepo = makeFallbackRepo(from: item)
            sourceEvents = []
            isLocalHit = false
        }
        loadReadme(for: item)

        // ─── 异步段:后台升级 displayRepo 到本地真值或 GitHub API 真值 ───────
        await loadDetail(for: item)
        await resolveRepo(for: item)
    }

    private func loadDetail(for item: WeeklyFeedItem) async {
        do {
            let detail = try await dependencies.weeklyAPI.fetchDetail(repoID: item.ghRepoId)
            guard detail.repo.card.ghRepoId == item.ghRepoId else { return }
            displayRepo = detail.repo.card.toEphemeralRepo()
            sourceEvents = detail.events
            isLocalHit = false
        } catch {
            AppLog.network.warning("weekly: detail load failed for \(item.ghRepoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 决定 `displayRepo` 与 `isLocalHit`(D-27 修订:silent upgrade 模式)。
    ///
    /// 步骤(D-26 / D-27 修法继承):
    /// 1a. **优先 findById(displayRepo?.id)** 精确匹配 — 用于 star/unstar 完成后
    ///     第二次 resolveRepo,避开 owner/name 大小写 / 重命名问题(详见 D-24)。
    ///     **D-26 修订**:1a 必须额外校验 fullName 同源。Shell 重建后 displayRepo
    ///     初始为 fallback `id=0`,1a 守卫 `cached.id > 0` 自动跳过,只在
    ///     「同 shell 内 handleStarTapped 后二次 resolveRepo」路径上命中。
    /// 1b. findById 不命中 → 走 `findByOwnerName(owner:name:)` 兜底。
    /// 2.  全部不命中 → **silent upgrade**:调 GitHub `/repos` 用真值替换 fallback;
    ///     失败保持 fallback 不变(hero 不白屏)。
    private func resolveRepo(for item: WeeklyFeedItem) async {
        // 1a) 本地查找 — id 精确匹配 优先(仅当 fullName 与当前 project 同源)
        if let cached = displayRepo, cached.id > 0 {
            do {
                if let local = try await dependencies.repoRepository.findById(item.ghRepoId) {
                    displayRepo = local
                    isLocalHit = true
                    return
                }
            } catch {
                AppLog.sync.error("weekly: local repo findById(\(cached.id, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 1b) findById 未命中 → owner/name 兜底
        do {
            if let local = try await dependencies.repoRepository.findByOwnerName(
                owner: item.owner,
                name: item.name
            ) {
                displayRepo = local
                isLocalHit = true
                return
            }
        } catch {
            AppLog.sync.error("weekly: local repo lookup failed: \(error.localizedDescription, privacy: .public)")
        }

        // 2) Silent upgrade — 调 GitHub API 用真值替换 fallback。
        //
        // weekly 列表只是发现入口,**不入库**——避免污染本地 starred 集合。
        do {
            let dto = try await dependencies.apiClient.repo(owner: item.owner, repo: item.name)
            let cachedAt = ISO8601DateFormatter.shared.string(from: Date())
            displayRepo = GRDBRepoRepository.repoFromDTO(
                dto,
                starredAt: nil,
                cachedAt: cachedAt,
                isStarred: false
            )
            isLocalHit = false
        } catch {
            AppLog.network.error("weekly: GitHub /repos silent upgrade failed for \(item.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // 保持 loadAll 入口推的 fallback 不动,hero 不白屏。
        }
    }

    /// 从 WeeklyProject 构造一份"最小可用" Repo。
    ///
    /// 仅填 weekly 项目本身就有的字段：fullName / description / language / stars。
    /// `id = 0` 配合守卫 `repo.id != 0`,不能让此 Repo 进任何写入路径。
    private func makeFallbackRepo(from item: WeeklyFeedItem) -> Repo {
        item.card.toEphemeralRepo()
    }

    /// 触发 README 加载（D-27 修订:同步签名,fire-and-forget）。
    private func loadReadme(for item: WeeklyFeedItem) {
        let model = ensureReadmeViewModel()
        model.loadTrending(
            owner: item.owner,
            repo: item.name,
            isLoggedIn: authSession.state.isAuthenticated
        )
    }

    private func ensureReadmeViewModel() -> ReadmeViewModel {
        if let readmeVM {
            return readmeVM
        }
        // HOM-201 P0-2（2026-06-14）：与 active Shell 同款，注入共享 availability 单例。
        // weekly 走 `loadTrending` 不读 availability，但构造函数必传——传同一个实例
        // 保证未来 weekly 切到 loadInternal 路径时自然共享 404 短路。
        //
        // HOM-201 P0-4（2026-06-14）：weekly 永远走 `loadTrending`，`onHTMLLoaded` 不会
        // 被触发（详见 `ReadmeViewModel.onHTMLLoaded` 注释），因此**故意不传**——
        // 跟 active Shell 不一样,是为了让"weekly 是 trending 路径"这件事在代码层面
        // 显式可见。
        let model = ReadmeViewModel(
            api: dependencies.readmeAPI,
            availability: dependencies.readmeAvailability
        )
        readmeVM = model
        return model
    }

    // MARK: - Star / Unstar 协调（v1.7 修订继承）

    /// Star stat 按钮点击——与 manage / trending / activity 4 详情页**完全同构**。
    ///
    /// `StarActionService.toggle(repo:)` 内部按 `repo.isStarred || registry.contains`
    /// 派生 star/unstar 分支。本地命中 / 未命中 / ephemeral repo 三种情形通吃。
    ///
    /// **D-22 followup(2026-06-11)**:toggle 完成后双保险让 hero star 立即同步:
    /// 1. 用 registry 派生 isStarred 显式更新 displayRepo —— 第一道防线;
    /// 2. resolveRepo —— 第二道防线,合回本地 DB 完整字段。
    ///
    /// - 未登录 → `authSession.signIn()` 触发设备流,return(chip 不抖)
    /// - API 抛错 → throw 让 `StarStatChipButton` 触发抖动 + 短暂红色 600ms
    private func handleStarTapped(repo: Repo) async throws {
        guard authSession.state.isAuthenticated else {
            // 2026-06-29：只弹登录 sheet，不强制走 Device Flow
            authSession.requestLoginSheet()
            return
        }
        try await dependencies.starActionService.toggle(repo: repo)

        // D-22 followup:registry 派生新 isStarred 显式更新 displayRepo,让 hero 当帧拿真值。
        let nowStarred = dependencies.starredRegistry.contains(ghRepoId: repo.id)
        var updated = repo
        updated.isStarred = nowStarred
        displayRepo = updated

        await homeViewModel.refreshAfterExternalStarChange()
        await resolveRepo(for: item)
    }
}
