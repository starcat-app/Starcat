//
//  SecurityAdvisoryAPI.swift
//  Starcat
//
//  Activity 公告与关注 PR-3（2026-06-17）：`GET /repos/{owner}/{repo}/security-advisories`。
//
//  设计要点：
//  - per-repo 端点，无集中 ETag；ActivityViewModel 按「最近 30 天有 push」的 starred
//    子集批量扫描，`activity_sync_state.last_security_fetched_at` 只记整批完成时间。
//  - 404 / 403 在 ViewModel 层静默跳过（私有仓库 / 无 advisory 权限），不在 API 层吞错。
//  - 响应是 `[GitHubSecurityAdvisoryDTO]` 数组，走 `GitHubAPIClient.get` 标准 JSON 解码。
//

import Foundation

extension GitHubAPIClient {

    /// 拉取单个仓库已发布的 Security Advisory 列表。
    ///
    /// Activity feed 只展示已经公开发布的 GHSA。显式加 `state=published` 是为了避免
    /// 维护者 token 看到 triage / draft / closed 等工作流中间态；这些记录不一定具备
    /// 公开 GHSA 展示所需字段，直接解码会把整批安全公告扫描误报为解析失败。
    ///
    /// - Returns: 可能为空数组（仓库无已发布 GHSA）；404 表示仓库不存在或无权限，由调用方决定降级。
    func securityAdvisories(owner: String, repo: String) async throws -> APIResponse<[GitHubSecurityAdvisoryDTO]> {
        try await get(
            path: AppEndpoints.GitHubREST.Paths.repoSecurityAdvisories(owner: owner, repo: repo),
            queryItems: [
                URLQueryItem(name: "state", value: "published"),
                URLQueryItem(name: "per_page", value: "100"),
            ]
        )
    }
}
