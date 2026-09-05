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

    // MARK: - 关注（follow）

    /// 获取任意用户公开 profile。
    func getUser(login: String) async throws -> GitHubUserDTO {
        let response: APIResponse<GitHubUserDTO> = try await get(
            path: AppEndpoints.GitHubREST.Paths.userProfile(login: login)
        )
        return response.value
    }

    /// 获取任意用户公开展示的社交账号。
    ///
    /// GitHub Profile 的 Social accounts 与传统 `blog` / `twitter_username` 是两套字段；
    /// owner 卡片必须额外请求本端点，才能拿到 Telegram 等通用链接。
    func getUserSocialAccounts(login: String) async throws -> [GitHubSocialAccountDTO] {
        let response: APIResponse<[GitHubSocialAccountDTO]> = try await get(
            path: AppEndpoints.GitHubREST.Paths.userSocialAccounts(login: login)
        )
        return response.value
    }

    /// 当前用户是否已关注 `login`。
    ///
    /// GitHub `GET /user/following/{login}` 语义：204 = 已关注，404 = 未关注。
    /// 用 `getBytes`（`performBytes`）而非 `get<T>` 是因为 204 无响应 body，
    /// 走 JSON 解码会误抛 decoding error；`performBytes` 对 404 抛 `NetworkError.notFound`，
    /// 在这里 catch 转成 `false`，其它错误原样上抛。
    func isFollowing(login: String) async throws -> Bool {
        do {
            _ = try await getBytes(
                path: AppEndpoints.GitHubREST.Paths.userFollowing(login: login),
                accept: "application/vnd.github+json"
            )
            return true
        } catch NetworkError.notFound {
            return false
        }
    }

    /// 关注用户。`put(path:)` 走 `performNoBody`，GitHub 204 No Content 即成功。
    func follow(login: String) async throws {
        try await put(path: AppEndpoints.GitHubREST.Paths.userFollowing(login: login))
    }

    /// 取消关注用户。`delete(path:)` 走 `performNoBody`，204 No Content 即成功。
    func unfollow(login: String) async throws {
        try await delete(path: AppEndpoints.GitHubREST.Paths.userFollowing(login: login))
    }
}

private struct CurrentUserStatusPayload: Decodable {
    let viewer: Viewer

    struct Viewer: Decodable {
        let status: GitHubUserStatusDTO?
    }
}
