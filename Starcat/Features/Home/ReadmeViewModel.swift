//
//  ReadmeViewModel.swift
//  Starcat
//
//  README 详情视图的 ViewModel（Phase 2 SWR 模式）。
//
//  状态机：
//  - idle：尚未加载（初始态或重置后）
//  - loading：正在请求（仅在"无可用缓存"时显示）
//  - loaded(html, cachedAt)：已加载并准备渲染
//  - empty：该 repo 没有 README（404 或本地 session 缓存的"已知 404"）
//  - error(message)：网络或解析错误（且无可用缓存兜底）
//
//  Phase 2 加载流程（stale-while-revalidate，2026-05-30）：
//  ```
//  load(repo)
//    │
//    ├─ 切到新 repo → state = .loading 占位（防止显示旧 repo README）
//    │
//    ▼
//  cachedReadme(for:)                 ← 异步读本地（GRDB 内存查询，通常 < 1ms）
//    │
//    ├─ 有缓存 → state = .loaded(html, cachedAt) 立即上屏
//    └─ 无缓存 → 保持 state = .loading
//    │
//    ▼
//  判断是否需要后台 refresh：
//    - forceRefresh=true（用户主动刷新）→ 必刷
//    - 无可用缓存 → 必刷
//    - 缓存仍在 softTtl(6h) 内 → 不刷（直接结束）
//    - 缓存已过期 → 必刷
//    │
//    ▼
//  refreshReadme(for:)                ← 后台 fire-and-forget
//    │
//    ├─ .updated(readme)    → state = .loaded(新 html, 新 cachedAt)   无感替换
//    ├─ .notModified(readme) → state = .loaded(原 html, 新 cachedAt)  仅刷新"缓存于..."显示
//    ├─ .notFound           → availability.markNotFound + state = .empty
//    └─ .failed(error)      → 有缓存 → 静默 debug 日志; 无缓存 → state = .error
//  ```
//
//  设计约束：
//  - @MainActor：所有状态写入都在主线程，避免 SwiftUI 触发警告
//  - 把 Task 自身存起来，新请求来时 cancel 旧任务；不依赖 view 的 task(id:) 因为我们要更细的取消粒度
//  - 切到新 repo 时立即同步设 .loading 占位：cachedReadme 是 async，await 期间 state 还是旧值
//    会让用户看到 "repo B 详情区显示 repo A README" 一帧。同步占位消除这个 race
//  - **`isRefreshing` 状态不暴露给 UI**（按 §12.2 评审决策）：已显示的 README 被无感替换符合预期，
//    加 loading spinner 反而吵
//
//  Session 404 缓存：
//  - 状态由共享对象 `ReadmeAvailability`（`AppDependencies` 持有的单例）承载，
//    跨 manage / active 等多个 VM 实例共享一份"已知不存在"集合（HOM-201 P0-2，2026-06-14）
//  - 自动加载命中 → 直接走 empty 不发请求
//  - 手动 reload 清掉对应项给一次重试机会
//

import Foundation

extension Notification.Name {

    /// README 加载完成事件（manage 路径 only，2026-06-12 阅读状态 v2 引入）。
    ///
    /// **发射时机**：`ReadmeViewModel.loadInternal` 路径下任一次 `state = .loaded(...)`
    /// 写入后立即 post。trending 路径（loadTrending）**不发射**——trending repo 大多是
    /// ephemeral（repo.id = ghRepoId 但 `isStarred = false`），不属于用户库，不应触发
    /// 阅读状态升级。
    ///
    /// **userInfo**：
    /// - `"repoId": Int64` —— 加载完成的 repo.id（保证 != 0；ephemeral / id=0 不 post）
    ///
    /// **订阅方**：`RepoNotesSection`（详情页"阅读状态"段），匹配当前 repo.id 后调用
    /// `repoNoteRepository.markAsReadIfNeeded(repoId:)` 把 unread 升级为 read。
    /// 接口设计上是事件流而非直接调用，因为 `ReadmeViewModel` 通过 environment 注入
    /// 路径在 4 个详情页（manage / trending / weekly / activity）并不完全一致
    /// （manage 在 HomeView 最外层注入，其他 3 个在 ContentView 子树内注入），
    /// RepoLocalSections / RepoNotesSection 在 Scaffold 的 metadataPanel 内挂载，
    /// trending/weekly/activity Shell 的 environment 链不直达。NotificationCenter
    /// 完全解耦发射方与订阅方，零 environment 改造。
    static let readmeDidLoad = Notification.Name("StarcatReadmeDidLoad")
}

