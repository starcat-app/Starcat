//
//  EventsAPI.swift
//  Starcat
//
//  GET /users/{username}/received_events/public 端点封装
//  （Activity 公告与关注 PR-2，2026-06-16）。
//
//  设计要点：
//  - 走 `getBytes` 而不是 `get<T:Decodable>`：events 端点的 `payload` 子对象因
//    `type` 不同结构差异巨大（参考 GitHubEventDTO 注释），无法用单一 Decodable
//    struct 表达；而 client.getBytes 已经包了 ETag / 304 / RateLimit / 401
//    集中处理，最适合「我自己手解 JSON」的场景。
//  - ETag/If-None-Match：服务端 304 → 抛 `NetworkError.notModified(etag:)`，
//    与 StarsAPI / ReadmeHTMLAPI 同款契约。调用方（ActivityViewModel）按方案
//    §5.4 SWR 流程：捕获 .notModified → 直接消费本地缓存、记 last_events_fetched_at。
//  - 不带分页（events 是滑动窗口，最近 90 条/30 天，GitHub 不暴露 next 链接）。
//  - perPage 仅作显式声明，GitHub 内部似乎仍按服务端固定窗口返回；保留参数便于
//    未来 GitHub 调整时不改调用方。
//

import Foundation

extension GitHubAPIClient {

    /// 拉取「我关注的人/组织」最近的公开活动 feed。
    ///
    /// - Parameters:
    ///   - username: 当前登录用户 login（如 `dong4j`）。事件 feed 是「user-scoped」
    ///     的，必须用本人 login；用别人的 login 会返回别人收到的 feed。
    ///   - perPage: 每页条数，最大 100（GitHub 限制）。GitHub 实际返回上限受
    ///     30 天窗口约束，常态 < 90 条。
    ///   - ifNoneMatch: 上次响应保存的 ETag；若服务端 feed 未变化会抛
    ///     `NetworkError.notModified(etag:)`（带回当前 ETag 给上层 touch 时间戳）。
    /// - Returns: `APIResponse<[GitHubEventDTO]>`，含已解析的事件数组 + 当前 ETag。
    ///   `LinkHeader` 永远是 `(nil, nil)`（events 不分页）。
    /// - Throws: `NetworkError.notModified` / 401 / 404 / 5xx / 解析失败。
    func receivedEvents(
        username: String,
        perPage: Int = 100,
        ifNoneMatch: String? = nil
    ) async throws -> APIResponse<[GitHubEventDTO]> {
        precondition(perPage >= 1 && perPage <= 100, "perPage must be in [1, 100]")

        // 拼 query string 走通用 buildRequest 不方便（getBytes 没 queryItems 参数）；
        // events 端点 perPage 是可选 query，干脆把它拼进 path（与 GitHub 文档示例一致）。
        let basePath = AppEndpoints.GitHubREST.Paths.userReceivedEvents(username: username)
        let path = "\(basePath)?per_page=\(perPage)"

        let bytes = try await getBytes(
            path: path,
            accept: "application/vnd.github+json",
            ifNoneMatch: ifNoneMatch,
            ifModifiedSince: nil
        )

        // 304 命中 → 上层用本地缓存，这里直接抛业务约定错误（与 StarsAPI 同款契约）。
        if bytes.notModified {
            throw NetworkError.notModified(etag: bytes.etag)
        }

        let dtos = try Self.parseEvents(from: bytes.data)

        return APIResponse(
            value: dtos,
            linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
            rateLimit: bytes.rateLimit,
            statusCode: bytes.statusCode,
            etag: bytes.etag
        )
    }

    /// 把 events 端点的 JSON 数组逐条解析成 DTO。
    ///
    /// 关键约束（不要轻易改）：
    /// 1. **整数组解析失败一次性 throw**：单条 malformed 不会让其它条进库 ——
    ///    feed 顺序敏感（按 created_at 倒序），中途跳几条会让用户体感「事件丢了」
    ///    比「这次刷新失败下次重试」更糟。
    /// 2. **payload reserialize 用 `.sortedKeys`**：保证同一份逻辑 payload 在
    ///    任何 macOS 版本下产生稳定字节序列（DB 入库 / ETag 比对都依赖确定性）。
    /// 3. **缺字段视为 malformed**：id / type / actor / repo / created_at 是 GitHub
    ///    Events API 文档承诺一定有的字段，缺任一个说明响应损坏，按 invalidResponse
    ///    抛错让上层走错误降级路径。
    nonisolated private static func parseEvents(from data: Data) throws -> [GitHubEventDTO] {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []) else {
            throw NetworkError.invalidResponse
        }
        guard let array = raw as? [[String: Any]] else {
            throw NetworkError.invalidResponse
        }
        return try array.map { dict -> GitHubEventDTO in
            guard
                let id = dict["id"] as? String,
                let type = dict["type"] as? String,
                let actorDict = dict["actor"] as? [String: Any],
                let actorID = (actorDict["id"] as? NSNumber)?.int64Value ?? (actorDict["id"] as? Int).map(Int64.init),
                let actorLogin = actorDict["login"] as? String,
                let repoDict = dict["repo"] as? [String: Any],
                let repoID = (repoDict["id"] as? NSNumber)?.int64Value ?? (repoDict["id"] as? Int).map(Int64.init),
                let repoName = repoDict["name"] as? String,
                let createdAt = dict["created_at"] as? String
            else {
                throw NetworkError.invalidResponse
            }

            let payloadObj = dict["payload"] ?? [String: Any]()
            // sortedKeys 让 payloadJson 字节稳定，ETag 比对 / DB diff 都靠这点。
            let payloadData = (try? JSONSerialization.data(withJSONObject: payloadObj, options: [.sortedKeys]))
                ?? Data("{}".utf8)
            let payloadJson = String(data: payloadData, encoding: .utf8) ?? "{}"

            let actor = GitHubEventActorDTO(
                id: actorID,
                login: actorLogin,
                displayLogin: actorDict["display_login"] as? String,
                avatarUrl: actorDict["avatar_url"] as? String
            )
            let repo = GitHubEventRepoDTO(
                id: repoID,
                name: repoName,
                url: repoDict["url"] as? String
            )

            return GitHubEventDTO(
                id: id,
                type: type,
                actor: actor,
                repo: repo,
                payloadJson: payloadJson,
                createdAt: createdAt
            )
        }
    }
}
