//
//  ReadmeAPI.swift
//  Starcat
//
//  README 抓取与缓存协调层（Phase 2 SWR 拆分版）。
//
//  端点：
//  - GET /repos/{owner}/{repo}/readme
//    Accept: application/vnd.github.html  → 直接返回 GitHub 服务端渲染好的 HTML 片段
//
//  Phase 2 关键改动（2026-05-30，见 docs/详细设计/readme.md-渲染设计.md §12.2 / §13）：
//  把原 `fetchHTML(for:forceRefresh:)` 拆为：
//  - `cachedReadme(repoId:)` 纯读本地（不发网络）
//  - `refreshReadme(for:)` 走网络刷新（所有错误包到 `.failed`，不抛出）
//
//  这样 ViewModel 可以实现 "先读缓存立即 loaded → 判断 softTtl → 后台 fire-and-forget refresh"
//  的 stale-while-revalidate 模式，不再需要 API 层吃下 softTtl 短路。
//
//  refresh 路径详细步骤：
//  1. 读本地缓存（拿 etag / last_modified）
//  2. 带 If-None-Match / If-Modified-Since 发条件请求
//  3. 304 → 仅 touch cached_at，返回 `.notModified(refreshed)`
//     （refreshed.cachedAt 已被更新为现在，便于 UI 显示"刚刚刷新"）
//  4. 200 → upsert 新 HTML，返回 `.updated(readme)`
//  5. 404 → 删本地旧缓存，返回 `.notFound`
//  6. 边缘：304 + 本地缓存丢失 → 走 `refreshUnconditional` 不带 validator 重拉
//  7. 任何其他错误（transport / decoding / rate limit / 5xx）→ `.failed(error)`
//
//  设计意图：
//  - 选用 GitHub 服务端渲染的 HTML 而非 raw markdown，理由：
//    a) 100% GFM 兼容（任务列表 / 表格 / mermaid 等），客户端零渲染负担
//    b) 减少客户端 markdown 解析器依赖，降低安全攻击面
//    c) GitHub 已把相对图片 URL 处理成绝对 camo CDN URL，WebView 直接显示
//  - `refreshReadme` 不抛错而是返回 enum：让调用方能优雅处理"刷新失败但旧缓存还能用"的场景
//    （SWR 的核心体验：网络挂了也不打扰用户）
//
//  线程模型：调用方可在任意 actor 调用，内部所有 IO 都 async
//

import Foundation

// D-02：README 抓取从直接 `client.getBytes(path: "/repos/...")` 改为业务端点
// `client.readmeHTML(owner:repo:...)`（实现见 ReadmeHTMLAPI.swift），不再需要本文件持有
// path / accept 等底层细节。原 `readmeHTMLAccept` 常量已迁移到 ReadmeHTMLAPI.swift。

/// `refreshReadme` 的返回值。
///
/// 用 enum 而非 throws 是为了让调用方在"刷新失败但旧缓存还能用"时静默回退，
/// 不必把网络错误传到 UI 打扰用户（SWR 模式）。
enum ReadmeRefreshResult {
    /// 200：拿到新 HTML，已 upsert 到本地。
    case updated(Readme)
    /// 304：本地缓存仍有效，cached_at 已 touch（readme.cachedAt 已是最新）。
    case notModified(Readme)
    /// 404：该 repo 没有 README，本地旧缓存（若有）已被删除。
    case notFound
    /// 其他错误（transport / decoding / rate limit / 5xx / Repository 写入失败）。
    /// 调用方应优先复用 `cachedReadme` 拿到的旧值；若没有则展示 error 态。
    case failed(Error)
}

/// README API。
struct ReadmeAPI {

    /// D-02：依赖协议而非具体 actor 类型，便于单测注入 Mock。
    let client: any GitHubAPIClientProtocol
    let repository: ReadmeRepository

    /// 软过期阈值。
    ///
    /// **Phase 2 后语义变化**：本常量不再被 ReadmeAPI 自身使用，
    /// 而是供 ViewModel 通过 `isWithinSoftTtl(...)` 判断"本次自动加载是否需要后台刷新"。
    /// API 层只暴露能力，不再吃缓存决策。
    ///
    /// 选 6h 的理由：
    /// - 多数仓库 README 一天内不会变化
    /// - 用户主动"刷新"按钮可绕过（ViewModel 层 `forceRefresh: true` 时跳过本判断）
    ///
    /// 暂硬编码，Settings 面板调节留到 P2。
    static let softTtl: TimeInterval = 6 * 3600

    init(client: any GitHubAPIClientProtocol, repository: ReadmeRepository) {
        self.client = client
        self.repository = repository
    }

    // MARK: - Public

    /// 纯读本地缓存，不发网络。
    ///
    /// SWR 模式的"第一阶段"：拿到旧 HTML 立即上屏。
    /// - Returns: 缓存命中返回 Readme；未命中返回 nil
    func cachedReadme(repoId: Int64) async throws -> Readme? {
        try await repository.find(repoId: repoId)
    }