@MainActor
@Observable
final class ReadmeViewModel {

    /// 加载状态。
    enum LoadState: Equatable {
        case idle
        case loading
        /// `cachedAt`：本地缓存写入时间，UI 可显示"缓存于..."
        case loaded(html: String, cachedAt: Date)
        case empty
        /// 需要登录才能查看（403 且用户未登录）。
        case requiresLogin
        case error(message: String)
    }

    private(set) var state: LoadState = .idle {
        didSet {
            switch state {
            case .loaded(let html, _):
                // 只在文档发布时计算一次进程内指纹。SwiftUI 后续 body 重算直接复用，
                // 304 仅更新时间戳时指纹保持不变，不会让 WKWebView 无谓重载。
                activeDocumentID = "\(html.utf8.count):\(html.hashValue)"
            case .loading:
                // 加载新仓期间保留旧指纹，ReadmeStateView 会用它维持原生 WebView 身份。
                break
            case .idle, .empty, .requiresLogin, .error:
                activeDocumentID = nil
            }
        }
    }
    private(set) var isRefreshing: Bool = false

    /// 当前已发布 HTML 的进程内轻量身份，仅供视图更新判定，不持久化也不跨进程比较。
    private(set) var activeDocumentID: String?

    /// UI 判断 `state` 是否仍服务当前 manage 详情（与 `ReadmeStateView.contentScope` 对齐）。
    private(set) var activeRepoId: Int64?

    /// UI 判断 `state` 是否仍服务当前 trending / weekly 详情。
    private(set) var activeTrendingKey: String?

    private let api: ReadmeAPI
    /// Private / Internal 仓库专用 API。未注入时 Private 请求不得回退主 OAuth。
    private let privateAPI: ReadmeAPI?

    /// 当前加载中的 repoId，用于"切换 repo 时丢弃旧响应"（与 `activeRepoId` 同步写入）。
    private var currentRepoId: Int64?

    /// 当前 in-flight 任务。新请求来时先 cancel。
    private var currentTask: Task<Void, Never>?

    /// session 内已确认"无 README"（404）的状态承载对象。
    ///
    /// HOM-201 P0-2（2026-06-14）：原 `sessionNotFound: Set<Int64>` 字段提升为
    /// `AppDependencies` 持有的单例 `ReadmeAvailability`。本字段是它的注入引用，
    /// manage（HomeView 全局 VM）和 active（每个 Shell 局部 VM）共用同一份状态，
    /// 跨 VM 命中 404 短路。详见 `ReadmeAvailability.swift` 文件头。
    private let availability: ReadmeAvailability

