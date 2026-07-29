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
        let installationAccess: GitHubAppInstallationAccess?
    }

    private struct PreparedCredential: Sendable {
        let credential: ResolvedProjectCredential
        let installationAccess: GitHubAppInstallationAccess?
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

    /// 用户主动断开 GitHub App：先撤销 GitHub 侧完整 user grant，再删除独立凭据与
    /// GitHub App 来源关系；保留 OAuth Public 关系、Repo 记录和全部用户内容。
    /// 远端撤销失败会提前抛错，因此本机关系不会出现“已断开”的假状态。
    func disconnectProjectAccess(userID: Int64) async throws {
        try await projectAccessSession.disconnect()
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
            let initialCredential = try await resolveCredential()
            let prepared = try await prepareCredentialForSync(
                userID: userID,
                initialCredential: initialCredential
            )
            return SyncResult(
                summary: try await performSync(userID, prepared.credential, force),
                authorizationSource: prepared.credential.authorizationSource,
                installationAccess: prepared.installationAccess
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
                } else if summary.isPartial
                    || result.installationAccess == .selectedRepositories {
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

    /// GitHub App 同步前复查安装范围，避免安装被删除后继续把旧凭据当作完整授权。
    ///
    /// `/user/installations` 返回未安装时，独立 GitHub App Web Flow 凭据会保留，方便用户重新安装后
    /// 直接复查；GitHub App 来源关系立即移除，并在同一次刷新中重新解析为 OAuth Public
    /// fallback。复查过程若轮换了 access token，也必须重新解析凭据，不能继续使用旧 token。
    private func prepareCredentialForSync(
        userID: Int64,
        initialCredential: ResolvedProjectCredential
    ) async throws -> PreparedCredential {
        guard initialCredential.authorizationSource == .githubApp else {
            return PreparedCredential(
                credential: initialCredential,
                installationAccess: nil
            )
        }

        let access = try await projectAccessSession.refreshInstallationState()
        if access == .notInstalled {
            try await repository?.deleteRelations(
                userID: userID,
                authorizationSource: .githubApp
            )
        }
        let currentCredential = try await resolveCredential()
        return PreparedCredential(
            credential: currentCredential,
            installationAccess: access.isInstalled ? access : nil
        )
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
