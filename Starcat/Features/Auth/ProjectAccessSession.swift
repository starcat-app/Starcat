//
//  ProjectAccessSession.swift
//  Starcat
//
//  “我的项目”GitHub App 授权状态机与 OAuth / GitHub App 凭据路由。
//
//  与 `AuthSession` 的边界：
//  - 本状态机只决定项目可见范围，不代表 Starcat 主账号登录；
//  - GitHub App 授权失败、过期、撤销或断开均不得删除现有 OAuth token；
//  - GitHub App 不可用时自动回退 OAuth public 项目，不扩大 OAuth scope。
//

import Foundation
import Observation

enum ProjectAccessFailureCode: String, Equatable, Sendable {
    case configuration
    case network
    case storage
    case authorizationDenied = "authorization_denied"
    case reauthorizationRequired = "reauthorization_required"
    case invalidResponse = "invalid_response"
    case unknown
}

enum ProjectAccessState: Equatable, Sendable {
    case unavailable
    case disconnected
    case connecting
    /// GitHub App 安装页已打开，等待 `starcat://github-app/callback`。
    case awaitingAuthorization
    /// Web Flow 已成功，但当前 App 尚无可访问安装；凭据保留以支持安装后直接复查。
    case installationRequired
    /// 已有 GitHub App Web Flow 凭据，但安装状态暂时无法验证；与首次授权失败分开呈现。
    case installationCheckFailed(ProjectAccessFailureCode)
    case connected(expiresAt: Date?)
    case partialAuthorization
    case organizationApprovalPending
    case expired
    case revoked
    /// 远端 grant 撤销失败；本机凭据仍保留，用户可安全重试断开。
    case disconnectionFailed(ProjectAccessFailureCode)
    case failed(ProjectAccessFailureCode)
}

enum ProjectAccessSessionError: Error, Equatable {
    case unavailable
    case missingCredential
    case expired
    case storage
}

/// GitHub App 系统认证窗口结束后的有限结果。
///
/// UI 只需要区分“可同步”“用户取消”和“失败”，具体错误已经由状态机映射为稳定状态，
/// 不应把 OAuth 响应正文继续传到视图层。
enum ProjectAccessConnectionResult: Equatable, Sendable {
    case connected(GitHubAppInstallationAccess)
    case cancelled
    case failed
}

@MainActor
protocol ProjectAccessConnectionHistoryStoring: AnyObject {
    func hasCompletedAuthorization(for userID: Int64) -> Bool
    func markAuthorizationCompleted(for userID: Int64)
}

@MainActor
protocol ProjectAccessDisconnectProgressStoring: AnyObject {
    func isGrantRevoked(for userID: Int64) -> Bool
    func markGrantRevoked(for userID: Int64)
    func clearGrantRevoked(for userID: Int64)
}

/// 保存“远端 grant 已撤销、等待本地清理”的非敏感恢复点。
///
/// GitHub 撤销和本地数据库 / Keychain 无法组成同一个事务。远端成功后先落这个标记，
/// 即使数据库清理失败或 App 重启，下一次重试也不会依赖已经失效的 token 再次撤销。
@MainActor
final class UserDefaultsProjectAccessDisconnectProgress:
    ProjectAccessDisconnectProgressStoring
{
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "projectAccess.grantRevokedPendingCleanup.v1"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func isGrantRevoked(for userID: Int64) -> Bool {
        guard !TestEnvironment.isRunning else { return false }
        return defaults.bool(forKey: key(for: userID))
    }

    func markGrantRevoked(for userID: Int64) {
        guard !TestEnvironment.isRunning else { return }
        defaults.set(true, forKey: key(for: userID))
    }

    func clearGrantRevoked(for userID: Int64) {
        guard !TestEnvironment.isRunning else { return }
        defaults.removeObject(forKey: key(for: userID))
    }

    private func key(for userID: Int64) -> String {
        "\(keyPrefix).\(userID)"
    }
}

