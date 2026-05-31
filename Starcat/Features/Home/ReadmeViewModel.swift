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
    func load(repo: Repo?) {
        loadInternal(repo: repo, forceRefresh: false)
    }

    /// 重新加载当前 repo（用户点击"重试" / 详情底栏"刷新"时调用）。
    ///
    /// 与 `load(repo:)` 的差异：
    /// - 清掉 sessionNotFound 中该 repoId（README 可能刚被作者补上）
    /// - `forceRefresh: true` → 即使 cached 仍在 softTtl 内也走网络
    /// - 同一 repo + 当前是 .error → 同步转为 .loading 给反馈
    /// - 同一 repo + 当前是 .loaded → 保持显示，后台静默 refresh（SWR 体验）
    func reload(repo: Repo) {
        loadInternal(repo: repo, forceRefresh: true)
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

    /// 加载 Trending repo 的 README（不走本地数据库缓存）。
    ///
    /// 用于 TrendingRepo 等本地无持久化记录的仓库。
    func loadTrending(owner: String, repo: String) {
        currentTask?.cancel()

        let key = "\(owner)/\(repo)"

        // 切到新 repo 时立即同步设 .loading 占位
        let isSameRepo = (currentTrendingKey == key)
        currentTrendingKey = key

        if !isSameRepo {
            state = .loading
        }

        currentTask = Task { [weak self] in
            guard let self else { return }

            self.isRefreshing = true
            defer { self.isRefreshing = false }

            // 直接走网络获取（Trenging repo 无本地缓存）
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

            case .notModified, .notFound:
                self.state = .empty

            case .failed(let error):
                AppLog.network.error("Trending README 加载失败 owner=\(owner, privacy: .public) repo=\(repo, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.state = .error(message: error.localizedDescription)
            }
        }
    }

    // MARK: - 内部

    /// load / reload 的统一实现（两段式 SWR）。
    private func loadInternal(repo: Repo?, forceRefresh: Bool) {
        currentTask?.cancel()
        guard let repo else {
            currentRepoId = nil
            state = .idle
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

    /// 把 readmes.cached_at 的 ISO8601 字符串解析回 Date，便于 UI 格式化显示。
    private static func parseISO8601(_ s: String) -> Date? {
        ISO8601DateFormatter.shared.date(from: s)
    }
}
