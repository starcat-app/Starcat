//
//  WeeklyDetailView.swift
//  Starcat
//
//  Activity 页 weekly 分类的右侧详情面板。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计目标（R-01 v1.2 Phase B5 重写，2026-06-10）
//  ────────────────────────────────────────────────────────────────────────────
//
//  与 Manage / Trending / Activity-建议/仓库/星标 共用 **同一套** 详情页骨架：
//
//      `RepoDetailScaffold` (Hero + heroExtension + trailingActions + body slot)
//
//  Weekly 场景下：
//  - **trailingActions**：`[.weeklyIssue, .share, .ai]`(Scaffold 内置 weeklyIssue
//    case 渲染 capsule + secondary 描边的「第 N 期」按钮);未 star 时只剩
//    weeklyIssue 一项(share / ai 守卫绑 `StarredRegistry.contains`,见 v1.7 修订)。
//  - **body slot**:`WeeklyDetailContent` 渲染 README WebView(走 trending 缓存路径)
//  - **不接 heroExtension**:weekly 没有 contributors 字段
//
//  ────────────────────────────────────────────────────────────────────────────
//  Repo 解析策略(与 B5 重写前保持一致,逻辑搬到 Scaffold 外)
//  ────────────────────────────────────────────────────────────────────────────
//
//  1. 本地命中(findByOwnerName)→ 用本地真值,hero 三段(tags/notes/release)开启;
//  2. 未命中 → 调 `GET /repos/{owner}/{repo}` 拉完整字段构造临时 Repo(id=0,
//     isStarred=false, **不入库**);
//  3. API 失败 → 用 WeeklyProject 现有字段构造最小 Repo(保证 hero 不白屏)。
//
//  与 B5 之前版本的差异：原 `WeeklyDetailView` 自己持有 `metadataPanelCollapseProgress`
//  / `metadataPanelHeight` + 自写 `CollapsibleRepoMetadataPanel + RepoMetadataHeaderView`
//  的"半骨架";现在折叠 / hero / trailing 全部交给 `RepoDetailScaffold`,本 view 仅
//  保留「Repo 解析 + readmeVM 局部持有 + star/unstar 协调」三块。
//
//  ────────────────────────────────────────────────────────────────────────────
//  关键约束
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **不复用 HomeView 全局 readmeVM**:与 Activity / Trending Shell 同款做法,本地
//    `@State` 持有,避免周刊详情污染主路径的 README 状态。
//  - **API 调用失败兜底**:网络失败 / 404 时 fallback 到一份"最小 Repo",UI 仍能
//    渲染但部分字段空缺,不至于详情页直接白屏。
//
//  ────────────────────────────────────────────────────────────────────────────
//  v1.7 修订(2026-06-10, dong4j bug 反馈)
//  ────────────────────────────────────────────────────────────────────────────
//
//  原 `handleStarTapped` 三段式(本地命中-star/unstar / 未命中-跳 stargazers 页面)
//  存在两个问题:
//  ① 与 manage / trending / activity 4 详情页不同构,各家维护一套行为契约;
//  ② 未命中跳 stargazers 是当时 §3.2.6 的妥协方案,但 `StarActionService.star(...)`
//     内部已包含 `PUT /user/starred` + `GET /repos/{o}/{r}` + DB upsert,
//     完全可以直接 star 入自己账户(与 trending 路径相同)。
//
//  v1.7 把 4 详情页的行为契约统一收口到 `StarActionService.toggle(repo:)` +
//  `StarredRegistry.contains(ghRepoId:)`:
//  - **trailingActions**:守卫 `isAuthenticated && registry.contains(...)` 派生
//    `.share` / `.ai` 可见性,与 4 详情页同构;
//  - **starHelpKey**:tooltip 由 registry 派生,删 weekly 独有的「打开 Stargazers
//    页面」case;
//  - **onStarTapped**:无论命中与否都走 toggle,删跳 stargazers 妥协逻辑,
//    weekly 也能直接 star 入自己账户。
//
//  ────────────────────────────────────────────────────────────────────────────
//  D-26 修订(2026-06-11, dong4j bug 反馈)
//  ────────────────────────────────────────────────────────────────────────────
//
//  D-24 修复了「weekly 详情页第一次 star 后 hero 不变实心」,引入了 `resolveRepo`
//  步骤 1a 优先 `findById(displayRepo?.id)` 的精确命中策略(避开 weekly owner/name
//  大小写不一致 owner/name 查找漏命中)。但该实现**只考虑同 project 内 star/unstar
//  后第二次 resolveRepo**,没考虑切换 project 的场景。
//
//  Bug 现象:用户在 weekly 详情 A 中 star 之后,切到 weekly 详情 B,**README 区域
//  正常切换到 B(loadReadme 走 project.owner/name)**,但 hero / 三段仍显示 A
//  (`@State displayRepo` 不会因 project prop 变化自动重置,resolveRepo 1a 用 A_id
//   findById 命中本地 A_local → displayRepo = A_local → return,B 永远不被解析)。
//
//  D-26 修法:1a 必须额外校验 `displayRepo.fullName.lowercased() ==
//  project.fullName.lowercased()`,只有「同一 project 内」才走 ghRepoId 精确匹配;
//  fullName 不匹配时自动跳到 1b owner/name 查找(与 D-24 之前行为一致)。
//  这是最小改动方案,保留 D-24 大小写防护的同时修复 ghosting bug。
//
//  ────────────────────────────────────────────────────────────────────────────
//  D-27 修订(2026-06-11 22:00, dong4j「weekly 切换 repo 卡顿 + 旧 repo 视觉残留」反馈)
//  ────────────────────────────────────────────────────────────────────────────
//
//  Bug 现象:weekly 列表选中 A → 切到 B 时,右侧详情页表现为 ——
//    ① 上半部分(hero)还是 A 的内容;
//    ② 下半部分(README)闪一下 A 的 readme html;
//    ③ 然后才出现 loading 转圈;
//    ④ 最后才更换为 B 的 hero + readme。
//
//  对比 trending 切换路径(`TrendingScaffoldShell`)秒切丝滑,根因有三条互相放大:
//
//    1) **resolveRepo 步骤 2 把 GitHub `/repos/{o}/{r}` 网络调用放在切换 critical
//       path 里**:weekly 项目大概率本地未命中(不是用户 starred 过的),必走 GitHub
//       API。`await apiClient.repo(...)` 几百 ms ~ 1+s 期间 `displayRepo` 一直是 A,
//       hero 看上去不变。trending 路径完全不调 `/repos`,本地未命中直接
//       `trending.makeEphemeralRepo()` 同步返回。
//
//    2) **loadAll 串行 await**(原版 `await resolveRepo` 跑完才调 `loadReadme`):
//       `readmeVM` 切到 B 的 `.loading` 状态被网络请求阻塞,期间 README 区一直
//       渲染 A 的 stale `.loaded` html。
//
//    3) **`.id(project.id)` 加在 `content` 子树**而非 `WeeklyDetailView` 顶层:
//       触发**子树重建**但 `@State displayRepo` / `readmeVM` 是外层 `WeeklyDetailView`
//       的 state 不会重置 → 新子树用 stale 值(A 的 displayRepo + A 的 readmeVM.state
//       `.loaded`)渲染一帧 → 用户看到「上半 A + 下半闪一下 A」的视觉残留。
//       注:`RepoDetailScaffold` 内部本身就有 `.id(repo.id)` 处理元信息面板折叠重置,
//       外层再加 `.id(project.id)` 完全冗余且反作用。
//
//  D-27 修法(三步同改,缺一不可):
//
//    1) **loadAll 入口同步推 fallback + 同步触发 readmeVM**:跨 project 切换时
//       (`displayRepo?.fullName != project.fullName`)立即把 `displayRepo` 设为
//       `makeFallbackRepo(from: project)`(同步构造,纯字段拷贝零失败可能)→ hero
//       同帧切到 B 的 owner/name/desc/language/stars。然后**同步**调
//       `readmeVM.loadTrending(...)`,该方法入口处 `if !isSameRepo { state = .loading }`
//       同帧把 README 切到 spinner。这两步必须放在 await `resolveRepo` 之前,任何
//       await 都会拖延 readme 切换。
//
//    2) **删除 `content(project).id(project.id)`**:Scaffold 内部已有
//       `.id(repo.id)`(处理元信息面板折叠重置等),外层再加是冗余的。删掉后
//       SwiftUI 平滑 diff hero / readme,不再出现 stale state 渲染一帧。
//
//    3) **resolveRepo 步骤 2 改后台 silent upgrade**:fallback 已在屏幕上(loadAll
//       入口同步推),步骤 2 仅尝试用 GitHub `/repos` 真值替换 fallback 字段;失败
//       时保持 fallback 不变(hero 不会因 API 失败而白屏)。同步删除 `@State
//       isFetchingRemote`(其唯一用途——`else if isFetchingRemote` ProgressView 占位
//       态——在 fallback-on-entry 策略下永远不会触发,作 dead state 删干净)。原
//       「步骤 3 用 fallback 兜底」并入入口同步路径,resolveRepo 函数末尾不再额外
//       推 fallback。
//
//  关键约束(写入注释):
//    - fallback minimal Repo `id = 0` + `isStarred = false`,与原步骤 3 兜底语义
//      一致 → trailingActions / RepoLocalSections 守卫 `repo.isStarred && id != 0`
//      自动隐藏私人面板 / share / ai,与未登录或未命中场景表现完全一致;
//    - readmeVM 是 WeeklyDetailView 局部 `@State`(非全局),不会污染 Manage / Trending
//      主路径的 README 状态;
//    - 同 project 内重复 resolveRepo(handleStarTapped 后)仍走 D-26 1a 精确路径,
//      行为不变,只是不再因为 isFetchingRemote 抢屏卡顿;
//    - 不删 `@State isLocalHit`(目前 view body 未读取,但保留供后续扩展,避免无关
//      清理放大改动面)。
//

