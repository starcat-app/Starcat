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

    init(client: GitHubAPIClient, repository: ReadmeRepository) {
        self.client = client
        self.repository = repository
    }

    /// 拉取并缓存 README HTML。
    ///
    /// 命中缓存（304）时，仅刷新 cached_at 不重写 HTML。
    /// 命中失败（200）时，覆盖写入。
    /// - Parameter repo: 目标仓库
    /// - Returns: 最新（或缓存命中后的旧）Readme 记录
    /// - Throws:
    ///   - `NetworkError.notFound`：该 repo 没有 README
    ///   - 其他 NetworkError：网络/限流/服务端错误
    func fetchHTML(for repo: Repo) async throws -> Readme {
        let existing = try await repository.find(repoId: repo.id)
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
}
