//
//  UserProjectSyncService.swift
//  Starcat
//
//  “我的项目”应用级同步服务。
//
//  模块职责：
//  - 为一次同步解析并固定 OAuth / GitHub App 凭据来源；
//  - 统一维护手动、启动与系统后台刷新共享的可观察状态；
//  - GitHub App 返回 401 时只撤销项目授权，不影响 Starcat 主登录会话；
//  - 后台调度只持有当前用户 ID，不记录仓库名称或任何 Private 元数据。
//

import Foundation
import Observation

enum UserProjectSyncFailureCode: String, Equatable, Sendable {
    case unavailable
    case unauthorized
    case rateLimited = "rate_limited"
    case network
    case storage
    case unknown
}

enum UserProjectSyncServiceState: Equatable, Sendable {
    case idle
    case syncing
    case completed(at: Date, receivedCount: Int)
    case failed(UserProjectSyncFailureCode)
}

@MainActor
@Observable
final class UserProjectSyncService {
    nonisolated static let defaultInterval: TimeInterval = 4 * 60 * 60
    nonisolated static let defaultTolerance: TimeInterval = 30 * 60

    typealias CredentialResolver = @MainActor () async throws -> ResolvedProjectCredential
    typealias SyncOperation = @MainActor (
        _ userID: Int64,
        _ credential: ResolvedProjectCredential,
        _ force: Bool
    ) async throws -> UserProjectSyncSummary

    private let projectAccessSession: ProjectAccessSession
    private let repository: (any UserProjectRepositoryProtocol)?
    private let resolveCredential: CredentialResolver
    private let performSync: SyncOperation
    private let now: @Sendable () -> Date

    private struct SyncResult: Sendable {
        let summary: UserProjectSyncSummary
        let authorizationSource: ProjectAuthorizationSource
    }

    private var scheduler: NSBackgroundActivityScheduler?
    private var backgroundUserID: Int64?
    private var inFlightTask: Task<SyncResult, Error>?

    private(set) var state: UserProjectSyncServiceState = .idle
    private(set) var isBackgroundRefreshEnabled = false

    init(
        repository: any UserProjectRepositoryProtocol,
        projectAccessSession: ProjectAccessSession,
        credentialRouter: ProjectCredentialRouter,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.projectAccessSession = projectAccessSession
        self.repository = repository
        self.resolveCredential = {
            try await credentialRouter.resolve()
        }
        self.performSync = { [weak projectAccessSession] userID, credential, force in
            let client = GitHubAPIClient(
                tokenProvider: ProjectSyncTokenProvider(token: credential.accessToken)
            )
            if credential.authorizationSource == .githubApp {
                await client.setUnauthorizedHandler {
                    Task { @MainActor in
                        projectAccessSession?.markRevoked()
                    }
                }
            }
            let coordinator = UserProjectSyncCoordinator(
                api: client,
                repository: repository
            )
            do {
                return try await coordinator.sync(
                    userID: userID,
                    authorizationSource: credential.authorizationSource,
                    force: force
                )
            } catch NetworkError.unauthorized where credential.authorizationSource == .githubApp {
                await MainActor.run {
                    projectAccessSession?.markRevoked()
                }
                try? await repository.deleteRelations(
                    userID: userID,
                    authorizationSource: .githubApp
                )
                throw NetworkError.unauthorized
            }
        }
        self.now = now
    }

    /// 测试构造器：把网络和凭据边界替换成确定性闭包，验证服务自身的状态与去重语义。
    init(
        projectAccessSession: ProjectAccessSession,
        resolveCredential: @escaping CredentialResolver,
        performSync: @escaping SyncOperation,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.projectAccessSession = projectAccessSession
        self.repository = nil
        self.resolveCredential = resolveCredential
        self.performSync = performSync
        self.now = now
    }

    /// 恢复独立项目授权。测试 host 不应主动访问 Keychain，调用方负责门控。
    func restoreAccess() {
        projectAccessSession.restore()
    }

