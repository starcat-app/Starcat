//
//  UserProject.swift
//  Starcat
//
//  “我的项目”关系、同步状态和列表投影模型。
//
//  关键约束：
//  - Repo 元数据仍由 `repos` 统一保存，本文件只描述“当前用户可以访问该项目”的关系；
//  - Project、Star 和知识库是可交叉的独立集合，不能从 `Repo.isStarred` 推导项目归属；
//  - 所有枚举保留稳定 raw value，数据库和筛选器共同使用，避免 UI 文案进入持久化层。
//

import Foundation
import GRDB

enum ProjectAffiliation: String, Codable, CaseIterable, Sendable {
    case owner
    case organizationMember = "organization_member"
}

enum ProjectOwnerType: String, Codable, CaseIterable, Sendable {
    case user
    case organization
}

enum ProjectVisibility: String, Codable, CaseIterable, Sendable {
    case `public`
    case `private`
    case `internal`
}

enum ProjectPermission: String, Codable, CaseIterable, Sendable {
    case admin
    case maintain
    case push
    case triage
    case pull
    case unknown
}

enum ProjectAuthorizationSource: String, Codable, CaseIterable, Sendable {
    case oauth
    case githubApp = "github_app"
}

enum ProjectSyncStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case syncing
    case succeeded
    case failed
}

/// 当前 GitHub 用户与一个 Repo 的项目关系。
struct UserProject: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    static let databaseTableName = "user_projects"

    var userId: Int64
    var repoId: Int64
    var affiliation: ProjectAffiliation
    var ownerLogin: String
    var ownerType: ProjectOwnerType
    var visibility: ProjectVisibility
    var permission: ProjectPermission
    var authorizationSource: ProjectAuthorizationSource
    var installationId: Int64?
    var generation: String
    var lastSeenAt: String
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case repoId = "repo_id"
        case affiliation
        case ownerLogin = "owner_login"
        case ownerType = "owner_type"
        case visibility
        case permission
        case authorizationSource = "authorization_source"
        case installationId = "installation_id"
        case generation
        case lastSeenAt = "last_seen_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

extension UserProject {
    /// GitHub 只向仓库管理员或协作者开放 Stargazers 时间列表。
    ///
    /// owner 关系本身足以证明仓库归属；其余项目必须有明确权限，避免把仅由
    /// 组织枚举得到但不可访问的项目误送到受限接口。
    var canReadStargazers: Bool {
        affiliation == .owner || permission != .unknown
    }
}

/// 一条 affiliation 同步链的持久状态。
struct ProjectSyncState: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    static let databaseTableName = "project_sync_state"

    var userId: Int64
    var credentialKind: ProjectAuthorizationSource
    var affiliation: ProjectAffiliation
    var etag: String?
    var generation: String?
    var lastAttemptAt: String?
    var lastSuccessAt: String?
    var syncStatus: ProjectSyncStatus
    var errorCode: String?
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case credentialKind = "credential_kind"
        case affiliation
        case etag
        case generation
        case lastAttemptAt = "last_attempt_at"
        case lastSuccessAt = "last_success_at"
        case syncStatus = "sync_status"
        case errorCode = "error_code"
        case updatedAt = "updated_at"
    }
}

/// API 层交给 Repository 的单个项目快照。
///
/// `visibility`、`permission` 和 `ownerType` 不能只由 `GitHubRepoDTO.isPrivate`
/// 推导，因此由 `/user/repos` DTO 显式解析后再传入。
struct RemoteUserProject: Sendable {
    let repo: GitHubRepoDTO
    let affiliation: ProjectAffiliation
    let ownerType: ProjectOwnerType
    let visibility: ProjectVisibility
    let permission: ProjectPermission
    let installationId: Int64?
}

/// 项目列表的 Repo 卡片数据与关系元数据。
struct UserProjectListItem: FetchableRecord, Equatable, Sendable {
    let repo: Repo
    let project: UserProject

    init(row: Row) throws {
        repo = try Repo(row: row)
        project = UserProject(
            userId: row["project_user_id"],
            repoId: row["project_repo_id"],
            affiliation: ProjectAffiliation(rawValue: row["project_affiliation"]) ?? .owner,
            ownerLogin: row["project_owner_login"],
            ownerType: ProjectOwnerType(rawValue: row["project_owner_type"]) ?? .user,
            visibility: ProjectVisibility(rawValue: row["project_visibility"]) ?? .public,
            permission: ProjectPermission(rawValue: row["project_permission"]) ?? .unknown,
            authorizationSource: ProjectAuthorizationSource(
                rawValue: row["project_authorization_source"]
            ) ?? .oauth,
            installationId: row["project_installation_id"],
            generation: row["project_generation"],
            lastSeenAt: row["project_last_seen_at"],
            createdAt: row["project_created_at"],
            updatedAt: row["project_updated_at"]
        )
    }
}

/// Repository 层的项目专属筛选。空集合表示不限制该维度。
struct UserProjectFilter: Equatable, Sendable {
    var affiliations: Set<ProjectAffiliation> = []
    var organizationLogins: Set<String> = []
    var visibilities: Set<ProjectVisibility> = []
    var permissions: Set<ProjectPermission> = []
    var authorizationSources: Set<ProjectAuthorizationSource> = []
    var searchText = ""
}
