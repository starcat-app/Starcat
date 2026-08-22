//
//  GitHubIssueTimelineAPI.swift
//  Starcat
//
//  Issue 事件流：`GET /repos/{owner}/{repo}/issues/{n}/timeline`。
//
//  协议方法挂在 `GitHubAPIClientProtocol`，组织仓走 `apiClient(for:)`。
//  第一页 `per_page=100`；更多页不做。结果只进 Inbox 内存缓存，不写库。
//

import Foundation

extension GitHubAPIClient {
    /// Issue / PR 时间线。未知 event 已在 parser 丢掉。失败原样抛给调用方。
    func listNotificationIssueTimeline(path: String) async throws -> [GitHubNotificationIssueTimelineItem] {
        let bytes = try await getBytes(
            path: path,
            accept: "application/vnd.github+json",
            queryItems: [URLQueryItem(name: "per_page", value: "100")],
            ifNoneMatch: nil,
            ifModifiedSince: nil
        )
        return GitHubNotificationIssueTimelineParser.parse(bytes.data)
    }
}