/// 只保存“曾完成 GitHub App 授权”这一非敏感路由标记，token 仍只进入 Keychain。
///
/// 测试 host 禁止写入真实用户偏好，避免单测改变下一次人工授权应走的入口。
@MainActor
final class UserDefaultsProjectAccessConnectionHistory:
    ProjectAccessConnectionHistoryStoring
{
    private let defaults: UserDefaults
    private let keyPrefix: String
    private let legacyKey: String
    private let persistenceEnabled: Bool

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "projectAccess.hasCompletedAuthorization.v2",
        legacyKey: String = "projectAccess.hasCompletedAuthorization.v1",
        persistenceEnabled: Bool = !TestEnvironment.isRunning
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.legacyKey = legacyKey
        self.persistenceEnabled = persistenceEnabled
    }

    func hasCompletedAuthorization(for userID: Int64) -> Bool {
        guard persistenceEnabled else { return false }
        let scopedKey = key(for: userID)
        if defaults.object(forKey: scopedKey) != nil {
            return defaults.bool(forKey: scopedKey)
        }
        // 旧版只有全局布尔值。首次读到时只迁移给当前登录用户并删除旧 Key，
        // 防止后续切换账号时把另一用户误判为已完成授权。
        guard defaults.bool(forKey: legacyKey) else { return false }
        defaults.set(true, forKey: scopedKey)
        defaults.removeObject(forKey: legacyKey)
        return true
    }

    func markAuthorizationCompleted(for userID: Int64) {
        guard persistenceEnabled else { return }
        defaults.set(true, forKey: key(for: userID))
    }

    private func key(for userID: Int64) -> String {
        "\(keyPrefix).\(userID)"
    }
}

@MainActor
@Observable
final class ProjectAccessSession {
    typealias InstallationCheck = @Sendable (
        _ accessToken: String,
        _ appSlug: String
    ) async throws -> GitHubAppInstallationAccess

    private(set) var state: ProjectAccessState

    private let oauthService: any ProjectAccessOAuthServiceProtocol
    private let keychain: any KeychainManaging
    private let webAuthenticationSession: any WebAuthenticationSessionProviding
    private let connectionHistory: any ProjectAccessConnectionHistoryStoring
    private let disconnectProgress: any ProjectAccessDisconnectProgressStoring
    private let isConfigured: Bool
    private let appSlug: String
    private let installationCheck: InstallationCheck
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var authorizationTask: Task<Void, Never>?
    private var isWebAuthenticationActive = false

