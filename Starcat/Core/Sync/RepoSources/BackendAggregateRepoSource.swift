//
//  BackendAggregateRepoSource.swift
//  Starcat
//
//  R-01 RepoSource chain 第三节：后端单 repo 聚合接口（**R-01 内永远返回 nil**）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  现状（R-01 占位实现）
//  ────────────────────────────────────────────────────────────────────────────
//
//  trending / weekly / sharing 后端目前没有「单 repo 聚合 endpoint」（如
//  `GET /api/v1/repos/{owner}/{repo}` 返回单个 StarcatRepoCardDTO）。
//  本 source 永远返回 nil，链会继续询问 GitHubFallbackRepoSource。
//
//  ────────────────────────────────────────────────────────────────────────────
//  Phase 2 扩展点（标记 P2 / 后端联动）
//  ────────────────────────────────────────────────────────────────────────────
//
//  当后端实现单 repo 聚合 endpoint 后，本 source 升级为：
//      1. 调 backend `GET /api/v1/repos/{owner}/{repo}`
//      2. 拿到 `StarcatRepoCardDTO`
//      3. `dto.toEphemeralRepo()` 返回
//
//  好处：① trending / weekly 详情页可显示更新更频繁的字段（后端 enricher
//  比 GitHub `/repos` 拉的最新值更快）；② 单接口可同时返回 trending / weekly
//  扩展段（contributor 列表 / 期号），免得详情页二次 fetch。
//
//  本 source 故意先建好链节点，让未来加 endpoint 时只动本文件，不动 chain 装配。
//

import Foundation

struct BackendAggregateRepoSource: RepoSource {
    let name = "BackendAggregateRepoSource"

    /// R-01 占位实现：永远返回 nil，链继续询问下一个 source。
    /// 后端单 repo 聚合 endpoint 上线后回填实现。
    func tryResolve(owner: String, name: String, hint: StarcatRepoCardDTO?) async throws -> Repo? {
        // 故意 nil。不抛错，让链高速跳过。
        nil
    }
}
