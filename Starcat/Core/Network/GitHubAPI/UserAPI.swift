//
//  UserAPI.swift
//  Starcat
//
//  GET /user 端点封装，用于：
//  - 登录后获取当前用户信息（avatar、login、name）
//  - Token 健康检查（401 即代表 token 失效）
//

import Foundation

extension GitHubAPIClient {

    /// 获取当前授权用户。
    func getCurrentUser() async throws -> GitHubUserDTO {
        let response: APIResponse<GitHubUserDTO> = try await get(path: "/user")
        return response.value
    }
}