    /// 启动系统后台刷新。重复传入同一用户为 no-op；切换用户时会重建 scheduler。
    func startBackgroundRefresh(
        userID: Int64,
        interval: TimeInterval = UserProjectSyncService.defaultInterval,
        tolerance: TimeInterval = UserProjectSyncService.defaultTolerance
    ) {
        if scheduler != nil, backgroundUserID == userID {
            return
        }
        stopBackgroundRefresh()

        let activity = NSBackgroundActivityScheduler(
            identifier: "\(AppConstants.bundleIdentifier).userProjectSync"
        )
        activity.repeats = true
        activity.interval = interval
        activity.tolerance = tolerance
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                guard let self, self.backgroundUserID == userID else {
                    completion(.finished)
                    return
                }
                _ = try? await self.refresh(userID: userID)
                completion(.finished)
            }
        }
        scheduler = activity
        backgroundUserID = userID
        isBackgroundRefreshEnabled = true
        AppLog.general.info("UserProjectSyncService background refresh started")
    }

    func stopBackgroundRefresh() {
        scheduler?.invalidate()
        scheduler = nil
        backgroundUserID = nil
        isBackgroundRefreshEnabled = false
        inFlightTask?.cancel()
        inFlightTask = nil
        if case .syncing = state {
            state = .idle
        }
    }

    /// 用户主动断开 GitHub App：删除独立凭据与 GitHub App 来源关系，保留 OAuth Public
    /// 关系、Repo 记录和全部用户内容。调用方随后可刷新一次 OAuth fallback。
    func disconnectProjectAccess(userID: Int64) async throws {
        try projectAccessSession.disconnect()
        try await repository?.deleteRelations(
            userID: userID,
            authorizationSource: .githubApp
        )
        state = .idle
    }

    /// 所有触发入口共享同一个 in-flight Task，避免启动刷新与手动刷新叠加生成两代数据。
    @discardableResult
    func refresh(userID: Int64, force: Bool = false) async throws -> UserProjectSyncSummary {
        if let inFlightTask {
            return try await inFlightTask.value.summary
        }

        state = .syncing
        let task = Task { @MainActor in
            let credential = try await resolveCredential()
            return SyncResult(
                summary: try await performSync(userID, credential, force),
                authorizationSource: credential.authorizationSource
            )
        }
        inFlightTask = task

        do {
            let result = try await task.value
            inFlightTask = nil
            if result.authorizationSource == .githubApp {
                let summary = result.summary
                if summary.isOrganizationApprovalPending {
                    projectAccessSession.markOrganizationApprovalPending()
                } else if summary.isPartial {
                    projectAccessSession.markPartialAuthorization()
                } else {
                    // 一次完整成功应清掉上轮 partial / approval pending 状态，并从独立
                    // Keychain 恢复真实到期时间；不触碰 Starcat 主 OAuth 会话。
                    projectAccessSession.restore()
                }
            }
            let summary = result.summary
            state = .completed(at: now(), receivedCount: summary.receivedCount)
            return summary
        } catch {
            inFlightTask = nil
            state = .failed(Self.failureCode(error))
            throw error
        }
    }

    private static func failureCode(_ error: Error) -> UserProjectSyncFailureCode {
        if let sessionError = error as? ProjectAccessSessionError {
            return switch sessionError {
            case .unavailable: .unavailable
            case .missingCredential: .unauthorized
            case .expired: .unauthorized
            case .storage: .storage
            }
        }
        guard let networkError = error as? NetworkError else {
            return error is CancellationError ? .network : .unknown
        }
        return switch networkError {
        case .unauthorized: .unauthorized
        case .rateLimited: .rateLimited
        case .transport, .serverError, .cancelled: .network
        case .invalidURL, .invalidResponse, .notModified, .notFound,
             .clientError, .decodingError: .unknown
        }
    }
}