    /// 走网络刷新 README HTML 并同步本地缓存。
    ///
    /// 所有错误（含 transport / decoding / rate limit / 5xx / Repository 写入失败）
    /// 都包到 `.failed(error)` 返回，**不抛出**。
    /// 这是为了支持 SWR 模式："刷新失败但旧缓存还能用"时静默回退，不打扰用户。
    ///
    /// 本方法不做 softTtl 短路 —— 调用方应用 `isWithinSoftTtl` 自己判断是否调本方法。
    ///
    /// - Parameter repo: 目标仓库
    /// - Returns: `ReadmeRefreshResult` —— `.updated` / `.notModified` / `.notFound` / `.failed`
    func refreshReadme(for repo: Repo) async -> ReadmeRefreshResult {
        let existing: Readme?
        do {
            existing = try await repository.find(repoId: repo.id)
        } catch {
            return .failed(error)
        }

        let raw: BytesResponse
        do {
            raw = try await client.readmeHTML(
                owner: repo.owner,
                repo: repo.name,
                ifNoneMatch: existing?.etag,
                ifModifiedSince: existing?.lastModified
            )
        } catch NetworkError.notFound {
            // GitHub 返回 404 意味该 repo 没有 README；清掉本地旧缓存（防止误显示）
            if existing != nil {
                try? await repository.delete(repoId: repo.id)
            }
            return .notFound
        } catch {
            return .failed(error)
        }

        // 304 命中 → 仅 touch cached_at，返回更新过时间戳的 readme
        if raw.notModified {
            guard let cached = existing else {
                // 极端 case：本地缓存被清掉但服务端仍 304 → 兜底无条件重拉
                AppLog.network.warning("README 304 但本地缓存丢失，无条件重拉 \(repo.fullName, privacy: .public)")
                return await refreshUnconditional(repo: repo)
            }
            let now = Date()
            try? await repository.touchCachedAt(repoId: repo.id, at: now)
            var refreshed = cached
            refreshed.cachedAt = ISO8601DateFormatter.shared.string(from: now)
            return .notModified(refreshed)
        }

        // 200 → 写新缓存
        let html = String(data: raw.data, encoding: .utf8) ?? ""
        let now = Date()
        let readme = Readme(
            repoId: repo.id,
            content: nil,
            renderedHtml: html,
            etag: raw.etag,
            lastModified: raw.lastModified,
            cachedAt: ISO8601DateFormatter.shared.string(from: now),
            size: raw.data.count
        )
        do {
            try await repository.upsert(readme)
        } catch {
            return .failed(error)
        }
        return .updated(readme)
    }

    // MARK: - Private

    /// 不带 validator 的强制刷新（304 但本地缓存丢失时的兜底）。
    /// 所有错误同样包到 `.failed`，保持与 `refreshReadme` 一致的语义。
    private func refreshUnconditional(repo: Repo) async -> ReadmeRefreshResult {
        let raw: BytesResponse
        do {
            raw = try await client.readmeHTML(
                owner: repo.owner,
                repo: repo.name,
                ifNoneMatch: nil,
                ifModifiedSince: nil
            )
        } catch NetworkError.notFound {
            return .notFound
        } catch {
            return .failed(error)
        }

        let html = String(data: raw.data, encoding: .utf8) ?? ""
        let now = Date()
        let readme = Readme(
            repoId: repo.id,
            content: nil,
            renderedHtml: html,
            etag: raw.etag,
            lastModified: raw.lastModified,
            cachedAt: ISO8601DateFormatter.shared.string(from: now),
            size: raw.data.count
        )
        do {
            try await repository.upsert(readme)
        } catch {
            return .failed(error)
        }
        return .updated(readme)
    }

    // MARK: - 纯逻辑工具（可独立单测）

    /// 判断 `cached_at`（ISO8601 字符串）距 `now` 是否仍在 `softTtl` 内。
    ///
    /// 设计：
    /// - 用半开区间 `<` 判断，恰好等于 softTtl 视为已过期（保守走网络）
    /// - 字符串无法解析 → 返回 false（数据库脏数据 / 未来格式变化时保守失效）
    /// - 时钟漂移导致 cached_at 在未来 → `now - cached_at` 为负数，仍 < softTtl
    ///   → 视为命中（不去打扰 GitHub；用户系统时间错也是用户的事）
    ///
    /// 提取为静态函数是为了无依赖单测（不需要 GitHubAPIClient mock）。
    /// Phase 2 起，本函数由 `ReadmeViewModel` 直接调用决定是否需要后台 refresh。
    static func isWithinSoftTtl(cachedAt: String, now: Date, softTtl: TimeInterval) -> Bool {
        guard let cachedDate = ISO8601DateFormatter.shared.date(from: cachedAt) else {
            return false
        }
        return now.timeIntervalSince(cachedDate) < softTtl
    }
}
