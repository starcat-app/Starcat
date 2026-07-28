//
//  UserProjectSyncCoordinator.swift
//  Starcat
//
//  “我的项目”两条 affiliation 分页链同步协调器。
//
//  并发约束：
//  - owner 与 organization_member 最多并行两条链，避免一次授权制造无界请求；
//  - 相同用户、凭据和刷新模式的并发触发共享同一个 Task；
//  - 每条链逐页串行，只有完整读取 Link Header 到末页后才做 generation 对账；
//  - 一条链失败不取消另一条链，成功的 affiliation 仍可提交，失败链保留旧关系。
//

import Foundation

struct UserProjectSyncSummary: Equatable, Sendable {
    let receivedCount: Int
    let unchangedAffiliations: Set<ProjectAffiliation>
}

actor UserProjectSyncCoordinator {
    private struct SyncKey: Equatable {
        let userID: Int64
        let authorizationSource: ProjectAuthorizationSource
        let force: Bool
    }

    private struct AffiliationResult: Sendable {
        let receivedCount: Int
        let unchanged: Bool
    }

    private let api: any UserProjectsAPIProtocol
    private let repository: any UserProjectRepositoryProtocol
    private let now: @Sendable () -> Date
    private var inFlight: (key: SyncKey, task: Task<UserProjectSyncSummary, Error>)?

    init(
        api: any UserProjectsAPIProtocol,
        repository: any UserProjectRepositoryProtocol,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.repository = repository
        self.now = now
    }

    func sync(
        userID: Int64,
        authorizationSource: ProjectAuthorizationSource,
        force: Bool = false
    ) async throws -> UserProjectSyncSummary {
        let key = SyncKey(
            userID: userID,
            authorizationSource: authorizationSource,
            force: force
        )
        if let inFlight, inFlight.key == key {
            return try await inFlight.task.value
        }

        let task = Task {
            try await runSync(
                userID: userID,
                authorizationSource: authorizationSource,
                force: force
            )
        }
        inFlight = (key, task)
        do {
            let result = try await task.value
            if inFlight?.key == key {
                inFlight = nil
            }
            return result
        } catch {
            if inFlight?.key == key {
                inFlight = nil
            }
            throw error
        }
    }

    private func runSync(
        userID: Int64,
        authorizationSource: ProjectAuthorizationSource,
        force: Bool
    ) async throws -> UserProjectSyncSummary {
        // OAuth App 的既有 public_repo 授权只承担公开 fallback；只有 GitHub App
        // user token 可以请求 all。由同步器固定映射，调用方无法误传扩大范围。
        let visibility: UserProjectsAPIVisibility = switch authorizationSource {
        case .oauth: .publicOnly
        case .githubApp: .all
        }
        async let owner = syncAffiliationResult(
            .owner,
            userID: userID,
            authorizationSource: authorizationSource,
            visibility: visibility,
            force: force
        )
        async let organization = syncAffiliationResult(
            .organizationMember,
            userID: userID,
            authorizationSource: authorizationSource,
            visibility: visibility,
            force: force
        )
        let results = await [owner, organization]

        var receivedCount = 0
        var unchanged: Set<ProjectAffiliation> = []
        var firstError: Error?
        for (affiliation, result) in zip(ProjectAffiliation.allCases, results) {
            switch result {
            case .success(let value):
                receivedCount += value.receivedCount
                if value.unchanged {
                    unchanged.insert(affiliation)
                }
            case .failure(let error):
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
        return UserProjectSyncSummary(
            receivedCount: receivedCount,
            unchangedAffiliations: unchanged
        )
    }

    private func syncAffiliationResult(
        _ affiliation: ProjectAffiliation,
        userID: Int64,
        authorizationSource: ProjectAuthorizationSource,
        visibility: UserProjectsAPIVisibility,
        force: Bool
    ) async -> Result<AffiliationResult, Error> {
        do {
            return .success(
                try await syncAffiliation(
                    affiliation,
                    userID: userID,
                    authorizationSource: authorizationSource,
                    visibility: visibility,
                    force: force
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private func syncAffiliation(
        _ affiliation: ProjectAffiliation,
        userID: Int64,
        authorizationSource: ProjectAuthorizationSource,
        visibility: UserProjectsAPIVisibility,
        force: Bool
    ) async throws -> AffiliationResult {
        let generation = UUID().uuidString
        let startedAt = now()
        let previousState = try await repository.fetchSyncState(
            userID: userID,
            affiliation: affiliation,
            authorizationSource: authorizationSource
        )
        try await repository.beginGeneration(
            userID: userID,
            affiliation: affiliation,
            authorizationSource: authorizationSource,
            generation: generation,
            startedAt: startedAt
        )

        do {
            var page = 1
            var receivedCount = 0
            var firstPageETag: String?
            while true {
                try Task.checkCancellation()
                let response = try await api.userProjects(
                    affiliation: affiliation,
                    visibility: visibility,
                    page: page,
                    perPage: 100,
                    ifNoneMatch: page == 1 && !force ? previousState?.etag : nil
                )
                if page == 1 {
                    firstPageETag = response.etag
                }
                let projects = response.value.map { $0.remoteProject(affiliation: affiliation) }
                try await repository.upsertPage(
                    projects,
                    userID: userID,
                    authorizationSource: authorizationSource,
                    generation: generation,
                    seenAt: now()
                )
                receivedCount += projects.count

                guard let nextPage = response.linkHeader.nextPage else { break }
                page = nextPage
            }

            try await repository.completeGeneration(
                userID: userID,
                affiliation: affiliation,
                authorizationSource: authorizationSource,
                generation: generation,
                etag: firstPageETag,
                completedAt: now()
            )
            return AffiliationResult(receivedCount: receivedCount, unchanged: false)
        } catch NetworkError.notModified(let responseETag) {
            // 304 表示服务端集合未变化。沿用上次成功 generation 完成一次“触达”，
            // 同时清掉先前失败请求可能留下的半代际行。
            guard let previousGeneration = previousState?.generation else {
                let error = NetworkError.invalidResponse
                try await repository.failGeneration(
                    userID: userID,
                    affiliation: affiliation,
                    authorizationSource: authorizationSource,
                    generation: generation,
                    errorCode: Self.errorCode(error),
                    failedAt: now()
                )
                throw error
            }
            try await repository.completeGeneration(
                userID: userID,
                affiliation: affiliation,
                authorizationSource: authorizationSource,
                generation: previousGeneration,
                etag: responseETag ?? previousState?.etag,
                completedAt: now()
            )
            return AffiliationResult(receivedCount: 0, unchanged: true)
        } catch {
            try await repository.failGeneration(
                userID: userID,
                affiliation: affiliation,
                authorizationSource: authorizationSource,
                generation: generation,
                errorCode: Self.errorCode(error),
                failedAt: now()
            )
            throw error
        }
    }

    private static func errorCode(_ error: Error) -> String {
        guard let network = error as? NetworkError else {
            return error is CancellationError ? "cancelled" : "unknown"
        }
        return switch network {
        case .invalidURL: "invalid_url"
        case .invalidResponse: "invalid_response"
        case .unauthorized: "unauthorized"
        case .rateLimited: "rate_limited"
        case .notModified: "not_modified"
        case .notFound: "not_found"
        case .serverError: "server_error"
        case .clientError(let statusCode, _): "client_\(statusCode)"
        case .decodingError: "decoding"
        case .transport: "transport"
        case .cancelled: "cancelled"
        }
    }
}
