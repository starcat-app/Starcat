//
//  OwnerFollowService.swift
//  Starcat
//
//  仓库详情页「owner 卡片」的数据与关注动作服务。
//
//  职责：
//  - 拉取任意 owner（`/users/{login}`）的公开 profile，供 OwnerCardSheet 展示；
//  - 查询 / 变更「当前用户是否已关注该 owner」。
//
//  设计取舍：
//  - **只缓存 profile，不缓存 follow 状态**：profile 是公开数据，与「谁登录」无关，跨账号
//    安全；follow 状态是「我」与 owner 的关系，切账号会串，因此每次实时查（一个 204/404 的
//    GET 很轻，authenticated 用户 rate limit 5000/h 绰绰有余），换取零串号 + 零 reset 接线。
//  - 未登录守卫在 UI 层做（OwnerCardSheet 读 `AuthSession.state.isAuthenticated`），
//    service 保持无状态、不反向依赖 AuthSession，与 `StarActionService` 的「未登录抛错」不同——
//    这里直接把登录引导留在 View，避免 service 引入 AuthSession 双向引用。
//

import Foundation

/// owner 卡片的数据与关注动作服务。
///
/// `@MainActor`：profile 内存缓存字典在 `profile(login:)` 内读写，标注主线程隔离保证
/// 并发调用（快速切换 repo 时多个 `.task` 并发拉取）不 data race。
@MainActor
final class OwnerFollowService {

    /// REST 调用入口；protocol 注入便于 Mock。
    private let apiClient: any GitHubAPIClientProtocol

    /// owner login → 公开 profile 的内存缓存。公开数据跨账号安全，App 生命周期内有效。
    private var profileCache: [String: GitHubUserDTO] = [:]

    init(apiClient: any GitHubAPIClientProtocol) {
        self.apiClient = apiClient
    }

    // MARK: - Profile

    /// 拉取 owner 公开 profile（带内存缓存，避免反复点开卡片重复打 API）。
    ///
    /// - Parameter login: owner 的 GitHub login（如 `apple`）。
    /// - Returns: 完整 `GitHubUserDTO`（name / bio / followers / following / 等）。
    func profile(login: String) async throws -> GitHubUserDTO {
        if let cached = profileCache[login] {
            return cached
        }
        let dto = try await apiClient.getUser(login: login)
        profileCache[login] = dto
        return dto
    }

    // MARK: - Follow

    /// 当前用户是否已关注 `login`。实时查询，不缓存（见文件头「设计取舍」）。
    func isFollowing(login: String) async throws -> Bool {
        try await apiClient.isFollowing(login: login)
    }

    /// 关注或取关。
    ///
    /// - Parameter following: `true` = 关注，`false` = 取关。由调用方传入目标状态，
    ///   service 不再多查一次当前状态（UI 已持有）。
    func setFollowing(_ following: Bool, login: String) async throws {
        if following {
            try await apiClient.follow(login: login)
        } else {
            try await apiClient.unfollow(login: login)
        }
    }
}
