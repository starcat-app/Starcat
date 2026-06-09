//
//  BackendAggregateRepoSource.swift
//  Starcat
//
//  R-01 RepoSource chain 第三节：后端单 repo 聚合接口。
//
//  ────────────────────────────────────────────────────────────────────────────
//  R-01 v1.2 实现（2026-06-09）
//  ────────────────────────────────────────────────────────────────────────────
//
//  接 weekly 后端的 `GET /api/v1/projects/{owner}/{repo}` 端点，拿到完整聚合的
//  `StarcatRepoCardDTO`（含 weekly 扩展段 + 后端 enricher 补的最新元数据），转
//  ephemeral `Repo` 返回。
//
//  设计意图：
//  - trending / weekly 详情页可显示更新更频繁的字段（后端 enricher 比客户端
//    GitHub `/repos` 拉的最新值更快）；
//  - 链顺序在 `BackendHintRepoSource` 之后，所以列表传 hint 时优先用 hint 的快路径，
//    没 hint 时（如外部 deeplink / 撤销 star 后再点入）才走聚合接口；
//  - sharing / trending 后端目前没有单 repo 聚合 endpoint，本 source 仅查 weekly。
//    如果后续 trending / sharing 也加了同类 endpoint，可以追加 fallback。
//
//  ────────────────────────────────────────────────────────────────────────────
//  错误处理（关键）
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 任何错误（鉴权失败 401 / 后端 404 / 网络超时 / 解码错）→ 返回 nil，
//    让链继续询问 GitHubFallbackRepoSource；**不抛错**，避免单 source 故障
//    击穿整条链
//  - 错误日志走 `AppLog.sync.warning`（不是 error 级别），因为本 source 设计
//    上就允许 miss
//

import Foundation

actor BackendAggregateRepoSource: RepoSource {
    let name = "BackendAggregateRepoSource"

    /// 注入的 weekly API actor。weekly 在 R-01 v1.2 时是唯一提供单 repo 聚合 endpoint 的后端。
    private let weeklyAPI: WeeklyAPI

    init(weeklyAPI: WeeklyAPI) {
        self.weeklyAPI = weeklyAPI
    }

    /// 尝试从 weekly 后端聚合 endpoint 解析 repo。
    ///
    /// hint 参数本身就是 `StarcatRepoCardDTO`，但来自列表场景；hint 可能不带 weekly 扩展段
    /// 或字段较旧（爬取后没刷新过）。本 source 的价值是**主动**调聚合 endpoint 拿"最新版本"
    /// 的卡片数据，所以不直接复用 hint。
    func tryResolve(owner: String, name: String, hint: StarcatRepoCardDTO?) async throws -> Repo? {
        do {
            let card = try await weeklyAPI.fetchProject(owner: owner, repo: name)
            // dto.toEphemeralRepo() 已处理 isStarred = false 等约束（详情页不改 DB，只 in-memory）
            return card.toEphemeralRepo()
        } catch {
            // 鉴权失败 / 404 / 解码错都退化为"未命中"，让链继续询问下一个 source。
            AppLog.sync.warning(
                "BackendAggregateRepoSource miss for \(owner, privacy: .public)/\(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
