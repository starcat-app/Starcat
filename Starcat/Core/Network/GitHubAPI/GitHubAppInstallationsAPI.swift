//
//  GitHubAppInstallationsAPI.swift
//  Starcat
//
//  GitHub App user access token 的安装范围验证端点。
//
//  关键约束：
//  - Device Flow 只证明用户授权了 App，不证明 App 已安装到个人账号或组织；
//  - 必须通过 /user/installations 验证当前 App 至少存在一个可访问安装，才能启用
//    Private / Internal 项目同步；
//  - 响应只用于判断安装是否存在，不持久化账号、组织或安装 ID。
//

import Foundation

/// `/user/installations` 的最小安装记录。
///
/// 这里只保留匹配当前 App 所需的 slug，避免把账号或组织信息带出网络层。
private struct GitHubAppInstallationDTO: Decodable, Sendable {
    let appSlug: String
}

/// GitHub 安装列表响应信封。
private struct GitHubAppInstallationsPageDTO: Decodable, Sendable {
    let installations: [GitHubAppInstallationDTO]
}

extension GitHubAPIClient {
    /// 判断当前 user access token 是否能访问指定 GitHub App 的任一安装。
    ///
    /// GitHub App 可能安装在多个个人账号或组织中，且响应支持分页；找到第一个 slug
    /// 匹配项即可提前返回。没有安装不是网络错误，而是明确的产品状态。
    func hasAccessibleGitHubAppInstallation(appSlug: String) async throws -> Bool {
        let normalizedSlug = appSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSlug.isEmpty else { return false }

        var page = 1
        while true {
            let response: APIResponse<GitHubAppInstallationsPageDTO> = try await get(
                path: AppEndpoints.GitHubREST.Paths.currentUserInstallations,
                queryItems: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "per_page", value: "100")
                ]
            )
            if response.value.installations.contains(where: {
                $0.appSlug.caseInsensitiveCompare(normalizedSlug) == .orderedSame
            }) {
                return true
            }
            guard let nextPage = response.linkHeader.nextPage else { return false }
            page = nextPage
        }
    }
}
