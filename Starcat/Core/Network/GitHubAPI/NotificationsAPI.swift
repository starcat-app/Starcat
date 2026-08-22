//
//  NotificationsAPI.swift
//  Starcat
//
//  GitHub Notifications inbox：列表走 getBytes（要 Last-Modified / X-Poll-Interval），
//  选中后 GET subject.url 补全，PATCH thread 标已读，DELETE thread 标 Done。
//
//  不做 mark-all。403 原样抛给 InboxService 判断缺 scope。
//

import Foundation

extension GitHubAPIClient {

    /// `GET /notifications`。`all=true` 才能把已读 thread 的 `unread=false` 拉回来校准蓝点。
    func listNotifications(
        all: Bool,
        since: String?,
        page: Int,
        perPage: Int,
        ifModifiedSince: String?
    ) async throws -> GitHubNotificationsListResponse {
        precondition(page >= 1, "page must be >= 1")
        precondition(perPage >= 1 && perPage <= 100, "perPage must be in [1, 100]")

        var items = [
            URLQueryItem(name: "all", value: all ? "true" : "false"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        if let since, !since.isEmpty {
            items.append(URLQueryItem(name: "since", value: since))
        }
        var components = URLComponents()
        components.queryItems = items
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let path = AppEndpoints.GitHubREST.Paths.notifications + query

        let bytes = try await getBytes(
            path: path,
            accept: "application/vnd.github+json",
            ifNoneMatch: nil,
            ifModifiedSince: ifModifiedSince
        )

        if bytes.notModified {
            return GitHubNotificationsListResponse(
                threads: [],
                lastModified: bytes.lastModified,
                pollIntervalSeconds: bytes.pollIntervalSeconds,
                nextPage: nil,
                notModified: true
            )
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let threads: [GitHubNotificationThreadDTO]
        do {
            threads = try decoder.decode([GitHubNotificationThreadDTO].self, from: bytes.data)
        } catch {
            throw NetworkError.decodingError(underlying: error)
        }

        return GitHubNotificationsListResponse(
            threads: threads,
            lastModified: bytes.lastModified,
            pollIntervalSeconds: bytes.pollIntervalSeconds,
            nextPage: threads.count < perPage ? nil : page + 1,
            notModified: false
        )
    }

    /// 选中后对 `subject.url` 打 1 次，Issue / PR 再拉 comments。失败由调用方忽略，骨架仍可用。
    func hydrateNotificationSubject(path: String) async throws -> GitHubNotificationSubjectHydration {
        let bytes = try await getBytes(
            path: path,
            accept: "application/vnd.github+json",
            ifNoneMatch: nil,
            ifModifiedSince: nil
        )
        return Self.parseSubjectHydration(from: bytes.data)
    }

    func markNotificationThreadRead(id: String) async throws {
        try await patch(path: AppEndpoints.GitHubREST.Paths.notificationThread(id: id))
    }

    /// `DELETE /notifications/threads/{id}`。和网页 Inbox 点 Done 一样，不是删 Issue。
    func markNotificationThreadDone(id: String) async throws {
        try await delete(path: AppEndpoints.GitHubREST.Paths.notificationThread(id: id))
    }

    /// Issue / PR / Discussion / Release 字段不完全相同，松散取 html_url / user|author.login / body。
    nonisolated private static func parseSubjectHydration(from data: Data) -> GitHubNotificationSubjectHydration {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return GitHubNotificationSubjectHydration(htmlURL: nil, actorLogin: nil, excerpt: nil, createdAt: nil, state: nil)
        }
        let htmlURL = obj["html_url"] as? String
        let user = obj["user"] as? [String: Any]
        let author = obj["author"] as? [String: Any]
        let actorLogin = (user?["login"] as? String) ?? (author?["login"] as? String)
        let excerpt = GitHubNotificationMapper.bodyMarkdown(obj["body"] as? String)
        let createdAt = (obj["created_at"] as? String) ?? (obj["published_at"] as? String)
        // Issues API 的 `state` 对已合并 PR 仍是 closed；PR API 才带 merged / merged_at。
        let state = GitHubNotificationMapper.resolvedIssueState(
            rawState: obj["state"] as? String,
            merged: obj["merged"] as? Bool,
            mergedAt: obj["merged_at"] as? String
        )
        return GitHubNotificationSubjectHydration(
            htmlURL: htmlURL,
            actorLogin: actorLogin,
            excerpt: excerpt,
            createdAt: createdAt,
            state: state
        )
    }

    func listNotificationIssueComments(path: String) async throws -> [GitHubNotificationComment] {
        let queryPath = path.contains("?") ? path : path + "?per_page=100"
        let bytes = try await getBytes(
            path: queryPath,
            accept: "application/vnd.github+json",
            ifNoneMatch: nil,
            ifModifiedSince: nil
        )
        return Self.parseIssueComments(from: bytes.data)
    }

    /// 公开 Issue / PR 用 `public_repo` 就能发；私有仓没 `repo` scope 时 GitHub 回 404。
    func createNotificationIssueComment(path: String, body: String) async throws -> GitHubNotificationComment {
        struct Payload: Encodable {
            let body: String
        }
        let response = try await post(path: path, body: Payload(body: body), as: GitHubIssueCommentDTO.self)
        guard let comment = Self.comment(from: response.value) else {
            throw NetworkError.decodingError(underlying: GitHubNotificationCommentDecodingError.missingLogin)
        }
        return comment
    }

    /// `PATCH /repos/{owner}/{repo}/issues/{n}`，`state=closed` 也能关 PR（GitHub 把 PR 当 issue）。
    func updateNotificationIssueState(path: String, state: String) async throws {
        struct Payload: Encodable {
            let state: String
        }
        try await patch(path: path, body: Payload(state: state))
    }

    nonisolated private static func parseIssueComments(from data: Data) -> [GitHubNotificationComment] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let rows = try? decoder.decode([GitHubIssueCommentDTO].self, from: data) else {
            return []
        }
        return rows.compactMap(comment(from:))
    }

    nonisolated private static func comment(from row: GitHubIssueCommentDTO) -> GitHubNotificationComment? {
        guard let login = row.user?.login, !login.isEmpty else { return nil }
        return GitHubNotificationComment(
            id: row.id,
            login: login,
            body: GitHubNotificationMapper.bodyMarkdown(row.body) ?? "",
            htmlURL: row.htmlUrl,
            createdAt: row.createdAt
        )
    }
}

private enum GitHubNotificationCommentDecodingError: Error {
    case missingLogin
}

private struct GitHubIssueCommentDTO: Decodable {
    let id: Int64
    let htmlUrl: String?
    let body: String?
    let createdAt: String?
    let user: GitHubNotificationOwnerDTO?
}