    /// 详情页 HTML 拉到（200 / 304）后触发的可选回调（**manage 路径 only**）。
    ///
    /// **2026-06-13 dong4j 补救 B 引入**。
    /// 文档 `docs/3-设计/详细设计/26-向量搜索改进.md` §6 关键流程表承诺的「详情页 README 拉到 →
    /// 异步补 raw Markdown 落 `readmes.content` + 调 `refreshIndexIfChanged`」触发源，
    /// 之前 2026-06-12 落地时漏接，2026-06-13 通过本回调补齐。
    ///
    /// **调用时机**：`loadInternal` 的 `.updated` / `.notModified` 分支拿到非空 html 后；
    /// **不调用**：`.notFound` / `.failed` / 缓存命中（首段）/ `loadTrending`（trending 路径）。
    ///
    /// **典型实现**（由 `HomeView` 装配 manage 路径的 `ReadmeViewModel` 时挂入）：
    /// 1. `Task { @MainActor in ... }` fire-and-forget，不阻塞详情页渲染；
    /// 2. `await readmeAPI.refreshMarkdownIfNeeded(for: repo)` 仅在 `readmes.content` 为空时
    ///    真发 GitHub raw markdown 请求；
    /// 3. 若返回 `.updated` 才接着 `await semanticSearchService.refreshIndexIfChanged(for: repo)`
    ///    走 diff 判定 + 视情况重建向量；`.notModified`（content 已存在）不动以省 embedding API。
    ///
    /// **为何 trending 路径不调**：trending repo 多为 ephemeral（用户没 star），不属于本地
    /// 库的 readmes 表 / repo_embeddings 表，补 markdown / 触发向量重建都无意义。
    private let onHTMLLoaded: ((Repo) -> Void)?
    /// 匿名遥测入口。仅在 manage 路径 README HTML 成功上屏后记录事件，不带 repo 信息。
    private let telemetryManager: TelemetryManager?

    init(
        api: ReadmeAPI,
        privateAPI: ReadmeAPI? = nil,
        availability: ReadmeAvailability,
        onHTMLLoaded: ((Repo) -> Void)? = nil,
        telemetryManager: TelemetryManager? = nil
    ) {
        self.api = api
        self.privateAPI = privateAPI
        self.availability = availability
        self.onHTMLLoaded = onHTMLLoaded
        self.telemetryManager = telemetryManager
    }

    // MARK: - Actions

    /// 加载指定 repo 的 README（SWR 模式：有缓存立即上屏 + 后台条件刷新）。
    /// - Parameter repo: 目标仓库；nil 表示重置到 idle
    /// - Parameter isLoggedIn: 用户是否已登录（用于判断 403 是否因未授权）
    func load(repo: Repo?, isLoggedIn: Bool) {
        loadInternal(repo: repo, forceRefresh: false, isLoggedIn: isLoggedIn)
    }

    /// 重新加载当前 repo（用户点击"重试" / 详情底栏"刷新"时调用）。
    ///
    /// 与 `load(repo:)` 的差异：
    /// - 清掉 availability 中该 repoId 的 404 标记（README 可能刚被作者补上）
    /// - `forceRefresh: true` → 即使 cached 仍在 softTtl 内也走网络
    /// - 同一 repo + 当前是 .error → 同步转为 .loading 给反馈
    /// - 同一 repo + 当前是 .loaded → 保持显示，后台静默 refresh（SWR 体验）
    /// - Parameter isLoggedIn: 用户是否已登录（用于判断 403 是否因未授权）
    func reload(repo: Repo, isLoggedIn: Bool) {
        loadInternal(repo: repo, forceRefresh: true, isLoggedIn: isLoggedIn)
    }

    /// 重置到 idle（视图从 selected → unselected 时调用）。
    func reset() {
        currentTask?.cancel()
        clearActiveTargets()
        state = .idle
    }

    // MARK: - Trending Repo 支持

    /// 当前 Trending repo 的标识（owner/repo），用于判断是否切换了 repo（与 `activeTrendingKey` 同步写入）。
    private var currentTrendingKey: String?

