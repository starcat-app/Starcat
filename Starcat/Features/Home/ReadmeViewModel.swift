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
//  cachedReadme(repoId:)              ← 异步读本地（GRDB 内存查询，通常 < 1ms）
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
//    ├─ .notFound           → sessionNotFound.insert + state = .empty
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
//  - `sessionNotFound: Set<Int64>` 记录 session 内已确认无 README 的 repoId
//  - 自动加载命中 → 直接走 empty 不发请求
//  - 手动 reload 清掉对应项给一次重试机会
//

import Foundation

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

    private(set) var state: LoadState = .idle
    private(set) var isRefreshing: Bool = false

    private let api: ReadmeAPI

    /// 当前加载中的 repoId，用于"切换 repo 时丢弃旧响应"。
    private var currentRepoId: Int64?

    /// 当前 in-flight 任务。新请求来时先 cancel。
    private var currentTask: Task<Void, Never>?

    /// session 内已确认"无 README"（404）的 repoId 集合。
    /// - 自动加载（`load(repo:)`）命中 → 直接 empty 不请求
    /// - 手动刷新（`reload(repo:)`）会清掉对应项，给一次重试机会
    private var sessionNotFound: Set<Int64> = []

    init(api: ReadmeAPI) {
        self.api = api
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
    /// - 清掉 sessionNotFound 中该 repoId（README 可能刚被作者补上）
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
        currentRepoId = nil
        currentTrendingKey = nil
        state = .idle
    }

    // MARK: - Trending Repo 支持

    /// 当前 Trending repo 的标识（owner/repo），用于判断是否切换了 repo。
    private var currentTrendingKey: String?

    /// 加载 Trending repo 的 README（W7+ 起：SWR 模式，与 manage `loadInternal` 同构）。
    ///
    /// 流程（与 `loadInternal` 完全对齐，只是缓存路径走 `cachedTrendingReadme(fullName:)`）：
    /// 1. 切到新 repo → 同步设 `.loading` 占位（避免 await 期间显示上一个 repo 的 README）
    /// 2. 读 `trending_readmes` 表（按 `owner/repo` PK）→ 命中立即上屏 `.loaded`
    /// 3. 不论缓存是否命中，都强制走网络刷新（dong4j 决策 ttl_c：trending 不设 TTL）
    /// 4. 200 / 304 → 覆盖或 touch cached_at；404 → 删本地 + `.empty`；其他错误 → 有缓存就静默
    ///
    /// 与 `loadInternal` 的差异：
    /// - 缓存读写 PK 是 `full_name`（owner/repo）而非 `repo_id`
    /// - 没有 manage 的 session 404 集合（trending repo 切换频繁，没必要在 session 内禁止重试）
    /// - 没有 forceRefresh 参数：调用方每次都希望走 SWR（无 TTL 短路）
    ///
    /// - Parameter isLoggedIn: 用户是否已登录。用于判断 403 是否因未授权（应显示"请登录"而非"加载失败"）。
    func loadTrending(owner: String, repo: String, isLoggedIn: Bool) {
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
            currentTrendingKey = key
            currentRepoId = nil
            state = .requiresLogin
            return
        }

        // 切到新 repo 时立即同步设 .loading 占位（race 防护）
        let isSameRepo = (currentTrendingKey == key)
        currentTrendingKey = key
        currentRepoId = nil // 进 trending 路径时清掉 manage 路径的 race key

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

            // 第二阶段：强制走网络刷新（dong4j 决策 ttl_c：trending 不设 TTL，每次都拉网络覆盖）
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
            currentRepoId = nil
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
            currentRepoId = repo.id
            state = .requiresLogin
            return
        }

        // session 404 短路：仅自动加载受其影响；手动 reload 会清掉
        if forceRefresh {
            sessionNotFound.remove(repo.id)
        } else if sessionNotFound.contains(repo.id) {
            currentRepoId = repo.id
            state = .empty
            return
        }

        // 切到新 repo 时立即同步设 .loading 占位，避免 await cachedReadme 期间
        // 显示上一个 repo 的 README（visual race）。
        // 同一 repo + .error 也清掉转 .loading，给用户"正在重试"反馈。
        // 同一 repo + .loaded：保持显示，后台 refresh 时再无感更新（SWR 体验）。
        let isSameRepo = (currentRepoId == repo.id)
        currentRepoId = repo.id
        let requestedId = repo.id

        if !isSameRepo {
            state = .loading
        } else if forceRefresh, case .error = state {
            state = .loading
        }

        currentTask = Task { [weak self] in
            guard let self else { return }
            
            self.isRefreshing = true
            defer { self.isRefreshing = false }

            // 第一阶段：读本地缓存
            let cached: Readme?
            do {
                cached = try await self.api.cachedReadme(repoId: requestedId)
            } catch {
                cached = nil
                AppLog.network.warning("README cachedReadme 失败 repo=\(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            guard !Task.isCancelled, self.currentRepoId == requestedId else { return }

            // 用缓存立即上屏（如果有有效内容）
            let hasUsableCache: Bool
            if let c = cached, let html = c.renderedHtml, !html.isEmpty {
                let cachedAt = Self.parseISO8601(c.cachedAt) ?? Date()
                self.state = .loaded(html: html, cachedAt: cachedAt)
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
            let result = await self.api.refreshReadme(for: repo)
            guard !Task.isCancelled, self.currentRepoId == requestedId else { return }

            switch result {
            case .updated(let readme):
                if let html = readme.renderedHtml, !html.isEmpty {
                    let cachedAt = Self.parseISO8601(readme.cachedAt) ?? Date()
                    self.state = .loaded(html: html, cachedAt: cachedAt)
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
                }
                // html 为空的 304 理论上不该发生（refreshReadme 会走 unconditional 兜底），
                // 防御性不动 state。

            case .notFound:
                self.sessionNotFound.insert(requestedId)
                self.state = .empty

            case .failed(let error):
                // 未登录被 GitHub 拒绝（匿名配额耗尽 403→rateLimited / 401 / clientError 403）→ 引导登录
                if !isLoggedIn, Self.isUnauthenticatedBlock(error) {
                    self.state = .requiresLogin
                    return
                }

                if hasUsableCache {
                    // SWR 兜底：有缓存就静默，不打扰用户。debug 日志方便排查
                    AppLog.network.debug("README 后台刷新失败但本地有缓存，保持已显示 repo=\(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                } else {
                    AppLog.network.error("README 加载失败 repo=\(repo.fullName, privacy: .public) force=\(forceRefresh, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.state = .error(message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Helpers

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
}
