//
//  CompanionStarStateHandler.swift
//  Starcat
//
//  Browser Plugin 的 GitHub Star 状态对账入口。
//
//  插件只在 GitHub 页面已经确认按钮状态变化后发送“目标态”，本类型再复用
//  `StarActionService` 的唯一写入链路更新 GitHub、本地数据库与 StarredRegistry。
//  目标态而不是 toggle 能保证超时重试和快速连续点击不会把状态翻反。
//

import Foundation

enum CompanionStarStateError: Error, Equatable {
    case invalidRepoPath
}

struct CompanionStarStateHandler {
    private let lookupRepo: @Sendable (String, String) async throws -> Repo?
    private let star: @MainActor @Sendable (String, String) async throws -> Repo
    private let unstar: @MainActor @Sendable (Repo) async throws -> Void

    init(
        repoRepository: any RepoRepositoryProtocol,
        starActionService: StarActionService
    ) {
        self.init(
            lookupRepo: { owner, name in
                try await repoRepository.findByOwnerName(owner: owner, name: name)
            },
            star: { owner, name in
                try await starActionService.star(owner: owner, repo: name)
            },
            unstar: { repo in
                try await starActionService.unstar(repo: repo)
            }
        )
    }

    /// 测试注入点。闭包保留与生产链路相同的顺序约束，但不需要构造完整 AppDependencies。
    init(
        lookupRepo: @escaping @Sendable (String, String) async throws -> Repo?,
        star: @escaping @MainActor @Sendable (String, String) async throws -> Repo,
        unstar: @escaping @MainActor @Sendable (Repo) async throws -> Void
    ) {
        self.lookupRepo = lookupRepo
        self.star = star
        self.unstar = unstar
    }

    func apply(
        owner rawOwner: String,
        repo rawRepo: String,
        state: CompanionStarState
    ) async throws -> CompanionStarStateUpdateResponse {
        let owner = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CompanionContextProvider.isValidGitHubPathComponent(owner),
              CompanionContextProvider.isValidGitHubPathComponent(name) else {
            throw CompanionStarStateError.invalidRepoPath
        }

        switch state {
        case .starred:
            // PUT Star 是幂等操作；即使 GitHub 页面已经完成 Star，再走权威服务
            // 也能用同一条路径补齐 repo 元数据、DB、Registry 与 Home 刷新。
            let saved = try await star(owner, name)
            return CompanionStarStateUpdateResponse(
                schemaVersion: 1,
                status: "ok",
                repoID: saved.id,
                state: .starred
            )

        case .unstarred:
            // 未知或本地已经 unstarred 都视为目标态已达成。这里不能为了“补一次
            // DELETE”绕过 StarActionService，因为 Registry 的写入口有文件级约束。
            guard let localRepo = try await lookupRepo(owner, name) else {
                return CompanionStarStateUpdateResponse(
                    schemaVersion: 1,
                    status: "ok",
                    repoID: nil,
                    state: .unstarred
                )
            }
            if localRepo.isStarred {
                try await unstar(localRepo)
            }
            return CompanionStarStateUpdateResponse(
                schemaVersion: 1,
                status: "ok",
                repoID: localRepo.id,
                state: .unstarred
            )
        }
    }
}