    /// 加载 Trending repo 的 README（W7+ 起：SWR 模式，与 manage `loadInternal` 同构）。
    ///
    /// 流程（与 `loadInternal` 完全对齐，只是缓存路径走 `cachedTrendingReadme(fullName:)`）：
    /// 1. 切到新 repo → 同步设 `.loading` 占位（避免 await 期间显示上一个 repo 的 README）
    /// 2. 读 `trending_readmes` 表（按 `owner/repo` PK）→ 命中立即上屏 `.loaded`
    /// 3. 判断是否需要后台 refresh（HOM-201 P1-4，2026-06-14：与 manage 对齐用 softTtl=6h
    ///    短路；forceRefresh / 无可用缓存 / 缓存过期 → 必刷）
    /// 4. 200 / 304 → 覆盖或 touch cached_at；404 → 删本地 + `.empty`；其他错误 → 有缓存就静默
    ///
    /// 与 `loadInternal` 的差异：
    /// - 缓存读写 PK 是 `full_name`（owner/repo）而非 `repo_id`
    /// - 没有 manage 的 session 404 集合（trending repo 切换频繁，没必要在 session 内禁止重试）
    ///
    /// HOM-201 P1-4（2026-06-14）：把 trending 路径的 TTL 行为对齐到 manage（softTtl=6h）。
    /// 此前 dong4j 决策 `ttl_c` 让 trending 每次都强制走网络;但配合 P1-1 hover prefetch
    /// 后,每次进详情都打 GitHub 304 太浪费 60/h 匿名配额。改为:
    /// - 自动加载(`forceRefresh: false`) → 命中 softTtl 6h 内的缓存就跳过网络;
    /// - 用户主动刷新(详情页底部刷新按钮 / 列表 refreshable / forceRefresh: true) → 必刷。
    /// 用户感知不到差异(6h 内即便不刷网络,本地 cache 仍是最新),配额节省显著。
    ///
    /// - Parameter isLoggedIn: 用户是否已登录。用于判断 403 是否因未授权（应显示"请登录"而非"加载失败"）。
    /// - Parameter forceRefresh: 用户主动触发刷新(详情页底部 cacheFooter / 列表 refreshable)
    ///   时传 true,绕过 softTtl 短路。默认 false。
    func loadTrending(owner: String, repo: String, isLoggedIn: Bool, forceRefresh: Bool = false) {
        currentTask?.cancel()

        let key = "\(owner)/\(repo)"

        // v1.6 修订（2026-06-10, dong4j bug 反馈）：未登录态下禁用 README 渲染。
        //
        // 与 `loadInternal` 同义（详见该函数 v1.6 修订段长注释）：trending 路径同样
        // 是 SWR 两段式,未登录用户也会出现「闪现 stale cache → 跳登录提示」的跳帧。
        // 入口同步覆盖 state 为 .requiresLogin,跳过所有缓存读取与网络刷新。
        //
        // 注意:trending 路径的 currentTrendingKey **仍要更新**,否则用户登录后
        // selectedTrendingRepoID 不变 → onChange 不重触发 loadTrending,但内部 key
        // 还是上一个 repo,后续命中"同 repo 不变 state"的快速路径会出错。
        guard isLoggedIn else {
            bindTrendingTarget(fullName: key)
            state = .requiresLogin
            return
        }

        // 切到新 repo 时立即同步设 .loading 占位（race 防护）
        let isSameRepo = (currentTrendingKey == key)
        bindTrendingTarget(fullName: key)

        if !isSameRepo {
            state = .loading
        }

        currentTask = Task { [weak self] in
            guard let self else { return }

            self.isRefreshing = true
            defer { self.isRefreshing = false }

            // 第一阶段：读本地缓存（trending_readmes 表，PK = full_name）
            let cached = await self.api.cachedTrendingReadme(fullName: key)
            guard !Task.isCancelled, self.currentTrendingKey == key else { return }

            // 用缓存立即上屏（如果有有效内容）
            let hasUsableCache: Bool
            if let c = cached, let html = c.renderedHtml, !html.isEmpty {
                let cachedAt = Self.parseISO8601(c.cachedAt) ?? Date()
                self.state = .loaded(html: html, cachedAt: cachedAt)
                hasUsableCache = true
            } else {
                if case .loading = self.state {
                    // 已是 loading，不变
                } else {
                    self.state = .loading
                }
                hasUsableCache = false
            }

            // 第二阶段：判断是否需要后台 refresh(与 loadInternal 同构,P1-4)
            // - forceRefresh=true(用户主动) → 必刷
            // - 无可用缓存 → 必刷
            // - cached 在 softTtl(6h) 内 → 不刷直接结束
            // - cached 过期 → 必刷
            let needsRefresh: Bool
            if forceRefresh {
                needsRefresh = true
            } else if !hasUsableCache {
                needsRefresh = true
            } else if let c = cached,
                      ReadmeAPI.isWithinSoftTtl(
                        cachedAt: c.cachedAt,
                        now: Date(),
                        softTtl: ReadmeAPI.softTtl
                      ) {
                needsRefresh = false
            } else {
                needsRefresh = true
            }

            if !needsRefresh { return }

            // 第三阶段：后台 refresh(不抛错,所有错误都包到 .failed)
            let result = await self.api.refreshTrendingReadme(owner: owner, repo: repo)
            guard !Task.isCancelled, self.currentTrendingKey == key else { return }

            switch result {
            case .updated(let readme):
                if let html = readme.renderedHtml, !html.isEmpty {
                    let cachedAt = Self.parseISO8601(readme.cachedAt) ?? Date()
                    self.state = .loaded(html: html, cachedAt: cachedAt)
                } else {
                    self.state = .empty
                }

            case .notModified(let readme):
                // 304：html 没变，cachedAt 已被 touched。更新 state 让 UI 的 "缓存于 ..." 刷新到"刚刚"。
                if let html = readme.renderedHtml, !html.isEmpty {
                    let cachedAt = Self.parseISO8601(readme.cachedAt) ?? Date()
                    self.state = .loaded(html: html, cachedAt: cachedAt)
                }
                // html 为空的 304 理论上不该发生（refreshTrendingUnconditional 会兜底），防御性不动 state

            case .notFound:
                self.state = .empty

            case .failed(let error):
                // 未登录被 GitHub 拒绝（匿名配额耗尽 403→rateLimited / 401 / clientError 403）→ 引导登录
                if !isLoggedIn, Self.isUnauthenticatedBlock(error) {
                    self.state = .requiresLogin
                    return
                }

                if hasUsableCache {
                    // SWR 兜底：有缓存就静默，不打扰用户。debug 日志方便排查
                    AppLog.network.debug("Trending README 后台刷新失败但本地有缓存，保持已显示 owner=\(owner, privacy: .public) repo=\(repo, privacy: .public): \(error.localizedDescription, privacy: .public)")
                } else {
                    AppLog.network.error("Trending README 加载失败 owner=\(owner, privacy: .public) repo=\(repo, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.state = .error(message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 内部

    /// load / reload 的统一实现（两段式 SWR）。
    /// - Parameter isLoggedIn: 用户是否已登录。用于判断 403 是否因未授权（应显示"请登录"而非"加载失败"）。
    private func loadInternal(repo: Repo?, forceRefresh: Bool, isLoggedIn: Bool) {
        currentTask?.cancel()
        guard let repo else {
            clearActiveTargets()
            state = .idle
            return
        }

        // ────────────────────────────────────────────────────────────────────
        // v1.6 修订（2026-06-10, dong4j bug 反馈）：未登录态下禁用 README 渲染
        // ────────────────────────────────────────────────────────────────────
        //
        // 问题：未登录用户点 repo 详情页时,会出现「先闪现已缓存 README → 跳到
        // 登录提示」的视觉跳帧。
        //
        // 根因：原 SWR 路径下,未登录用户的请求流：
        //   1. 第一阶段读 cached → 命中（曾登录用户留下的缓存）→ state = .loaded
        //      → WebView 渲染 stale 缓存（用户看到 README 内容）
        //   2. 第二阶段强制走网络 refresh → GitHub 401/403/匿名配额耗尽
        //   3. catch error → `if !isLoggedIn { state = .requiresLogin }` →
        //      WebView 切到登录提示（用户看到"跳帧"到登录页）
        //
        // dong4j 产品决策：未登录用户**根本不能看 README**（即便本地有缓存或匿名
        // 配额够用）→ 入口立即同步设 .requiresLogin,跳过所有 SWR 路径,既消除
        // 跳帧又明确引导登录。
        //
        // 关键约束：
        // - 必须**同步**设 state（不能 await）—— SwiftUI 一帧 commit 即生效;
        // - 必须**强制覆盖** state（即便上一个 repo 是 .loaded）——`currentTask?.cancel()`
        //   只能阻止 future write,不会回滚已写的 state;
        // - 放在 `guard let repo else` 之后,nil repo 仍走 .idle（取消选择不弹登录）;
        // - 不影响登录用户的 SWR 体验——已登录用户分支完全没动。
        guard isLoggedIn else {
            bindManageTarget(repoId: repo.id)
            state = .requiresLogin
            return
        }

        // session 404 短路：仅自动加载受其影响；手动 reload 会清掉。
        // HOM-201 P0-2（2026-06-14）：状态来自跨 VM 共享的 `ReadmeAvailability`，
        // manage 命中后切到 active 看同 repo 也能短路掉网络请求（详见类头注释）。
        if forceRefresh {
            availability.clearNotFound(repoId: repo.id)
        } else if availability.isKnownNotFound(repoId: repo.id) {
            bindManageTarget(repoId: repo.id)
            state = .empty
            return
        }

        // 切到新 repo 时立即同步设 .loading 占位，避免 await cachedReadme 期间
        // 显示上一个 repo 的 README（visual race）。
        // 同一 repo + .error 也清掉转 .loading，给用户"正在重试"反馈。
        // 同一 repo + .loaded：保持显示，后台 refresh 时再无感更新（SWR 体验）。
        let isSameRepo = (currentRepoId == repo.id)
        bindManageTarget(repoId: repo.id)
        let requestedId = repo.id

        if !isSameRepo {
            state = .loading
        } else if forceRefresh, case .error = state {
            state = .loading
        }

        currentTask = Task { [weak self] in
            guard let self else { return }
            // Private 仓库绝不回退主 OAuth API。GitHub App 未连接时 provider 返回 nil，
            // 请求会失败并保留旧本地缓存，不会把仓库名发送到公共 Trending/Discovery。
            let selectedAPI = repo.isPrivate ? self.privateAPI : self.api
            
            self.isRefreshing = true
            defer { self.isRefreshing = false }
            var didTrackReadmeOpened = false

            // 第一阶段：读本地缓存
            //
            // HOM-201 P0-1（2026-06-14）：传 repo 而非 repoId,让 ReadmeAPI 在 manage 表
            // 未命中时兜底查 `trending_readmes`（按 fullName）并 promote 到 manage 表
            // ——用户在 trending 详情读过 README + star + 切到 manage 详情时零网络复用。
            let cached: Readme?
            do {
                cached = try await selectedAPI?.cachedReadme(for: repo)
            } catch {
                cached = nil
                AppLog.network.warning("README cachedReadme 失败 repoId=\(repo.id): \(error.localizedDescription, privacy: .public)")
            }

            guard !Task.isCancelled, self.currentRepoId == requestedId else { return }

            // 用缓存立即上屏（如果有有效内容）
            let hasUsableCache: Bool
            if let c = cached, let html = c.renderedHtml, !html.isEmpty {
                let cachedAt = Self.parseISO8601(c.cachedAt) ?? Date()
                self.state = .loaded(html: html, cachedAt: cachedAt)
                self.trackReadmeOpenedOnce(&didTrackReadmeOpened)
                // 阅读状态 v2：缓存命中即视为"已加载"，派发事件让笔记段升级 unread → read。
                self.postReadmeLoaded(repoId: requestedId)
                // 2026-06-13 dong4j 补救 B：cache 命中分支也触发——高频路径（用户重复打开
                // 同 repo / cache 在 6h softTtl 内）会跳过下方网络刷新阶段，不走 .updated /
                // .notModified，必须在这里 hook 才能让"看详情页 = 自动丰富 markdown"成立。
                // 后续若 cache 过期再进网络分支，会再触发一次；refreshMarkdownIfNeeded 内部
                // 对 content 非空短路 .notModified，重复触发 cheap（仅一次本地 DB 查询）。
                if !repo.isPrivate {
                    self.onHTMLLoaded?(repo)
                }
                hasUsableCache = true
            } else {
                // 无可用缓存：保持 .loading（之前在入口已设置；同 repo 且无 cache 的极端 case 也补一下）
                if case .loading = self.state {
                    // 已是 loading，不变
                } else {
                    self.state = .loading
                }
                hasUsableCache = false
            }

            // 第二阶段：判断是否需要后台 refresh
            let needsRefresh: Bool
            if forceRefresh {
                needsRefresh = true
            } else if !hasUsableCache {
                needsRefresh = true
            } else if let c = cached,
                      ReadmeAPI.isWithinSoftTtl(
                        cachedAt: c.cachedAt,
                        now: Date(),
                        softTtl: ReadmeAPI.softTtl
                      ) {
                needsRefresh = false // 缓存仍新鲜，不打扰 GitHub
            } else {
                needsRefresh = true
            }

            if !needsRefresh { return }

            // 第三阶段：后台 refresh（不抛错，所有错误都包到 .failed）
            guard let selectedAPI else {
                if !hasUsableCache {
                    self.state = .error(message: String.l10n("project.access.state.disconnected.detail"))
                }
                return
            }
            let result = await selectedAPI.refreshReadme(for: repo)
            guard !Task.isCancelled, self.currentRepoId == requestedId else { return }

            switch result {
            case .updated(let readme):
                if let html = readme.renderedHtml, !html.isEmpty {
                    let cachedAt = Self.parseISO8601(readme.cachedAt) ?? Date()
                    self.state = .loaded(html: html, cachedAt: cachedAt)
                    self.trackReadmeOpenedOnce(&didTrackReadmeOpened)
                    // 阅读状态 v2：网络刷新成功，再 post 一次（幂等：repository 端
                    // markAsReadIfNeeded 对 read/using 行 no-op，不会重复升级）。
                    self.postReadmeLoaded(repoId: requestedId)
                    // 2026-06-13 dong4j 补救 B：异步补 raw markdown + 视情况触发向量重建。
                    // fire-and-forget 由回调实现方自己管 Task；这里只负责告知"HTML 到位"。
                    if !repo.isPrivate {
                        self.onHTMLLoaded?(repo)
                    }
                } else {
                    // GitHub 返回 200 但 body 为空（极少见）→ 视作 empty
                    self.state = .empty
                }

            case .notModified(let readme):
                // 304：html 没变，cachedAt 已被 touched。
                // 更新 state 让 UI 的 "缓存于 ..." footer 刷新到 "刚刚"。
                // WebView 因 ReadmeKey 一致不会 reload，不闪。
                if let html = readme.renderedHtml, !html.isEmpty {
                    let cachedAt = Self.parseISO8601(readme.cachedAt) ?? Date()
                    self.state = .loaded(html: html, cachedAt: cachedAt)
                    self.trackReadmeOpenedOnce(&didTrackReadmeOpened)
                    // 304 路径同样视为"加载完成"事件；与上方两处幂等。
                    self.postReadmeLoaded(repoId: requestedId)
                    // 2026-06-13 补救 B：304 路径也触发——HTML 没变但 `readmes.content`
                    // 可能为空（用户从未跑过 SemanticIndexBuilder / 之前是新 user），
                    // 给它一次懒补 markdown 的机会；refreshMarkdownIfNeeded 内部 content
                    // 非空时短路 .notModified，不会无谓打 GitHub。
                    if !repo.isPrivate {
                        self.onHTMLLoaded?(repo)
                    }
                }
                // html 为空的 304 理论上不该发生（refreshReadme 会走 unconditional 兜底），
                // 防御性不动 state。

            case .notFound:
                self.availability.markNotFound(repoId: requestedId)
                self.state = .empty

            case .failed(let error):
                // 未登录被 GitHub 拒绝（匿名配额耗尽 403→rateLimited / 401 / clientError 403）→ 引导登录
                if !isLoggedIn, Self.isUnauthenticatedBlock(error) {
                    self.state = .requiresLogin
                    return
                }

                if hasUsableCache {
                    // SWR 兜底：有缓存就静默，不打扰用户。debug 日志方便排查
                    AppLog.network.debug("README 后台刷新失败但本地有缓存，保持已显示 repoId=\(repo.id): \(error.localizedDescription, privacy: .public)")
                } else {
                    AppLog.network.error("README 加载失败 repoId=\(repo.id) force=\(forceRefresh, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.state = .error(message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Helpers

    /// 派发 README 加载完成事件（阅读状态 v2，2026-06-12）。
    ///
    /// **守卫**：`repoId != 0` —— ephemeral repo（trending / weekly fallback）显式跳过，
    /// 不污染 `repo_notes` 表。manage 路径的 repo.id 都是真 DB 主键，必非 0。
    ///
    /// 仅由 `loadInternal` 调用（manage 路径）；trending 路径不调用。
    private func postReadmeLoaded(repoId: Int64) {
        guard repoId != 0 else { return }
        NotificationCenter.default.post(
            name: .readmeDidLoad,
            object: nil,
            userInfo: ["repoId": repoId]
        )
    }

    /// 同一次 load 周期只记录一次，避免 cache 命中后后台 304 再重复计数。
    private func trackReadmeOpenedOnce(_ didTrack: inout Bool) {
        guard !didTrack else { return }
        didTrack = true
        telemetryManager?.track(.readmeOpened)
    }

    /// 判断"未登录时 GitHub 拒绝请求"的错误——若是，UI 应引导登录而非展示原始报错。
    ///
    /// 为什么不只看 403/clientError：
    /// 未登录用户请求公开 README 走的是 GitHub **匿名配额 60 次/小时**。配额耗尽后 GitHub
    /// 返回 `403 + X-RateLimit-Remaining: 0 + "API rate limit exceeded"`，被 `GitHubAPIClient`
    /// 映射成 **`.rateLimited`**（不是 `.clientError(403)`）——这正是之前"未登录还报『请求过于频繁』"
    /// 的根因。另外 403 也可能映射成 `.unauthorized`（消息不含 rate limit）或 `.clientError(403)`。
    /// 对未登录用户而言，这三种的解法**都是登录**（配额升到 5000/h 或获得授权），故统一引导登录。
    ///
    /// 已登录用户的同类错误不会走到这里——调用方用 `!isLoggedIn` 作前置门控，
    /// 已登录的 `.rateLimited` 仍应如实展示"请求过于频繁"。
    private static func isUnauthenticatedBlock(_ error: Error) -> Bool {
        guard let networkError = error as? NetworkError else { return false }
        switch networkError {
        case .unauthorized, .rateLimited:
            return true
        case .clientError(statusCode: 403, _):
            return true
        default:
            return false
        }
    }

    /// 把 readmes.cached_at 的 ISO8601 字符串解析回 Date，便于 UI 格式化显示。
    private static func parseISO8601(_ s: String) -> Date? {
        ISO8601DateFormatter.shared.date(from: s)
    }

    private func bindManageTarget(repoId: Int64) {
        currentRepoId = repoId
        activeRepoId = repoId
        currentTrendingKey = nil
        activeTrendingKey = nil
    }

    private func bindTrendingTarget(fullName: String) {
        currentTrendingKey = fullName
        activeTrendingKey = fullName
        currentRepoId = nil
        activeRepoId = nil
    }

    private func clearActiveTargets() {
        currentRepoId = nil
        activeRepoId = nil
        currentTrendingKey = nil
        activeTrendingKey = nil
    }
}
