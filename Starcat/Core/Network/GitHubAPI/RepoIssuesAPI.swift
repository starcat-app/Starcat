//
//  RepoIssuesAPI.swift
//  Starcat
//
//  仓库维度 Issue 列表 / 搜索 / 新建端点与轻量领域模型。
//
//  关键约束：
//  - `/repos/{owner}/{repo}/issues` 会把 Pull Request 混进响应（GitHub 复用同一 schema）；
//    必须在 API 边界按 `pull_request` 字段排除，不能靠标题猜。
//  - `/search/issues` 限流独立于普通 REST（登录用户约 30 次/分钟），只承担两件事：
//    ① per_page=1 取 `total_count` 做精确未解决/已关闭计数；② 列表客户端过滤无结果时
//    的关键词兜底。不承担日常列表分页。
//  - OAuth `public_repo` 覆盖公开仓库的列表与新建；私有仓没有 `repo` scope 时 GitHub
//    回 404，由 UI 层错误映射负责提示。
//  - 时间字段按项目惯例在 DTO 保持 String，映射时转 Date（见 `GitHubDTOs.swift` 文件头）。
//

import Foundation

/// 仓库 Issue 的展示状态。列表浮层只有「未解决 / 已关闭」两态；
/// `/search/issues` 的限定词由调用方按 `is:open` / `is:closed` 拼接。
enum GitHubRepoIssueState: String, CaseIterable, Identifiable, Sendable {
    case open
    case closed

    var id: String { rawValue }
}

struct GitHubRepoIssueLabel: Equatable, Hashable, Sendable {
    let name: String
    /// GitHub 返回不带 `#` 的 6 位 hex；缺省用中性灰。
    let colorHex: String
}

struct GitHubRepoIssue: Identifiable, Equatable, Sendable {
    let id: Int64
    let number: Int
    let title: String
    let state: GitHubRepoIssueState
    let body: String?
    let htmlURL: URL
    let authorLogin: String?
    let labels: [GitHubRepoIssueLabel]
    let commentsCount: Int
    let createdAt: Date?
    let updatedAt: Date?
    let closedAt: Date?
}

/// `/search/issues` 的包装结果。`totalCount` 是带 `is:issue` 限定后的精确总数（不含 PR）。
struct GitHubRepoIssueSearchResult: Equatable, Sendable {
    let totalCount: Int
    let items: [GitHubRepoIssue]
}

extension GitHubAPIClient {

