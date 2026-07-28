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
    private(set) var state: ProjectAccessState

    private let oauthService: any ProjectAccessOAuthServiceProtocol
    private let keychain: any KeychainManaging
    private let isConfigured: Bool
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        oauthService: any ProjectAccessOAuthServiceProtocol = ProjectAccessOAuthService(),
        keychain: any KeychainManaging = KeychainManager.shared,
        isConfigured: Bool = !AppConstants.githubAppClientID.isEmpty,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.oauthService = oauthService
        self.keychain = keychain
        self.isConfigured = isConfigured
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
        do {
            let credential = try await oauthService.awaitCredential()
            try saveCredential(credential)
            state = .connected(expiresAt: credential.accessExpiresAt)
        } catch {
            state = .failed(Self.failureCode(error))
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
                state = .connected(expiresAt: refreshed.accessExpiresAt)
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
        state = .connected(expiresAt: credential.accessExpiresAt)
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
        if let projectToken = try? await projectAccessSession.validAccessToken() {
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
