//
//  OrganizationIssuesAPI.swift
//  Starcat
//
//  GitHub 组织 Issue 列表端点与轻量领域模型。
//
//  关键约束：
//  - `/orgs/{org}/issues` 返回当前凭据可见的结果，不等同于 Notifications。
//  - GitHub 会把 Pull Request 混进 Issue 响应；必须在 API 边界排除。
//  - 数据写入当前 GitHub 用户隔离的本地时间线库，但不进入 CloudKit / 导出 / Discovery。
//

import Foundation

enum GitHubOrganizationIssueState: String, CaseIterable, Identifiable, Sendable {
    case open
    case closed
    case all

    var id: String { rawValue }
}

struct GitHubOrganizationIssueLabel: Equatable, Hashable, Sendable {
    let name: String
    let colorHex: String
}

struct GitHubOrganizationIssue: Identifiable, Equatable, Sendable {
    let id: Int64
    let subjectAPIURL: String
    let organization: String
    let repositoryFullName: String
    let number: Int
    let title: String
    let state: GitHubOrganizationIssueState
    let body: String?
    let htmlURL: URL
    let authorLogin: String?
    let assigneeLogins: [String]
    let labels: [GitHubOrganizationIssueLabel]
    let commentsCount: Int
    let createdAt: Date?
    let updatedAt: Date?
    let closedAt: Date?

    /// 两份凭据可能返回同一条 Issue；GitHub issue id 理论上全局唯一，但 repo + number
    /// 更符合产品展示身份，也方便 Mock / 迁移数据稳定去重。
    var deduplicationKey: String {
        "\(repositoryFullName.lowercased())#\(number)"
    }
}

extension GitHubAPIClient {
    func organizationIssues(
        organization: String,
        state: GitHubOrganizationIssueState,
        page: Int,
        perPage: Int
    ) async throws -> APIResponse<[GitHubOrganizationIssue]> {
        precondition(page >= 1, "page must be >= 1")
        precondition(perPage >= 1 && perPage <= 100, "perPage must be in [1, 100]")

        let response: APIResponse<[GitHubOrganizationIssueDTO]> = try await get(
            path: AppEndpoints.GitHubREST.Paths.organizationIssues(organization: organization),
            queryItems: [
                URLQueryItem(name: "filter", value: "all"),
                URLQueryItem(name: "state", value: state.rawValue),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "direction", value: "desc"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage))
            ]
        )

        let issues = response.value.compactMap { dto in
            Self.organizationIssue(from: dto, organization: organization)
        }
        return APIResponse(
            value: issues,
            linkHeader: response.linkHeader,
            rateLimit: response.rateLimit,
            statusCode: response.statusCode,
            etag: response.etag
        )
    }

    nonisolated private static func organizationIssue(
        from dto: GitHubOrganizationIssueDTO,
        organization: String
    ) -> GitHubOrganizationIssue? {
        // GitHub 的 Issue API 明确复用同一 schema 返回 PR；字段存在即排除，不能靠标题猜。
        guard dto.pullRequest == nil,
              let htmlURL = URL(string: dto.htmlUrl),
              let repositoryFullName = repositoryFullName(from: dto.repositoryUrl),
              let issueState = GitHubOrganizationIssueState(rawValue: dto.state)
        else { return nil }

        return GitHubOrganizationIssue(
            id: dto.id,
            subjectAPIURL: dto.url,
            organization: organization,
            repositoryFullName: repositoryFullName,
            number: dto.number,
            title: dto.title,
            state: issueState,
            body: dto.body,
            htmlURL: htmlURL,
            authorLogin: dto.user?.login,
            assigneeLogins: dto.assignees.map(\.login),
            labels: dto.labels.compactMap { label in
                guard let name = label.name, !name.isEmpty else { return nil }
                return GitHubOrganizationIssueLabel(name: name, colorHex: label.color ?? "6e7781")
            },
            commentsCount: dto.comments,
            createdAt: parseGitHubDate(dto.createdAt),
            updatedAt: parseGitHubDate(dto.updatedAt),
            closedAt: parseGitHubDate(dto.closedAt)
        )
    }

    nonisolated private static func repositoryFullName(from repositoryURL: String) -> String? {
        guard let url = URL(string: repositoryURL) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 3 else { return nil }
        return components.suffix(2).joined(separator: "/")
    }

    nonisolated private static func parseGitHubDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return ISO8601DateFormatter.shared.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
    }
}

private struct GitHubOrganizationIssueDTO: Decodable, Sendable {
    let id: Int64
    let url: String
    let number: Int
    let title: String
    let state: String
    let body: String?
    let htmlUrl: String
    let repositoryUrl: String
    let user: GitHubOrganizationIssueUserDTO?
    let assignees: [GitHubOrganizationIssueUserDTO]
    let labels: [GitHubOrganizationIssueLabelDTO]
    let comments: Int
    let createdAt: String?
    let updatedAt: String?
    let closedAt: String?
    let pullRequest: GitHubOrganizationIssuePullRequestDTO?
}

private struct GitHubOrganizationIssueUserDTO: Decodable, Sendable {
    let login: String
}

private struct GitHubOrganizationIssueLabelDTO: Decodable, Sendable {
    let name: String?
    let color: String?
}

/// 只需要知道字段是否存在；内容不参与展示。
private struct GitHubOrganizationIssuePullRequestDTO: Decodable, Sendable {}
