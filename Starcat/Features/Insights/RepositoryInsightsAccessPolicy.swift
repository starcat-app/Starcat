//
//  RepositoryInsightsAccessPolicy.swift
//  Starcat
//
//  仓库洞察远端拉取门禁与 Metrics token 路由策略。
//
//  为什么单独拆文件：
//  - ViewModel 只关心「能不能打远端」；Metrics Client 只关心「用哪张 token」；
//  - 私人仓库默认禁止走 OAuth `public_repo`，避免 404/403 噪音，也避免误以为公开链路可用；
//  - 「我的项目」私仓例外：已写入 `user_projects` 的关系证明用户主动授权，改走 GitHub App token。
//

import Foundation

/// Metrics 请求应使用的凭据来源。
enum RepositoryInsightsCredentialKind: Equatable, Sendable {
    /// 主登录 OAuth（公开仓与 Stars 路径）。
    case oauth
    /// 「我的项目」GitHub App user access token（私人 / Internal）。
    case githubApp
}

/// 按仓库身份选择洞察 Metrics 凭据。
protocol RepositoryInsightsCredentialResolving: Sendable {
    func credential(for repository: RepoIdentity) async -> RepositoryInsightsCredentialKind
}

/// ViewModel 远端区块门禁：决定是否允许发起 Metrics / GraphQL 拉取。
protocol RepositoryRemoteInsightsAccessProviding: Sendable {
    func allowsRemoteInsights(repo: Repo, isAuthenticated: Bool) async -> Bool
}

/// 生产实现：`user_projects` 命中且可见性为 private/internal → App token。
///
/// 公开「我的项目」仍走 OAuth：`public_repo` 足够，且与 Stars 配额、缓存身份一致。
struct GRDBRepositoryInsightsCredentialResolver: RepositoryInsightsCredentialResolving, Sendable {
    let projectRepository: any UserProjectRepositoryProtocol

    func credential(for repository: RepoIdentity) async -> RepositoryInsightsCredentialKind {
        guard let repoID = repository.ghRepoID,
              let project = try? await projectRepository.fetchProject(repoID: repoID),
              project.visibility == .private || project.visibility == .internal
        else {
            return .oauth
        }
        return .githubApp
    }
}

/// 生产门禁：公开仓始终允许远端结构；私仓仅「我的项目」关系命中且已登录时放行。
///
/// 未进入 `user_projects` 的私仓继续本地-only，防止任意私仓身份进入 OAuth Metrics。
/// Activity 等仍需登录的区块由 ViewModel 额外检查 `isAuthenticated`。
struct DefaultRepositoryRemoteInsightsAccessProvider: RepositoryRemoteInsightsAccessProviding, Sendable {
    let projectRepository: any UserProjectRepositoryProtocol

    func allowsRemoteInsights(repo: Repo, isAuthenticated: Bool) async -> Bool {
        if !repo.isPrivate {
            return true
        }
        guard isAuthenticated else { return false }
        return (try? await projectRepository.fetchProject(repoID: repo.id)) != nil
    }
}
