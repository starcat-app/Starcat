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
        let response: APIResponse<GitHubUserDTO> = try await get(path: AppEndpoints.GitHubREST.Paths.currentUser)
        do {
            let status = try await getCurrentUserStatus()
            return response.value.replacingStatus(status)
        } catch {
            // status 是个人资料的展示增强，不参与 token 健康检查。GraphQL 临时失败时保留登录态，
            // 让头像降级为无 status，避免一个非关键 badge 把启动恢复 / 登录流程打断。
            AppLog.network.warning("GitHub user status fetch failed: \(error.localizedDescription, privacy: .public)")
            return response.value
        }
    }

    private func getCurrentUserStatus() async throws -> GitHubUserStatusDTO? {
        let payload = try await graphql(
            query: """
            query StarcatCurrentUserStatus {
              viewer {
                status {
                  emoji
                  emojiHTML
                  message
                  expiresAt
                  indicatesLimitedAvailability
                  updatedAt
                }
              }
            }
            """,
            as: CurrentUserStatusPayload.self
        )
        return payload.viewer.status
    }
}

private struct CurrentUserStatusPayload: Decodable {
    let viewer: Viewer

    struct Viewer: Decodable {
        let status: GitHubUserStatusDTO?
    }
}