    init(
        oauthService: any ProjectAccessOAuthServiceProtocol = ProjectAccessOAuthService(),
        keychain: any KeychainManaging = KeychainManager.shared,
        webAuthenticationSession: any WebAuthenticationSessionProviding =
            SystemWebAuthenticationSession(),
        connectionHistory: any ProjectAccessConnectionHistoryStoring =
            UserDefaultsProjectAccessConnectionHistory(),
        disconnectProgress: any ProjectAccessDisconnectProgressStoring =
            UserDefaultsProjectAccessDisconnectProgress(),
        isConfigured: Bool = AppConstants.isGitHubAppConfigured,
        appSlug: String = AppConstants.githubAppSlug,
        installationCheck: @escaping InstallationCheck = { accessToken, appSlug in
            let client = GitHubAPIClient(
                tokenProvider: ProjectSyncTokenProvider(token: accessToken)
            )
            return try await client.githubAppInstallationAccess(appSlug: appSlug)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.oauthService = oauthService
        self.keychain = keychain
        self.webAuthenticationSession = webAuthenticationSession
        self.connectionHistory = connectionHistory
        self.disconnectProgress = disconnectProgress
        self.isConfigured = isConfigured
        self.appSlug = appSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        self.installationCheck = installationCheck
        self.now = now
        state = isConfigured ? .disconnected : .unavailable
    }

    func restore(userID: Int64) {
        guard isConfigured else {
            state = .unavailable
            return
        }
        do {
            guard let credential = try loadCredential() else {
                state = .disconnected
                return
            }
            connectionHistory.markAuthorizationCompleted(for: userID)
            if isRefreshExpired(credential) {
                state = .expired
            } else {
                state = .connected(expiresAt: credential.accessExpiresAt)
            }
        } catch {
            state = .failed(.storage)
        }
    }

    /// 首次连接走安装联动；已有连接历史时直接重新授权，避免已有安装不触发 callback。
    @discardableResult
    func beginConnection(
        userID: Int64,
        modeOverride: ProjectAccessAuthorizationMode? = nil
    ) async throws -> ProjectAccessAuthorizationInfo {
        guard isConfigured else {
            state = .unavailable
            throw ProjectAccessSessionError.unavailable
        }
        state = .connecting
        do {
            let mode: ProjectAccessAuthorizationMode = modeOverride
                ?? (connectionHistory.hasCompletedAuthorization(for: userID)
                    ? .reauthorization
                    : .installation)
            let info = try await oauthService.beginAuthorization(mode: mode)
            state = .awaitingAuthorization
            return info
        } catch {
            state = .failed(Self.failureCode(error))
            throw error
        }
    }

    /// 在当前 Starcat 进程内启动 GitHub App 安装与用户授权。
    ///
    /// 与主登录复用同一种 `ASWebAuthenticationSession` 适配层，但必须持有独立实例：
    /// 用户可能在主登录之外单独管理项目权限，两条 OAuth 状态机和取消操作不能互相影响。
    /// 系统认证会话直接截获 `starcat://github-app/callback`，因此 App Store 与 Direct
    /// 同时安装时也不会依赖 Launch Services 猜测应唤醒哪个版本。
    func startConnection(
        userID: Int64,
        modeOverride: ProjectAccessAuthorizationMode? = nil,
        completion: @escaping @MainActor @Sendable (ProjectAccessConnectionResult) -> Void
    ) {
        authorizationTask?.cancel()
        if isWebAuthenticationActive {
            webAuthenticationSession.cancel()
            isWebAuthenticationActive = false
        }

        authorizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let info = try await beginConnection(
                    userID: userID,
                    modeOverride: modeOverride
                )
                try Task.checkCancellation()
                do {
                    try webAuthenticationSession.start(
                        authorizationURL: info.authorizationURL,
                        callbackURLScheme: AppConstants.oauthCallbackScheme
                    ) { [weak self] result in
                        self?.handleWebAuthenticationResult(
                            result,
                            userID: userID,
                            completion: completion
                        )
                    }
                } catch {
                    // OAuth state 已经进入 awaiting；系统窗口若无法启动，必须同步清理，
                    // 否则后续重试会携带一份用户从未看到过的旧 state。
                    await oauthService.reset()
                    state = .failed(.unknown)
                    throw error
                }
                isWebAuthenticationActive = true
                authorizationTask = nil
            } catch is CancellationError {
                // cancelConnection 负责重置 OAuth state 和可见状态。
            } catch {
                authorizationTask = nil
                completion(.failed)
            }
        }
    }

    /// 消费 GitHub App callback，保存独立凭据并立即验证安装范围。
    @discardableResult
    func completeConnection(
        callbackURL: URL,
        userID: Int64
    ) async throws -> GitHubAppInstallationAccess {
        guard isConfigured else {
            state = .unavailable
            throw ProjectAccessSessionError.unavailable
        }
        let credential: ProjectAccessCredential
        do {
            credential = try await oauthService.exchangeCallback(callbackURL)
            try saveCredential(credential)
            connectionHistory.markAuthorizationCompleted(for: userID)
        } catch {
            state = .failed(Self.failureCode(error))
            throw error
        }
        do {
            return try await updateInstallationState(using: credential)
        } catch NetworkError.unauthorized {
            markRevoked()
            throw NetworkError.unauthorized
        } catch {
            // 凭据已经安全保存，安装校验失败不应让用户重复授权。
            state = .installationCheckFailed(Self.failureCode(error))
            throw error
        }
    }

    /// 组织批准或仓库范围变化后重新检查，无需重复 GitHub App OAuth。
    ///
    /// Web Flow 凭据会在 `.installationRequired` 状态保留，因此用户完成安装后可以直接
    /// 点击“重新检查”。返回值同时携带全部仓库或指定仓库范围。
    @discardableResult
    func refreshInstallationState() async throws -> GitHubAppInstallationAccess {
        guard isConfigured else {
            state = .unavailable
            throw ProjectAccessSessionError.unavailable
        }
        guard let credential = try loadCredential() else {
            state = .disconnected
            throw ProjectAccessSessionError.missingCredential
        }
        let usableCredential = try await refreshedCredentialIfNeeded(credential)
        do {
            return try await updateInstallationState(using: usableCredential)
        } catch NetworkError.unauthorized {
            markRevoked()
            throw NetworkError.unauthorized
        } catch {
            state = .installationCheckFailed(Self.failureCode(error))
            throw error
        }
    }

    func cancelConnection() async {
        authorizationTask?.cancel()
        authorizationTask = nil
        if isWebAuthenticationActive {
            webAuthenticationSession.cancel()
            isWebAuthenticationActive = false
        }
        await oauthService.reset()
        state = isConfigured ? .disconnected : .unavailable
    }

    /// 执行完整断开；不涉及项目关系的调用方可使用这个便捷入口。
    func disconnect(userID: Int64) async throws {
        try await prepareDisconnect(userID: userID)
        try finishDisconnect(userID: userID)
    }

    /// 撤销 GitHub 侧完整 user grant，并持久化“等待本地清理”的恢复点。
    ///
    /// UserProjectSyncService 会在此后删除项目关系，再调用 `finishDisconnect` 清理 Keychain。
    /// 如果中间步骤失败，下一次调用会命中恢复点并跳过重复的远端撤销。
    func prepareDisconnect(userID: Int64) async throws {
        if disconnectProgress.isGrantRevoked(for: userID) {
            return
        }
        guard let credential = try loadCredential() else {
            state = isConfigured ? .disconnected : .unavailable
            return
        }
        connectionHistory.markAuthorizationCompleted(for: userID)
        let usableCredential = try await credentialForDisconnect(credential)
        do {
            try await oauthService.revokeAuthorization(
                accessToken: usableCredential.accessToken
            )
        } catch {
            state = .disconnectionFailed(Self.failureCode(error))
            throw error
        }
        disconnectProgress.markGrantRevoked(for: userID)
    }

    /// 仅在项目关系已经清理后删除本机凭据并结束断开恢复点。
    func finishDisconnect(userID: Int64) throws {
        do {
            try keychain.deleteProjectAccessCredential()
            disconnectProgress.clearGrantRevoked(for: userID)
            state = isConfigured ? .disconnected : .unavailable
        } catch {
            state = .disconnectionFailed(.storage)
            throw ProjectAccessSessionError.storage
        }
    }

    /// 数据库关系清理失败时保持可重试状态，不能发布为已断开。
    func markDisconnectCleanupFailed() {
        state = .disconnectionFailed(.storage)
    }

    /// 没有当前 GitHub 用户的本地授权历史时，UI 应提供显式 OAuth 入口。
    ///
    /// 该入口用于 GitHub App 已由另一渠道或手动安装、但当前 Starcat 没有回调历史的场景。
    func shouldOfferExplicitReauthorization(for userID: Int64) -> Bool {
        !connectionHistory.hasCompletedAuthorization(for: userID)
    }

    /// 返回可用 GitHub App user token；access token 临近过期时先原子轮换整份凭据。
    func validAccessToken() async throws -> String {
        guard isConfigured else {
            state = .unavailable
            throw ProjectAccessSessionError.unavailable
        }
        guard let credential = try loadCredential() else {
            state = .disconnected
            throw ProjectAccessSessionError.missingCredential
        }
        if let accessExpiry = credential.accessExpiresAt,
           accessExpiry <= now().addingTimeInterval(60) {
            guard let refreshToken = credential.refreshToken,
                  !isRefreshExpired(credential) else {
                state = .expired
                throw ProjectAccessSessionError.expired
            }
            do {
                let refreshed = try await oauthService.refreshCredential(using: refreshToken)
                try saveCredential(refreshed)
                publishCredentialState(expiresAt: refreshed.accessExpiresAt)
                return refreshed.accessToken
            } catch ProjectAccessOAuthError.badRefreshToken {
                try? keychain.deleteProjectAccessCredential()
                state = .expired
                throw ProjectAccessSessionError.expired
            } catch {
                state = .failed(Self.failureCode(error))
                throw error
            }
        }
        publishCredentialState(expiresAt: credential.accessExpiresAt)
        return credential.accessToken
    }

    /// 项目 API 返回 401 时只撤销 GitHub App 项目授权，不触碰主 OAuth 登录。
    func markRevoked() {
        try? keychain.deleteProjectAccessCredential()
        state = .revoked
    }

    func markPartialAuthorization() {
        state = .partialAuthorization
    }

    func markOrganizationApprovalPending() {
        state = .organizationApprovalPending
    }

    /// 校验安装并发布状态。没有安装是可恢复状态，不删除已经取得的 Web Flow 凭据；
    /// selected repositories 必须保持独立状态，不能伪装成完整授权。
    @discardableResult
    private func updateInstallationState(
        using credential: ProjectAccessCredential
    ) async throws -> GitHubAppInstallationAccess {
        let access = try await installationCheck(credential.accessToken, appSlug)
        state = switch access {
        case .notInstalled:
            .installationRequired
        case .allRepositories:
            .connected(expiresAt: credential.accessExpiresAt)
        case .selectedRepositories:
            .partialAuthorization
        }
        return access
    }

    /// 为“撤销整个 grant”准备有效 token，但绝不能像普通同步刷新那样删除旧凭据。
    ///
    /// 删除 grant 的 GitHub API 要求有效 access token。refresh 已失效时必须保留当前凭据，
    /// 让 UI 先完成一次显式重新授权，再使用新 token 继续原来的断开操作。
    private func credentialForDisconnect(
        _ credential: ProjectAccessCredential
    ) async throws -> ProjectAccessCredential {
        guard let accessExpiry = credential.accessExpiresAt,
              accessExpiry <= now().addingTimeInterval(60)
        else {
            return credential
        }
        guard let refreshToken = credential.refreshToken,
              !isRefreshExpired(credential)
        else {
            state = .disconnectionFailed(.reauthorizationRequired)
            throw ProjectAccessSessionError.expired
        }
        do {
            let refreshed = try await oauthService.refreshCredential(using: refreshToken)
            try saveCredential(refreshed)
            return refreshed
        } catch ProjectAccessOAuthError.badRefreshToken {
            state = .disconnectionFailed(.reauthorizationRequired)
            throw ProjectAccessSessionError.expired
        } catch {
            state = .disconnectionFailed(Self.failureCode(error))
            throw error
        }
    }

    /// 复查安装前只处理 token 轮换，不提前把界面改成 connected。
    private func refreshedCredentialIfNeeded(
        _ credential: ProjectAccessCredential
    ) async throws -> ProjectAccessCredential {
        guard let accessExpiry = credential.accessExpiresAt,
              accessExpiry <= now().addingTimeInterval(60)
        else {
            return credential
        }
        guard let refreshToken = credential.refreshToken,
              !isRefreshExpired(credential)
        else {
            state = .expired
            throw ProjectAccessSessionError.expired
        }
        do {
            let refreshed = try await oauthService.refreshCredential(using: refreshToken)
            try saveCredential(refreshed)
            return refreshed
        } catch ProjectAccessOAuthError.badRefreshToken {
            try? keychain.deleteProjectAccessCredential()
            state = .expired
            throw ProjectAccessSessionError.expired
        }
    }

    /// 刷新 token 不应抹掉“未安装 / 部分授权 / 待组织审批”等更具体的产品状态。
    private func publishCredentialState(expiresAt: Date?) {
        switch state {
        case .installationRequired, .installationCheckFailed,
             .partialAuthorization, .organizationApprovalPending,
             .disconnectionFailed:
            break
        default:
            state = .connected(expiresAt: expiresAt)
        }
    }

    private func loadCredential() throws -> ProjectAccessCredential? {
        guard let json = try keychain.loadProjectAccessCredential() else { return nil }
        guard let data = json.data(using: .utf8) else {
            throw ProjectAccessSessionError.storage
        }
        do {
            return try decoder.decode(ProjectAccessCredential.self, from: data)
        } catch {
            throw ProjectAccessSessionError.storage
        }
    }

    private func saveCredential(_ credential: ProjectAccessCredential) throws {
        do {
            let data = try encoder.encode(credential)
            guard let json = String(data: data, encoding: .utf8) else {
                throw ProjectAccessSessionError.storage
            }
            try keychain.storeProjectAccessCredential(json)
        } catch {
            throw ProjectAccessSessionError.storage
        }
    }

    /// 将系统认证结果收口到项目权限状态机；回调始终位于 MainActor。
    private func handleWebAuthenticationResult(
        _ result: Result<URL, WebAuthenticationSessionError>,
        userID: Int64,
        completion: @escaping @MainActor @Sendable (ProjectAccessConnectionResult) -> Void
    ) {
        authorizationTask = nil
        isWebAuthenticationActive = false
        switch result {
        case .success(let callbackURL):
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let access = try await completeConnection(
                        callbackURL: callbackURL,
                        userID: userID
                    )
                    completion(.connected(access))
                } catch {
                    completion(.failed)
                }
            }
        case .failure(.cancelled):
            Task { @MainActor [weak self] in
                guard let self else { return }
                await cancelConnection()
                completion(.cancelled)
            }
        case .failure:
            state = .failed(.unknown)
            Task { await oauthService.reset() }
            completion(.failed)
        }
    }

    private func isRefreshExpired(_ credential: ProjectAccessCredential) -> Bool {
        guard credential.accessExpiresAt.map({ $0 <= now().addingTimeInterval(60) }) == true else {
            return false
        }
        guard credential.refreshToken != nil else { return true }
        return credential.refreshExpiresAt.map { $0 <= now().addingTimeInterval(60) } ?? false
    }

    private static func failureCode(_ error: Error) -> ProjectAccessFailureCode {
        if let network = error as? NetworkError {
            return switch network {
            case .transport, .serverError, .rateLimited:
                .network
            default:
                .invalidResponse
            }
        }
        guard let oauth = error as? ProjectAccessOAuthError else {
            return error is ProjectAccessSessionError ? .storage : .unknown
        }
        return switch oauth {
        case .configurationMissing: .configuration
        case .network: .network
        case .userDeclined: .authorizationDenied
        case .flowNotStarted, .codeExpired, .badRefreshToken,
             .invalidCallback, .stateMismatch, .invalidResponse:
            .invalidResponse
        case .httpStatus(let status):
            (500...599).contains(status) ? .network : .invalidResponse
        }
    }
}