    /// 拉取单仓库一页 Issue。`sort=updated&direction=desc` 与浮层「按最新更新」展示一致；
    /// 分页由调用方跟随返回的 `linkHeader.nextPage` 继续。
    func repoIssues(
        owner: String,
        repo: String,
        state: GitHubRepoIssueState,
        page: Int,
        perPage: Int
    ) async throws -> APIResponse<[GitHubRepoIssue]> {
        precondition(page >= 1, "page must be >= 1")
        precondition(perPage >= 1 && perPage <= 100, "perPage must be in [1, 100]")

        let response: APIResponse<[GitHubRepoIssueDTO]> = try await get(
            path: AppEndpoints.GitHubREST.Paths.repoIssues(owner: owner, repo: repo),
            queryItems: [
                URLQueryItem(name: "state", value: state.rawValue),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "direction", value: "desc"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage))
            ]
        )

        let issues = response.value.compactMap(Self.repoIssue(from:))
        return APIResponse(
            value: issues,
            linkHeader: response.linkHeader,
            rateLimit: response.rateLimit,
            statusCode: response.statusCode,
            etag: response.etag
        )
    }

    /// `/search/issues`。`query` 由调用方拼完整限定词（`repo:owner/name is:issue is:open ...`），
    /// 这里不二次加工——限定词里是否排除 PR、是否限定仓库都由调用方负责。
    func searchIssues(
        query: String,
        page: Int,
        perPage: Int
    ) async throws -> APIResponse<GitHubRepoIssueSearchResult> {
        precondition(page >= 1, "page must be >= 1")
        precondition(perPage >= 1 && perPage <= 100, "perPage must be in [1, 100]")

        let response: APIResponse<GitHubIssueSearchResponseDTO> = try await get(
            path: AppEndpoints.GitHubREST.Paths.searchIssues,
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage))
            ]
        )

        let result = GitHubRepoIssueSearchResult(
            totalCount: response.value.totalCount,
            items: response.value.items.compactMap(Self.repoIssue(from:))
        )
        return APIResponse(
            value: result,
            linkHeader: response.linkHeader,
            rateLimit: response.rateLimit,
            statusCode: response.statusCode,
            etag: response.etag
        )
    }

    /// 新建 Issue。标题必填（GitHub 422 校验）；body 支持 Markdown，可为空。
    /// 公开仓库 `public_repo` scope 即可；私有仓可能 404。
    func createRepoIssue(
        owner: String,
        repo: String,
        title: String,
        body: String?
    ) async throws -> GitHubRepoIssue {
        struct Payload: Encodable {
            let title: String
            let body: String?
        }
        let response = try await post(
            path: AppEndpoints.GitHubREST.Paths.repoIssues(owner: owner, repo: repo),
            body: Payload(title: title, body: body),
            as: GitHubRepoIssueDTO.self
        )
        guard let issue = Self.repoIssue(from: response.value) else {
            throw NetworkError.decodingError(underlying: RepoIssueDecodingError.invalidCreatedIssue)
        }
        return issue
    }

    enum RepoIssueDecodingError: Error {
        /// 创建成功但响应缺关键字段（如 html_url 非法）；正常不会发生，防御性兜底。
        case invalidCreatedIssue
    }

    /// DTO → 领域模型。PR 混入 / html_url 非法 / state 未知都丢掉，由调用方兜空态。
    nonisolated private static func repoIssue(from dto: GitHubRepoIssueDTO) -> GitHubRepoIssue? {
        guard dto.pullRequest == nil,
              let htmlURL = URL(string: dto.htmlUrl),
              let issueState = GitHubRepoIssueState(rawValue: dto.state)
        else { return nil }

        return GitHubRepoIssue(
            id: dto.id,
            number: dto.number,
            title: dto.title,
            state: issueState,
            body: dto.body,
            htmlURL: htmlURL,
            authorLogin: dto.user?.login,
            labels: dto.labels.compactMap { label in
                guard let name = label.name, !name.isEmpty else { return nil }
                return GitHubRepoIssueLabel(name: name, colorHex: label.color ?? "6e7781")
            },
            commentsCount: dto.comments,
            createdAt: parseGitHubDate(dto.createdAt),
            updatedAt: parseGitHubDate(dto.updatedAt),
            closedAt: parseGitHubDate(dto.closedAt)
        )
    }

    nonisolated private static func parseGitHubDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return ISO8601DateFormatter.shared.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
    }
}

/// 列表与搜索共用同一 issue schema；只解码展示需要的字段（见 `GitHubDTOs.swift` 规范）。
private struct GitHubRepoIssueDTO: Decodable, Sendable {
    let id: Int64
    let number: Int
    let title: String
    let state: String
    let body: String?
    let htmlUrl: String
    let user: GitHubRepoIssueUserDTO?
    let labels: [GitHubRepoIssueLabelDTO]
    let comments: Int
    let createdAt: String?
    let updatedAt: String?
    let closedAt: String?
    let pullRequest: GitHubRepoIssuePullRequestDTO?
}

private struct GitHubRepoIssueUserDTO: Decodable, Sendable {
    let login: String
}

private struct GitHubRepoIssueLabelDTO: Decodable, Sendable {
    let name: String?
    let color: String?
}

/// 只需要知道字段是否存在；内容不参与展示（同 `OrganizationIssuesAPI.swift`）。
private struct GitHubRepoIssuePullRequestDTO: Decodable, Sendable {}

/// `/search/issues` 顶层包装：`{ total_count, incomplete_results, items: [...] }`。
private struct GitHubIssueSearchResponseDTO: Decodable, Sendable {
    let totalCount: Int
    let items: [GitHubRepoIssueDTO]
}
