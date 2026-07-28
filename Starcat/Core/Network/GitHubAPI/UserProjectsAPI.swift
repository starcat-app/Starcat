//
//  UserProjectsAPI.swift
//  Starcat
//
//  GET /user/repos 的“我的项目”端点封装。
//
//  关键约束：
//  - owner 与 organization_member 必须分两条分页链请求，才能独立保存 ETag 和失败状态；
//  - OAuth fallback 只允许 visibility=public，GitHub App user token 才允许 visibility=all；
//  - 不请求 collaborator，首版明确排除“仅作为外部个人协作者”的仓库；
//  - 分页严格消费 Link Header，不能用“本页不足 100 条”猜测下一页。
//

import Foundation

enum UserProjectsAPIVisibility: String, Sendable {
    case publicOnly = "public"
    case all
}

/// `/user/repos` 比通用 `GitHubRepoDTO` 多出的项目权限字段。
///
/// 同一 JSON 对象先交给 `GitHubRepoDTO` 解码通用 Repo 元数据，再从 keyed container
/// 解码 visibility / permissions / owner.type，避免复制整套 GitHub Repo DTO。
struct GitHubUserProjectDTO: Decodable, @unchecked Sendable {
    let repo: GitHubRepoDTO
    let ownerType: ProjectOwnerType
    let visibility: ProjectVisibility
    let permission: ProjectPermission

    private enum CodingKeys: String, CodingKey {
        case owner
        case visibility
        case permissions
        case roleName
        case isPrivate = "private"
    }

    private struct OwnerMetadata: Decodable {
        let type: String?
    }

    private struct Permissions: Decodable {
        let admin: Bool?
        let maintain: Bool?
        let push: Bool?
        let triage: Bool?
        let pull: Bool?
    }

    init(from decoder: Decoder) throws {
        repo = try GitHubRepoDTO(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let owner = try container.decodeIfPresent(OwnerMetadata.self, forKey: .owner)
        ownerType = owner?.type?.lowercased() == "organization" ? .organization : .user

        if let rawVisibility = try container.decodeIfPresent(String.self, forKey: .visibility),
           let decodedVisibility = ProjectVisibility(rawValue: rawVisibility) {
            visibility = decodedVisibility
        } else {
            let isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
            visibility = isPrivate ? .private : .public
        }

        let permissions = try container.decodeIfPresent(Permissions.self, forKey: .permissions)
        let roleName = try container.decodeIfPresent(String.self, forKey: .roleName)
        permission = Self.resolvePermission(permissions: permissions, roleName: roleName)
    }

    func remoteProject(affiliation: ProjectAffiliation) -> RemoteUserProject {
        RemoteUserProject(
            repo: repo,
            affiliation: affiliation,
            ownerType: ownerType,
            visibility: visibility,
            permission: permission,
            installationId: nil
        )
    }

    /// GitHub Enterprise 可能返回自定义 role_name，因此优先使用稳定的 permissions
    /// 布尔矩阵；无法映射时降级 unknown，不把服务端展示文案写入数据库。
    private static func resolvePermission(
        permissions: Permissions?,
        roleName: String?
    ) -> ProjectPermission {
        if permissions?.admin == true { return .admin }
        if permissions?.maintain == true { return .maintain }
        if permissions?.push == true { return .push }
        if permissions?.triage == true { return .triage }
        if permissions?.pull == true { return .pull }
        if let roleName, let role = ProjectPermission(rawValue: roleName.lowercased()) {
            return role
        }
        return .unknown
    }
}

protocol UserProjectsAPIProtocol: Sendable {
    func userProjects(
        affiliation: ProjectAffiliation,
        visibility: UserProjectsAPIVisibility,
        page: Int,
        perPage: Int,
        ifNoneMatch: String?
    ) async throws -> APIResponse<[GitHubUserProjectDTO]>
}

extension GitHubAPIClient: UserProjectsAPIProtocol {
    func userProjects(
        affiliation: ProjectAffiliation,
        visibility: UserProjectsAPIVisibility,
        page: Int,
        perPage: Int = 100,
        ifNoneMatch: String? = nil
    ) async throws -> APIResponse<[GitHubUserProjectDTO]> {
        precondition(page >= 1, "page must be >= 1")
        precondition(perPage >= 1 && perPage <= 100, "perPage must be in [1, 100]")

        return try await get(
            path: AppEndpoints.GitHubREST.Paths.currentUserRepos,
            queryItems: [
                URLQueryItem(name: "affiliation", value: affiliation.rawValue),
                URLQueryItem(name: "visibility", value: visibility.rawValue),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "direction", value: "desc"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage))
            ],
            ifNoneMatch: ifNoneMatch
        )
    }
}