struct ResolvedProjectCredential: Equatable, Sendable {
    let accessToken: String
    let authorizationSource: ProjectAuthorizationSource
}

/// 按“项目读取”用途选择凭据：GitHub App 优先，失败时回退现有 OAuth public token。
@MainActor
final class ProjectCredentialRouter {
    private let projectAccessSession: ProjectAccessSession
    private let keychain: any KeychainManaging

    init(
        projectAccessSession: ProjectAccessSession,
        keychain: any KeychainManaging = KeychainManager.shared
    ) {
        self.projectAccessSession = projectAccessSession
        self.keychain = keychain
    }

    func resolve() async throws -> ResolvedProjectCredential {
        // Web Flow 成功但 App 尚未安装时，user token 不具备项目访问范围；继续用它会把
        // “未安装”误报为同步失败，因此明确回退主 OAuth 的 Public 项目。
        let installationMissing = projectAccessSession.state == .installationRequired
        if !installationMissing,
           let projectToken = try? await projectAccessSession.validAccessToken() {
            return ResolvedProjectCredential(
                accessToken: projectToken,
                authorizationSource: .githubApp
            )
        }
        guard let oauthToken = try keychain.loadGithubToken(), !oauthToken.isEmpty else {
            throw NetworkError.unauthorized
        }
        return ResolvedProjectCredential(
            accessToken: oauthToken,
            authorizationSource: .oauth
        )
    }
}

/// 一次同步固定使用同一 token，避免刷新中途凭据来源变化造成 generation 混写。
struct ProjectSyncTokenProvider: GitHubTokenProviding {
    let token: String
    func currentToken() async -> String? { token }
}

/// Private README 等按请求读取的 GitHub App token provider。
///
/// 与 `ProjectSyncTokenProvider` 的区别：项目全量同步要求整轮固定 token；详情 README
/// 请求应在每次发出前检查过期并刷新凭据，因此这里动态调用独立授权 session。
struct ProjectAccessTokenProvider: GitHubTokenProviding {
    let session: ProjectAccessSession

    func currentToken() async -> String? {
        try? await session.validAccessToken()
    }
}
