//
//  NotificationsAPI.swift
//  Starcat
//
//  GitHub Notifications inbox：列表走 getBytes（要 Last-Modified / X-Poll-Interval），
//  选中后 GET subject.url 补全，PATCH thread 标已读。
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

    /// 选中后对 `subject.url` 打 1 次。失败由调用方忽略，骨架仍可用。
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

    /// Issue / PR / Discussion / Release 字段不完全相同，松散取 html_url / user|author.login / body。
    nonisolated private static func parseSubjectHydration(from data: Data) -> GitHubNotificationSubjectHydration {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return GitHubNotificationSubjectHydration(htmlURL: nil, actorLogin: nil, excerpt: nil)
        }
        let htmlURL = obj["html_url"] as? String
        let user = obj["user"] as? [String: Any]
        let author = obj["author"] as? [String: Any]
        let actorLogin = (user?["login"] as? String) ?? (author?["login"] as? String)
        let excerpt = GitHubNotificationMapper.truncatedExcerpt(obj["body"] as? String)
        return GitHubNotificationSubjectHydration(
            htmlURL: htmlURL,
            actorLogin: actorLogin,
            excerpt: excerpt
        )
    }
}
