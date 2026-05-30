//
//  AuthSession.swift
//  Starcat
//
//  全局登录态门面。
//
//  职责：
//  - 启动时从 Keychain 读 token，决定 unauthenticated / authenticated 初始态
//  - 触发 Device Flow（两阶段：拿 user_code → 等用户授权）
//  - 登录成功后落库 token + 拉一次 /user 信息
//  - 登出：清 Keychain + 重置状态
//
//  @MainActor 保证状态变更只在主线程，SwiftUI 观察安全。
//

import Foundation
import Observation

/// 登录态。
enum AuthState: Equatable {
    /// 未登录。
    case unauthenticated
    /// Device Flow 已发起，等待用户在浏览器输 code。
    case awaitingUserCode(OAuthDeviceCodeInfo)
    /// 已登录。
    case authenticated(user: GitHubUserDTO)

    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
}

/// 登录态视图模型，全局唯一。
@MainActor
@Observable
final class AuthSession {

    // MARK: - 状态

    /// 当前登录状态。
    var state: AuthState = .unauthenticated

    /// 最近一次错误（用户取消、网络失败等），UI 用于展示。
    var lastError: (any LocalizedError)?

    /// 是否处于登录进行中（用于禁用按钮、显示 Spinner）。
    var isAuthenticating: Bool = false

    // MARK: - 依赖

    private let oauthService: any GithubOAuthServiceProtocol
    /// D-02：依赖协议而非具体 actor，便于单测注入 Mock。
    private let apiClient: any GitHubAPIClientProtocol
    private let keychain: any KeychainManaging

    /// 当前进行中的 Device Flow 轮询 Task，便于取消。
    private var pollingTask: Task<Void, Never>?

    // MARK: - 初始化

    /// - Parameters:
    ///   - oauthService: Device Flow 实现（Real 或 Mock）。
    ///   - apiClient: 用于登录后立刻拉 /user 验证 token。
    ///   - keychain: token 存储。
    init(
        oauthService: any GithubOAuthServiceProtocol,
        apiClient: any GitHubAPIClientProtocol,
        keychain: any KeychainManaging = KeychainManager.shared
    ) {
        self.oauthService = oauthService
        self.apiClient = apiClient
        self.keychain = keychain
    }

    // MARK: - 启动时恢复登录

    /// 启动期调用。Keychain 有 token 时尝试拉 /user 验证。
    /// 验证失败（401）则视为未登录，清除 token。
    ///
    /// 诊断"每次启动都要重新登录"问题：
    /// 查看 Console.app subsystem `com.starcat.app` 过滤 category `auth`：
    /// - "restore: keychain miss" → token 没存进/没读出（多半 entitlements 问题）
    /// - "restore: token invalid (401)" → token 被 GitHub 撤销
    /// - "restore: network error" → 拉 /user 网络失败，token 仍保留
    /// - "restore: success" → 正常恢复
    func restoreSessionIfAvailable() async {
        let tokenOpt: String?
        do {
            tokenOpt = try keychain.loadGithubToken()
        } catch {
            AppLog.auth.error("restore: keychain read error: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let token = tokenOpt, !token.isEmpty else {
            AppLog.auth.info("restore: keychain miss (no token); starting unauthenticated")
            return
        }

        AppLog.auth.info("restore: keychain hit (token length=\(token.count, privacy: .public)); verifying via /user...")

        do {
            let user = try await apiClient.getCurrentUser()
            self.state = .authenticated(user: user)
            AppLog.auth.info("restore: success login=\(user.login, privacy: .public)")
        } catch NetworkError.unauthorized {
            AppLog.auth.warning("restore: token invalid (401); clearing")
            try? keychain.deleteGithubToken()
            self.state = .unauthenticated
        } catch {
            AppLog.auth.error("restore: network error (token retained): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 登录

    /// 触发 Device Flow 登录。
    /// 一次只允许一个登录流程进行中。
    func signIn() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        lastError = nil

        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.runDeviceFlow()
        }
    }

    /// 取消进行中的登录。
    func cancelSignIn() {
        pollingTask?.cancel()
        pollingTask = nil
        isAuthenticating = false
        state = .unauthenticated
        Task { await oauthService.reset() }
    }

    private func runDeviceFlow() async {
        defer {
            self.isAuthenticating = false
            self.pollingTask = nil
        }

        do {
            // 阶段 1：拿 user_code
            let info = try await oauthService.beginDeviceFlow()
            self.state = .awaitingUserCode(info)

            // 阶段 2：轮询 token
            let token = try await oauthService.awaitAccessToken()
            try keychain.storeGithubToken(token)
            AppLog.auth.info("Token stored to Keychain")

            // 阶段 3：拉 /user 验证 + 取信息
            let user = try await apiClient.getCurrentUser()
            self.state = .authenticated(user: user)
            AppLog.auth.info("Sign-in complete: login=\(user.login, privacy: .public)")
        } catch is CancellationError {
            AppLog.auth.info("Sign-in cancelled by user")
            self.state = .unauthenticated
        } catch NetworkError.cancelled {
            AppLog.auth.info("Sign-in cancelled")
            self.state = .unauthenticated
        } catch let error as LocalizedError {
            AppLog.auth.error("Sign-in failed: \(error.localizedDescription, privacy: .public)")
            self.lastError = error
            self.state = .unauthenticated
        } catch {
            AppLog.auth.error("Sign-in failed (unknown): \(error.localizedDescription, privacy: .public)")
            self.state = .unauthenticated
        }
    }

    // MARK: - 登出

    func signOut() {
        do {
            try keychain.deleteGithubToken()
        } catch {
            AppLog.auth.error("Logout: failed to delete token: \(error.localizedDescription, privacy: .public)")
        }
        state = .unauthenticated
        lastError = nil
        AppLog.auth.info("Signed out")
    }
}
