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
    case invalidResponse = "invalid_response"
    case unknown
}

enum ProjectAccessState: Equatable, Sendable {
    case unavailable
    case disconnected
    case connecting
    case awaitingAuthorization(OAuthDeviceCodeInfo)
    /// Device Flow 已成功，但当前 App 尚无可访问安装；凭据保留以支持安装后直接复查。
    case installationRequired
    /// 已有 Device Flow 凭据，但安装状态暂时无法验证；与首次授权失败分开呈现。
    case installationCheckFailed(ProjectAccessFailureCode)
    case connected(expiresAt: Date?)
    case partialAuthorization
    case organizationApprovalPending
    case expired
    case revoked
    case failed(ProjectAccessFailureCode)
}

enum ProjectAccessSessionError: Error, Equatable {
    case unavailable
    case missingCredential
    case expired
    case storage
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
    private let isConfigured: Bool
    private let appSlug: String
    private let installationCheck: InstallationCheck
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        oauthService: any ProjectAccessOAuthServiceProtocol = ProjectAccessOAuthService(),
        keychain: any KeychainManaging = KeychainManager.shared,
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
        self.isConfigured = isConfigured
        self.appSlug = appSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        self.installationCheck = installationCheck
        self.now = now
        state = isConfigured ? .disconnected : .unavailable
    }

    func restore() {
        guard isConfigured else {
            state = .unavailable
            return
        }
        do {
            guard let credential = try loadCredential() else {
                state = .disconnected
                return
            }
            if isRefreshExpired(credential) {
                state = .expired
            } else {
                state = .connected(expiresAt: credential.accessExpiresAt)
            }
        } catch {
            state = .failed(.storage)
        }
    }

    @discardableResult
    func beginConnection() async throws -> OAuthDeviceCodeInfo {
        guard isConfigured else {
            state = .unavailable
            throw ProjectAccessSessionError.unavailable
        }
        state = .connecting
        do {
            let info = try await oauthService.beginDeviceFlow()
            state = .awaitingAuthorization(info)
            return info
        } catch {
            state = .failed(Self.failureCode(error))
            throw error
        }
    }

    func completeConnection() async throws {
        guard isConfigured else {
            state = .unavailable
            throw ProjectAccessSessionError.unavailable
        }
        let credential: ProjectAccessCredential
        do {
            credential = try await oauthService.awaitCredential()
            try saveCredential(credential)
        } catch {
            state = .failed(Self.failureCode(error))
            throw error
        }
        do {
            try await updateInstallationState(using: credential)
        } catch {
            // 凭据已经安全保存，安装校验失败不应让用户重复 Device Flow。
            state = .installationCheckFailed(Self.failureCode(error))
            throw error
        }
    }

    /// 安装 GitHub App 或组织批准后重新检查，无需重复 Device Flow。
    ///
    /// Device Flow 凭据会在 `.installationRequired` 状态保留，因此用户完成安装后可以直接
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
        } catch {
            state = .installationCheckFailed(Self.failureCode(error))
            throw error
        }
    }

    func cancelConnection() async {
        await oauthService.reset()
        state = isConfigured ? .disconnected : .unavailable
    }

    func disconnect() throws {
        try keychain.deleteProjectAccessCredential()
        state = isConfigured ? .disconnected : .unavailable
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

    /// 校验安装并发布状态。没有安装是可恢复状态，不删除已经取得的 Device Flow 凭据；
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
             .partialAuthorization, .organizationApprovalPending:
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
        case .flowNotStarted, .codeExpired, .badRefreshToken, .invalidResponse: .invalidResponse
        case .httpStatus: .network
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
        // Device Flow 成功但 App 尚未安装时，user token 不具备项目访问范围；继续用它会把
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
