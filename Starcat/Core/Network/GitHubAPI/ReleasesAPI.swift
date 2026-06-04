//
//  ReleasesAPI.swift
//  Starcat
//
//  GET /repos/{owner}/{repo}/releases 端点封装（HOM-47 Release 订阅追踪）。
//
//  设计要点：
//  - 仅拉第一页（按 GitHub 默认排序，最新的在前）；订阅追踪关心"最近 N 条"，无需翻页
//  - perPage 默认 10：
//      ① 多数仓库历史 Release 数量 ≤ 10，一次拉够
//      ② 后台轮询每个订阅 repo 都要打一次 API，控制响应体大小避免拖慢轮询
//      ③ 如未来要"同步全量历史 Release"再加翻页支持
//  - 不带 ETag/If-None-Match 条件请求：MVP 阶段保持简单；P2 可扩展
//  - 404 是预期行为（仓库无任何 Release），调用方需 catch 并退化"无 Release 占位"
//

import Foundation

extension GitHubAPIClient {

    /// 拉取一页 Releases。
    /// - Parameters:
    ///   - owner: 仓库 owner（与 GitHub URL 中的 owner 一致）
    ///   - repo: 仓库 name
    ///   - perPage: 每页条数，默认 10，上限 100（GitHub 限制）
    /// - Returns: APIResponse 包装 [GitHubReleaseDTO]，元素按 published_at desc 排序
    /// - Throws: 404 → `.notFound`（无 Release）；其它 → 同 GitHubAPIClient 通用错误
    func releases(owner: String, repo: String, perPage: Int = 10) async throws -> APIResponse<[GitHubReleaseDTO]> {
        precondition(perPage >= 1 && perPage <= 100, "perPage must be in [1, 100]")
        let query: [URLQueryItem] = [
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: "1"),
        ]
        return try await get(path: "/repos/\(owner)/\(repo)/releases", queryItems: query)
    }
}
