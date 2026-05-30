//
//  ReadmeAPI.swift
//  Starcat
//
//  README 抓取与缓存协调层。
//
//  端点：
//  - GET /repos/{owner}/{repo}/readme
//    Accept: application/vnd.github.html  → 直接返回 GitHub 服务端渲染好的 HTML 片段
//
//  缓存策略（与 readmes 表配合）：
//  0. 软过期短路（Phase 1，2026-05-30）：
//     若本地有有效 HTML 且 cached_at 距今 < softTtl（默认 6h）且非 forceRefresh
//     → 直接返回本地缓存，不发条件请求。
//     避免用户反复切同一 repo 时浪费 GitHub Rate Limit。
//     "刷新"按钮 → forceRefresh=true → 跳过本短路。
//  1. 先 ReadmeRepository.find 取本地缓存
//  2. 若有 etag/last_modified，带 If-None-Match / If-Modified-Since 请求
//  3. 304：本地缓存仍有效 → touchCachedAt 仅刷新时间，返回旧 readme
//  4. 200：拿到新 HTML → upsert 到本地 → 返回新 readme
//  5. 404：抛 NetworkError.notFound（无 README，由 UI 显示空态）
//
//  设计意图：
//  - 选用 GitHub 服务端渲染的 HTML 而非 raw markdown，理由：
//    a) 100% GFM 兼容（任务列表 / 表格 / mermaid 等），客户端零渲染负担
//    b) 减少客户端 markdown 解析器依赖，降低安全攻击面
//    c) GitHub 已把相对图片 URL 处理成绝对 camo CDN URL，WebView 直接显示
//  - 缺点：HTML 体积比 raw markdown 略大（GitHub HTML 含 anchor / 类目）
//    但 README 端点单文件不大，整体可接受
//
//  线程模型：调用方可在任意 actor 调用，内部所有 IO 都 async
//

import Foundation

/// README HTML 抓取的 Accept 头。
private let readmeHTMLAccept = "application/vnd.github.html"

/// README API。
struct ReadmeAPI {

    let client: GitHubAPIClient
    let repository: ReadmeRepository

    /// 软过期阈值。
    ///
    /// 本地缓存的 `cached_at` 距今小于该值时，视为"足够新鲜"，
    /// 跳过条件请求直接返回缓存。
    ///
    /// 选 6h 的理由：
    /// - 多数仓库 README 一天内不会变化（Trending 也不会）
    /// - 用户主动"刷新"按钮可绕过（`forceRefresh: true`）
    /// - 不阻止 ETag 校验路径；只是"6h 内不主动校验"
    ///
    /// 暂硬编码，Settings 面板调节留到 P2。
    static let softTtl: TimeInterval = 6 * 3600

    init(client: GitHubAPIClient, repository: ReadmeRepository) {
        self.client = client
        self.repository = repository
    }

    /// 拉取并缓存 README HTML。
    ///
    /// 命中缓存（304）时，仅刷新 cached_at 不重写 HTML。
    /// 命中失败（200）时，覆盖写入。
    /// - Parameters:
    ///   - repo: 目标仓库
    ///   - forceRefresh: 若为 true，跳过 softTtl 短路，无论本地缓存多新都发条件请求。
    ///     由用户主动"刷新"按钮触发；自动加载场景保持默认 false。
    /// - Returns: 最新（或缓存命中后的旧）Readme 记录
    /// - Throws:
    ///   - `NetworkError.notFound`：该 repo 没有 README
    ///   - 其他 NetworkError：网络/限流/服务端错误
    func fetchHTML(for repo: Repo, forceRefresh: Bool = false) async throws -> Readme {
        let existing = try await repository.find(repoId: repo.id)

        // 软过期短路：本地缓存仍新鲜 + 有有效 HTML + 非强制刷新 → 直接返回
        // 这条短路在 6h 内可消化 90%+ 重复切换 repo 的场景
        if !forceRefresh,
           let cached = existing,
           let html = cached.renderedHtml,
           !html.isEmpty,
           Self.isWithinSoftTtl(cachedAt: cached.cachedAt, now: Date(), softTtl: Self.softTtl) {
            return cached
        }

        let path = "/repos/\(repo.owner)/\(repo.name)/readme"

        let raw: RawAPIResponse
        do {
            raw = try await client.getRaw(
                path: path,
                accept: readmeHTMLAccept,
                ifNoneMatch: existing?.etag,
                ifModifiedSince: existing?.lastModified
            )
        } catch NetworkError.notFound {
            // GitHub 返回 404 意味着该仓库没有 README；清掉本地旧缓存（防止误显示）
            if existing != nil {
                try? await repository.delete(repoId: repo.id)
            }
            throw NetworkError.notFound
        }

        // 304 命中 → 用本地缓存返回，只刷新 cached_at
        if raw.notModified {
            guard let cached = existing else {
                // 极端情况：本地缓存被清掉了但条件请求仍返回 304；按照"未命中"重试一次（去掉 etag）
                AppLog.network.warning("README 304 但本地缓存丢失，重新无条件拉取 \(path, privacy: .public)")
                return try await fetchHTMLWithoutValidator(repo: repo)
            }
            let now = Date()
            try? await repository.touchCachedAt(repoId: repo.id, at: now)
            return cached
        }

        // 200：写新缓存
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
        try await repository.upsert(readme)
        return readme
    }

    /// 不带 ETag 的强制刷新（304 但本地缓存丢失时的兜底）。
    private func fetchHTMLWithoutValidator(repo: Repo) async throws -> Readme {
        let path = "/repos/\(repo.owner)/\(repo.name)/readme"
        let raw = try await client.getRaw(path: path, accept: readmeHTMLAccept)
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
        try await repository.upsert(readme)
        return readme
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
    static func isWithinSoftTtl(cachedAt: String, now: Date, softTtl: TimeInterval) -> Bool {
        guard let cachedDate = ISO8601DateFormatter.shared.date(from: cachedAt) else {
            return false
        }
        return now.timeIntervalSince(cachedDate) < softTtl
    }
}