import SwiftUI
import AppKit

struct WeeklyDetailView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var homeViewModel

    let project: WeeklyProject?

    /// 局部 README ViewModel；首次有 project 时按需 lazy 构造。
    /// 与 ActivityDetailView / TrendingScaffoldShell 同款做法：周刊详情页不影响 Manage / Trending 主路径的 README 状态。
    @State private var readmeVM: ReadmeViewModel?

    /// 当前 project 对应的展示用 `Repo`。
    ///
    /// 加载策略（D-27 修订后,见 `loadAll` + `resolveRepo`）：
    /// 0. **`loadAll` 入口同步推 fallback minimal Repo**(跨 project 切换时立即生效,
    ///    `id=0` / `isStarred=false`,字段来自 `WeeklyProject`,保证 hero 同帧切到当前
    ///    project 不残留上一个);
    /// 1. `resolveRepo` 异步查本地 DB(`findById` 优先 + `findByOwnerName` 兜底)→ 命中
    ///    即用本地真值替换 fallback,`isLocalHit = true`,开 tags/notes/release;
    /// 2. 本地未命中 → silent upgrade:调 `GET /repos/{owner}/{repo}` → 临时 Repo
    ///    (`id=0`, `isStarred=false`)替换 fallback,`isLocalHit = false`;失败保持
    ///    fallback 不变(hero 不白屏)。
    @State private var displayRepo: Repo?
    /// 当前 displayRepo 是否来自本地（保留供后续扩展使用,view body 当前不读取此字段）。
    @State private var isLocalHit: Bool = false
    // D-27 修订(2026-06-11):原 `@State isFetchingRemote` 已删除。其唯一用途
    // ——「本地未命中 → 拉 GitHub API 期间显示 ProgressView 占位」—— 在 `loadAll`
    // 入口同步推 fallback 后永远不会触发(displayRepo 不再有「nil 待拉」中间态)。
    // 删 dead state 而非保留,避免后续协作者误用。

    // R-01 §3.2.3 决策（Q2）：unstar **即点即生效，不弹 confirm alert**；
    // API 失败 chip 抖动 + 短暂红色（不弹 toast / alert）。失败仅 AppLog 记日志。
    // → 本 view 不持有 showUnstarConfirm / unstarError 等 @State。

    var body: some View {
        // D-27 修订(2026-06-11):删除原 `.id(project.id)` —— 该 modifier 加在 content
        // 子树而非 WeeklyDetailView 顶层时会触发**子树重建**但外层 @State (displayRepo /
        // readmeVM) 不重置,新子树用 stale 值渲染一帧 → 视觉残留。`RepoDetailScaffold`
        // 内部已有 `.id(repo.id)` 处理元信息面板折叠重置,这里再加冗余且反作用。
        // 现在依赖 SwiftUI 平滑 diff + loadAll 入口同步推 fallback displayRepo 实现切换。
        Group {
            if let project {
                content(project)
            } else {
                emptyState
            }
        }
        .task(id: project?.id) {
            await loadAll(for: project)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ project: WeeklyProject) -> some View {
        if let displayRepo, let readmeVM {
            RepoDetailScaffold(
                repo: displayRepo,
                viewData: RepoDetailViewData(
                    hero: RepoDetailHero(repo: displayRepo),
                    trailingActions: trailingActions(for: project, repo: displayRepo),
                    // R-01 v1.0 设计 ⑬：翻译按钮覆盖所有 repo 详情。
                    // 与 trending 同款：仅本地命中（`displayRepo.id != 0`）才暴露上下文,
                    // ephemeral repo（id=0,见 `resolveRepo` 步骤 2/3）撞翻译缓存命名空间。
                    // 实际翻译按钮渲染在 `WeeklyDetailContent` 的 `translationControl` 上,
                    // 这里 `translation` 字段当前只作上下文持有（Scaffold 暂未消费）,保持
                    // 与 4 详情页 viewData 元数据一致,后续若 Scaffold 改用此字段可零改动接通。
                    translation: displayRepo.id != 0 ? ReadmeTranslationContext(fullName: displayRepo.fullName) : nil,
                    backendHint: nil
                ),
                fallbackAccentColor: ActivityCategory.weekly.iconColor,
                // R-01 v1.5：三段渲染已下沉到 RepoDetailScaffold metadataPanel
                // (RepoLocalSections),**v2.0 起守卫绑 `repo.isStarred` 单一信任源**
                // (从 v1.7 的 `starredRegistry.contains(...)` 回归,详见
                // `RepoLocalSections.swift` v2.0 修订段)。
                //
                // tooltip 同步切换(**v2.0**):已 star 显示「取消 star」,未 star 显示「Star」,
                // 与 onStarTapped(toggle) 行为对齐。
                starHelpKey: starHelpKey(repo: displayRepo),
                onStarTapped: { try await handleStarTapped(repo: displayRepo) },
                body: { onScrollOffset in
                    WeeklyDetailContent(
                        repo: displayRepo,
                        onScrollOffset: onScrollOffset,
                        readmeVM: readmeVM
                    )
                }
            )
        } else {
            // 极端兜底:project 非 nil 但 displayRepo / readmeVM 极短瞬间还没填好
            // (理论上 loadAll 入口同步推 fallback + 同步 ensureReadmeViewModel 这帧就
            // 完成赋值,正常路径不会进此分支)。
            EmptyView()
        }
    }

    /// 计算 trailingActions(**v2.0 修订**, 2026-06-10):
    /// - `.weeklyIssue`(周刊期号外链):仅依赖 `firstIssue + issueURL`,与登录态/star 态无关
    ///   (公开 GitHub issue 页面),**保持独立**;
    /// - `.share` / `.ai`:守卫绑 `isAuthenticated && repo.isStarred`,与 4 详情页同构
    ///   (从 v1.7 的 `registry.contains(ghRepoId:)` 回归,理由见
    ///   `RepoLocalSections.swift` v2.0 修订段)。
    /// - 已登录 + 已 star → `[.weeklyIssue, .share, .ai]`(与 Manage 详情对齐 + 周刊期号入口);
    /// - 已登录 + 未 star → `[.weeklyIssue]`(share / ai 守卫拦下);
    /// - 未登录 → 仅 `[.weeklyIssue]`(若有 firstIssue);
    /// - 无 firstIssue 时(极端:trending hint 缺扩展段)→ 移除 `.weeklyIssue` case。
    private func trailingActions(for project: WeeklyProject, repo: Repo) -> [RepoDetailAction] {
        var actions: [RepoDetailAction] = []
        if project.firstIssue > 0, let issueURL = project.issueURL {
            actions.append(.weeklyIssue(number: project.firstIssue, url: issueURL))
        }
        if authSession.state.isAuthenticated, repo.isStarred {
            actions.append(.share)
            actions.append(.ai)
        }
        return actions
    }

    /// hero ⭐/☆ chip 的 tooltip 本地化键(**v2.0 修订**)。
    /// 与 onStarTapped(`StarActionService.toggle`)行为对齐,直接派生自 `repo.isStarred`:
    /// - 已 star → 「取消 star」
    /// - 未 star → 「Star」
    private func starHelpKey(repo: Repo) -> LocalizedStringKey {
        repo.isStarred ? "repo.unstar" : "trending.star"
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "newspaper")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("weekly.detail.emptyTitle")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("weekly.detail.emptySubtitle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Loading 协调

    /// 项目切换时一次性触发：fallback displayRepo + README + 后台升级 displayRepo。
    ///
    /// **D-27 修订(2026-06-11):严格的同步先行 + 异步升级双段式**——
    ///
    /// 1) **同步段(同帧立即生效,无 await)**:
    ///    - `displayRepo` 跨 project 切换时立即推 `makeFallbackRepo(...)`(纯字段构造,
    ///      零失败可能),hero 同帧切到当前 project,消除「上半还是 A 的内容」视觉残留;
    ///    - `readmeVM.loadTrending(...)` 同步调用,内部入口处 `if !isSameRepo
    ///      { state = .loading }` 同帧把 README 区切到 spinner,消除「下半闪一下 A 的
    ///      readme html」视觉残留。
    ///
    /// 2) **异步段(后台升级 displayRepo)**:
    ///    - `await resolveRepo(for:)` 走本地 DB 命中(D-26 1a id 精确 + 1b owner/name
    ///      兜底)→ silent upgrade GitHub `/repos`(失败保持 fallback)。期间 hero 已
    ///      经显示 fallback 内容,不再阻塞 UI。
    ///
    /// 这两段必须严格分先后:同步段必须放在 await 之前,任何 await 都会拖延 readme
    /// 切换 → 重现 D-27 卡顿症状。
    private func loadAll(for project: WeeklyProject?) async {
        guard let project else {
            // 切到空选中 → 释放 README 状态,避免上一项的 loading 残留。
            readmeVM?.reset()
            displayRepo = nil
            isLocalHit = false
            return
        }

        // ─── 同步段(D-27 修复 1):必须在任何 await 之前完成 ─────────────────
        //
        // 跨 project 切换时立即把 displayRepo 替换为当前 project 的 fallback minimal
        // Repo(纯字段拷贝,零失败可能),hero 同帧切到 B 的 owner/name/desc/language/
        // stars,消除「hero 残留 A 内容直到 await resolveRepo 完成」的卡顿症状。
        //
        // 同 project 内重复 loadAll(理论上 task(id:) 不会触发,但 handleStarTapped 等
        // 路径不在此走)→ fullName 匹配 → 不动 displayRepo,保留本地命中真值。
        if displayRepo?.fullName.lowercased() != project.fullName.lowercased() {
            displayRepo = makeFallbackRepo(from: project)
            isLocalHit = false
        }
        // 同步触发 README 切换。`loadTrending` 入口处 `if !isSameRepo { state = .loading }`
        // 同帧设置,消除「README 闪一下 A 的 stale html」视觉残留。
        loadReadme(for: project)

        // ─── 异步段:后台升级 displayRepo 到本地真值或 GitHub API 真值 ───────
        await resolveRepo(for: project)
    }

    /// 决定 `displayRepo` 与 `isLocalHit`(D-27 修订后:silent upgrade 模式)。
    ///
    /// **前置条件**:`loadAll` 入口已经同步把 `displayRepo` 推到当前 project 的 fallback
    /// minimal Repo,hero 已经在屏幕上。本函数仅负责**用更精细的真值替换 fallback**。
    ///
    /// 步骤:
    /// 1a. **优先 findById(displayRepo?.id)** 精确匹配 — 用于 star/unstar 完成后
    ///     第二次 resolveRepo,避开 owner/name 大小写 / 重命名问题(详见 D-24)。
    ///     **D-26 修订**:1a 必须额外校验 `displayRepo.fullName.lowercased() ==
    ///     project.fullName.lowercased()`,否则切换 project 时会用上一个 project
    ///     的 ghRepoId 误命中旧 repo。
    ///     注:D-27 修复后 loadAll 入口推的 fallback `id=0`,1a 守卫 `cached.id > 0`
    ///     自动跳过 fallback 路径,只在「handleStarTapped 后同 project 二次 resolveRepo」
    ///     这条原本想走 1a 的路径上命中。
    /// 1b. findById 不命中(displayRepo `id=0` fallback / 历史未命中 / fullName 不匹配)
    ///     → 走 `findByOwnerName(owner:name:)` 兜底。
    /// 2.  全部不命中 → **silent upgrade**:调 GitHub `/repos` 用真值替换 fallback;
    ///     失败保持 fallback 不变(hero 不白屏)。
    ///     **D-27 修订**:原步骤 2 设 `isFetchingRemote = true` + 阻塞 UI 显
    ///     ProgressView,现在 fallback 已在屏上,API 在后台静默跑,不阻塞 UI。原
    ///     「步骤 3 显式推 fallback 兜底」并入 `loadAll` 入口同步路径,本函数末尾
    ///     不再额外推 fallback。
    private func resolveRepo(for project: WeeklyProject) async {
        // 1a) 本地查找 — id 精确匹配 优先(仅当 fullName 与当前 project 同源)
        //
        // **D-24 followup**: weekly 项目 owner/name 源自阮一峰周刊 markdown 解析,
        // 偶有大小写不一致(如 `Vercel/swr` vs GitHub 真值 `vercel/swr`)。SQLite
        // 默认 BINARY collation 导致 findByOwnerName 漏掉,而 ghRepoId 全局
        // 唯一且不变,findById 精确命中无大小写陷阱。
        //
        // **D-26 修订(2026-06-11, dong4j bug 反馈)**:必须校验 fullName 同源
        // 才能用 displayRepo.id 做 findById。
        //
        // 触发场景:用户在 weekly 详情 A(已 star,DB 入库 → displayRepo.id=A_id)
        // 切换到 weekly 详情 B → `.task(id: project?.id)` 触发 resolveRepo(for: B),
        // 此时 displayRepo 还是 A(SwiftUI @State 不会因 prop 变化自动重置)。
        // 若不加 fullName 守卫,1a 会用 A_id 走 findById 命中本地 A_local 行
        // → `displayRepo = A_local` → 直接 return,导致 hero 区永远显示 A 的内容,
        // 而 README 路径(`loadReadme` 直接读 `project.owner/name`)却切到了 B,
        // 用户看到「README 换了 / hero 没换」的 ghosting 错觉。
        //
        // 加 fullName 守卫后,只有「同一个 project 内 star/unstar 后的二次解析」
        // 这条 1a 真正想走的路径会命中(此时 displayRepo.fullName == project.fullName);
        // 切换 project 时 fullName 不匹配 → 自动跳到 1b 走 owner/name 查找,
        // 与 D-24 之前的行为一致(weekly 大小写问题仍由 1b 走 GitHub API 兜底解决)。
        //
        // 触发时机:第二次以后调用 resolveRepo(同 project handleStarTapped 之后)。
        if let cached = displayRepo,
           cached.id > 0,
           cached.fullName.lowercased() == project.fullName.lowercased() {
            do {
                if let local = try await dependencies.repoRepository.findById(cached.id) {
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
                owner: project.owner,
                name: project.name
            ) {
                displayRepo = local
                // local 行可能 isStarred=false(用户取消 star 后的墓碑行);
                // 此时也算"本地有 repo.id 可用",tags/notes/release 段照常渲染。
                // Star stat 的 tooltip / 动作仍按 isStarred 真实状态决定。
                isLocalHit = true
                return
            }
        } catch {
            AppLog.sync.error("weekly: local repo lookup failed: \(error.localizedDescription, privacy: .public)")
            // 继续走远端路径,不阻塞
        }

        // 2) Silent upgrade — 调 GitHub API 用真值替换 fallback。
        //
        // **D-27 修订(2026-06-11)**:此前这里设 `isFetchingRemote = true` 阻塞 UI 显
        // ProgressView,导致 weekly 切换 critical path 必走 ~几百 ms ~ 1+s 的网络等待
        // 期间 hero 残留上一个 project 的内容(详见文件头 D-27 修订段)。现在 fallback
        // 已经在屏幕上(`loadAll` 入口同步推),本步骤仅用真值替换字段,失败时保持
        // fallback 不变(hero 不白屏)。weekly 列表只是发现入口,**不入库**——避免污染
        // 本地 starred 集合。
        do {
            let dto = try await dependencies.apiClient.repo(owner: project.owner, repo: project.name)
            let cachedAt = ISO8601DateFormatter.shared.string(from: Date())
            displayRepo = GRDBRepoRepository.repoFromDTO(
                dto,
                starredAt: nil,
                cachedAt: cachedAt,
                isStarred: false
            )
            isLocalHit = false
        } catch {
            AppLog.network.error("weekly: GitHub /repos silent upgrade failed for \(project.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // 保持 loadAll 入口推的 fallback minimal repo 不动,hero 不白屏。
            // 原「步骤 3 兜底显式推 fallback」已并入 loadAll 入口同步路径,这里不再
            // 重复推一次(避免 race:本步骤跑完时 displayRepo 可能已经被同 project 的
            // handleStarTapped 路径推上来 — 虽然实际不太可能,但语义上 silent upgrade
            // 应该是「成功才覆盖,失败不动」)。
        }
    }

    /// 从 WeeklyProject 构造一份"最小可用" Repo。
    ///
    /// 仅填 weekly 项目本身就有的字段：fullName / description / language / stars。
    /// forks / watchers / topics / dates 全部留默认值（0 / nil / nil）。
    /// `id = 0` 配合 `showLocalSections: false`，绝不能让此 Repo 进任何写入路径。
    private func makeFallbackRepo(from project: WeeklyProject) -> Repo {
        Repo(
            id: 0,
            owner: project.owner,
            name: project.name,
            fullName: project.fullName,
            description: project.description,
            language: project.language,
            starsCount: project.stars,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: project.url.absoluteString,
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: ISO8601DateFormatter.shared.string(from: Date())
        )
    }

    /// 触发 README 加载。
    ///
    /// **D-27 修订(2026-06-11)**:函数签名从 `async` 改为同步 —— 内部 `loadTrending`
    /// 本来就是"启动 Task,入口处同步设 state = .loading,网络异步跑"的 fire-and-forget
    /// 形态,外层 await 没有意义,反而误导调用方以为「await 完了 README 已加载好」。
    /// 同步签名让 `loadAll` 入口处「同步触发 README 切换」的语义更清晰。
    private func loadReadme(for project: WeeklyProject) {
        let model = ensureReadmeViewModel()
        model.loadTrending(
            owner: project.owner,
            repo: project.name,
            isLoggedIn: authSession.state.isAuthenticated
        )
    }

    private func ensureReadmeViewModel() -> ReadmeViewModel {
        if let readmeVM {
            return readmeVM
        }
        let model = ReadmeViewModel(api: dependencies.readmeAPI)
        readmeVM = model
        return model
    }

    // MARK: - Star / Unstar 协调（v1.7 修订, 2026-06-10）

    /// Star stat 按钮点击——与 manage / trending / activity 4 详情页**完全同构**。
    ///
    /// `StarActionService.toggle(repo:)` 内部按 `StarredRegistry.contains` 派生 star /
    /// unstar 分支。本地命中 / 未命中 / ephemeral repo 三种情形通吃:
    /// - 已 star(registry 命中)→ unstar
    /// - 未 star(registry 未命中)→ `star(owner:repo:)` 内部完成 PUT + GET /repos +
    ///   DB upsert,即便是未命中的 ephemeral repo 也能直接入自己账户(weekly 也能 star)。
    ///
    /// **v1.7 删除妥协逻辑**:原"未命中跳 stargazers 页面"是当时担心 ephemeral repo
    /// (id=0) 写入污染 starred 集合的妥协;但 `StarActionService.star` 拉 GitHub
    /// `/repos/{o}/{r}` 后用真实 ghRepoId 写库,与 trending 完全同路径,妥协无必要。
    ///
    /// - 未登录 → `authSession.signIn()` 触发设备流,return(chip 不抖)
    /// - API 抛错 → throw 让 `StarStatChipButton` 触发抖动 + 短暂红色 600ms
    ///
    /// 失败由 chip 统一处理(抖动 + 日志),本方法不再 catch 写日志。
    private func handleStarTapped(repo: Repo) async throws {
        guard authSession.state.isAuthenticated else {
            authSession.signIn()
            return
        }
        try await dependencies.starActionService.toggle(repo: repo)

        // ─────────────────────────────────────────────────────────────────
        // D-22 followup(2026-06-11, 详见 §6.3 D-24):
        // toggle 完成后**两步双保险**让 hero star 立即同步真值:
        //
        // 1. 用 registry 派生 isStarred 显式更新 displayRepo —— 第一道防线:
        //    无论 resolveRepo 步骤 1 命中与否, hero 当帧就能拿到新 isStarred。
        //    registry 是 toggle 内部 `_add`/`_remove` 的同步真值源(@MainActor
        //    @Observable, 同步内存写入), toggle await 返回后 registry 已是
        //    新真值,不受 owner/name 解析准确性影响。
        //
        // 2. 再调 resolveRepo(for:) —— 第二道防线:把本地 DB 完整字段(topics /
        //    license / forks / stars 真值)合回 displayRepo。已升级为 `findById`
        //    优先命中(详见 resolveRepo 文档段 D-24 followup 注释),避开
        //    weekly owner/name 大小写不一致漏命中陷阱;命中后 displayRepo
        //    的 isStarred 跟 registry 同步(均为 toggle 真值)。
        //
        // dong4j 2026-06-11 复现:weekly 详情第一次 star 一个 repo 后,卡片立
        // 即变实心(走 sidebar.refreshSidebar / list reload 路径),但 hero 永
        // 远空心直到切换 weekly 项目重建 view 才正常 —— 根因就是上面两步
        // 之前都没做(只调 resolveRepo,且 resolveRepo 走 owner/name 失败 →
        // 退化到 GitHub API → 写 displayRepo.isStarred=false 覆盖了刚刚 star
        // 完的真值)。
        //
        // Repo 是 value type 且 `var isStarred: Bool` 可写,直接 copy + 覆值即可。
        // ─────────────────────────────────────────────────────────────────
        let nowStarred = dependencies.starredRegistry.contains(ghRepoId: repo.id)
        var updated = repo
        updated.isStarred = nowStarred
        displayRepo = updated

        await homeViewModel.refreshSidebar()
        await homeViewModel.reloadItems(forceRefresh: true)
        if let project { await resolveRepo(for: project) }
    }

}
