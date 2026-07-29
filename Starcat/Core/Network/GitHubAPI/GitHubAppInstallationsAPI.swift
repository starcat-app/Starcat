//
//  GitHubAppInstallationsAPI.swift
//  Starcat
//
//  GitHub App user access token 的安装范围验证端点。
//
//  关键约束：
//  - Web Flow callback 只证明用户授权了 App，不证明所有个人或组织安装均已批准；
//  - 必须通过 /user/installations 验证当前 App 至少存在一个可访问安装，才能启用
//    Private / Internal 项目同步；
//  - 响应只用于判断安装是否存在及仓库选择范围，不持久化账号、组织或安装 ID。
//

import Foundation

/// 当前 GitHub App 安装对仓库的授权范围。
///
/// 多个账号或组织可以分别安装同一个 App；只要其中任一安装选择了部分仓库，
/// 整体就必须向用户呈现“部分授权”，避免错误宣称所有项目均可同步。
enum GitHubAppInstallationAccess: Equatable, Sendable {
    case notInstalled
    case allRepositories
    case selectedRepositories

    var isInstalled: Bool {
        self != .notInstalled
    }
}

/// `/user/installations` 的最小安装记录。
///
/// 这里只保留匹配当前 App 和判断授权范围所需字段，避免把账号或组织信息带出网络层。
private struct GitHubAppInstallationDTO: Decodable, Sendable {
    let appSlug: String
    let repositorySelection: RepositorySelection

    enum RepositorySelection: String, Decodable, Sendable {
        case all
        case selected
    }
}

/// GitHub 安装列表响应信封。
private struct GitHubAppInstallationsPageDTO: Decodable, Sendable {
    let installations: [GitHubAppInstallationDTO]
}

extension GitHubAPIClient {
    /// 返回当前 user access token 对指定 GitHub App 的安装与仓库选择范围。
    ///
    /// GitHub App 可能安装在多个个人账号或组织中，且响应支持分页。必须遍历全部匹配项：
    /// 任一安装使用 selected repositories 时，产品整体都应显示部分授权。没有安装不是
    /// 网络错误，而是明确的产品状态。
    func githubAppInstallationAccess(appSlug: String) async throws -> GitHubAppInstallationAccess {
        let normalizedSlug = appSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSlug.isEmpty else { return .notInstalled }

        var page = 1
        var foundMatchingInstallation = false
        while true {
            let response: APIResponse<GitHubAppInstallationsPageDTO> = try await get(
                path: AppEndpoints.GitHubREST.Paths.currentUserInstallations,
                queryItems: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "per_page", value: "100")
                ]
            )
            for installation in response.value.installations
            where installation.appSlug.caseInsensitiveCompare(normalizedSlug) == .orderedSame {
                foundMatchingInstallation = true
                if installation.repositorySelection == .selected {
                    return .selectedRepositories
                }
            }
            guard let nextPage = response.linkHeader.nextPage else {
                return foundMatchingInstallation ? .allRepositories : .notInstalled
            }
            page = nextPage
        }
    }
}
