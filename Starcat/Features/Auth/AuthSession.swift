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

    /// 已登录态下的 user；未登录返回 nil。
    /// 2026-06-06 加入：UserProfileService 整合后，reset / accept 路径
    /// 需要从当前 state 拿 login，避免重复用 `case let ...` 解构。
    var user: GitHubUserDTO? {
        if case .authenticated(let user) = self { return user }
        return nil
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

    /// 2026-06-06 UserProfileService（A 方案）：可选注入，便于：
    /// ① 启动期从磁盘缓存 prime 出 user → state 秒显（消除 sidebar 200-800ms 空白）；
    /// ② OAuth 登录成功 / restore 成功后把 user 顺手 push 给 service 持久化；
    /// ③ signOut / invalidate 时清 service。
    ///
    /// 用 var + 外部注入而非构造器参数：装配时 AppDependencies 先建 AuthSession，
    /// 再建 UserProfileService（持有 AuthSession weak 反向引用），最后回填 `session.userProfileService = svc`。
    /// 这样避免两者构造器循环依赖。
    var userProfileService: UserProfileService?

    /// R-01（2026-06-09）：登出 / 会话失效时的回调。
    ///
    /// 注入方：`AppDependencies` 用此 hook 让 `StarredRegistryBootstrapper.clearOnSignOut()`
    /// 在 token 被清除的瞬间把 registry 也清空，避免下个用户登录后看到上个用户的
    /// star 状态（registry 与 token 必须同步）。
    ///
    /// 调用时机：① `signOut()` 主动登出末尾；② `invalidateSession()` 401 被动失效末尾。
    /// 仅在状态成功切到 `.unauthenticated` 之后调用。
    var onSignOut: (@MainActor () -> Void)?

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
        // 测试期跳过：ad-hoc 签名下 keychain.loadGithubToken() 会触发 ACL 授权弹窗，
        // 测试 host 无窗口接收 → 主线程 hang → testmanagerd 超时。
        // 详见 docs/工程进度/2026-05-30-Keychain-临时绕过方案.md
        if TestEnvironment.isRunning {
            AppLog.auth.info("restore: test host detected, skip session restore")
            return
        }

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

        // ① UserProfileService prime：磁盘上有 cached profile 时立刻 emit state，
        //    让 sidebar / detail 0 ms 就能渲染出内容，避免启动期 200-800ms 空白窗。
        //    随后 ② 路径异步拉 /user 校验 token + 刷新数据，期间 sidebar 已经渲染好了。
        if let cached = userProfileService?.primeFromCache() {
            self.state = .authenticated(user: cached)
            AppLog.auth.info("restore: primed from cache login=\(cached.login, privacy: .public); verifying via /user...")
        }

        do {
            let user = try await apiClient.getCurrentUser()
            self.state = .authenticated(user: user)
            // ② 用真实数据覆盖 prime 出来的快照，并让 service 写盘
            userProfileService?.acceptFromAuth(user)
            AppLog.auth.info("restore: success login=\(user.login, privacy: .public)")
        } catch NetworkError.unauthorized {
            AppLog.auth.warning("restore: token invalid (401); clearing")
            try? keychain.deleteGithubToken()
            // 401 时清掉 cached profile，避免下次启动 prime 出错误账号的数据
            userProfileService?.reset(login: state.user?.login)
            self.state = .unauthenticated
        } catch {
            // 网络错误：token 保留 + cached state 也保留（避免离线时把刚 prime 的快照擦掉）
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
            AppLog.auth.info("Token stored to local file")

            // 阶段 3：拉 /user 验证 + 取信息
            let user = try await apiClient.getCurrentUser()
            self.state = .authenticated(user: user)
            // 让 UserProfileService 持久化这次 user，下次启动可以秒显
            userProfileService?.acceptFromAuth(user)
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
        let currentLogin = state.user?.login
        do {
            try keychain.deleteGithubToken()
        } catch {
            AppLog.auth.error("Logout: failed to delete token: \(error.localizedDescription, privacy: .public)")
        }
        // 清掉 cached profile（含磁盘 + lastLogin），下次启动是干净的未登录态
        userProfileService?.reset(login: currentLogin)
        state = .unauthenticated
        lastError = nil
        // R-01：清空 StarredRegistry，避免下个用户登录看到上个用户的 star 状态
        onSignOut?()
        AppLog.auth.info("Signed out")
    }

    // MARK: - 会话被动失效（集中式 401 处理入口）

    /// token 在使用中失效（被 GitHub 吊销 / 改密码 / 权限变更）时调用。
    ///
    /// 与 `signOut()` 的区别：
    /// - `signOut()` 是用户主动登出，不留错误提示；
    /// - 本方法是**被动失效**，会保留一条 `lastError`（"未授权，请重新登录"）给登录页展示。
    ///
    /// 调用来源：`GitHubAPIClient` 的集中式 401 回调（见 `AppDependencies` 接线）。
    /// 所有端点的 401 都汇聚到这里，避免每个调用点各写一套"清 token + 回登录"逻辑。
    ///
    /// 关键约束（防误伤 + 幂等）：
    /// - 仅当当前为"已登录"态才处理。登录流程中（`.unauthenticated` / `.awaitingUserCode`）
    ///   出现的 401 由各自流程处理，这里跳过，避免把进行中的 Device Flow 误判为失效。
    /// - 并发的多个 401 会重复调用本方法，首个把状态切走后，后续因 guard 直接 no-op。
    /// - `@MainActor`：状态变更只在主线程，由回调侧负责 hop 到主线程。
    func invalidateSession() {
        guard state.isAuthenticated else { return }
        AppLog.auth.warning("Session invalidated (401/unauthorized in use); clearing token")
        let currentLogin = state.user?.login
        do {
            try keychain.deleteGithubToken()
        } catch {
            AppLog.auth.error("invalidateSession: failed to delete token: \(error.localizedDescription, privacy: .public)")
        }
        userProfileService?.reset(login: currentLogin)
        state = .unauthenticated
        // 复用 network.error.unauthorized 文案（"未授权，请重新登录。"）在登录页提示用户。
        lastError = NetworkError.unauthorized
        // R-01：清空 StarredRegistry（与 token 同步失效）
        onSignOut?()
    }

    // MARK: - 接收 service 推送的最新 user（反向 push）

    /// `UserProfileService` 在后台拉到新 user（TTL 到期 / 用户手动刷新）后调用本方法，
    /// 把新数据写回 `state.user`，让所有观察 `authSession.state` 的视图自然重渲染。
    ///
    /// 与 `signIn` / `restoreSessionIfAvailable` 的区别：
    /// - 那两条路径是"从未登录 → 已登录"的状态迁移，可能伴随 token 落 Keychain；
    /// - 本方法是"已登录态内的 profile 字段刷新"，**仅替换 user，不动 token / lastError**。
    ///
    /// 关键约束（防误伤）：
    /// - 仅在当前是 `.authenticated` 且 **user.id 匹配**时替换。否则视为：
    ///   ① 已登出（state == .unauthenticated）—— 拉到的过期结果直接丢；
    ///   ② 切账号（user.id 不同）—— 也丢，避免把旧账号数据覆盖新账号视图。
    /// - 用 `Equatable` 判等：字段无变化时不重新 emit `state`，避免无意义 SwiftUI diff。
    func acceptRefreshedUser(_ user: GitHubUserDTO) {
        guard case .authenticated(let cur) = state else {
            AppLog.auth.debug("acceptRefreshedUser: not authenticated; ignore")
            return
        }
        guard cur.id == user.id else {
            AppLog.auth.info("acceptRefreshedUser: id mismatch (cur=\(cur.id, privacy: .public), got=\(user.id, privacy: .public)); ignore")
            return
        }
        if cur != user {
            state = .authenticated(user: user)
            AppLog.auth.debug("acceptRefreshedUser: state updated for login=\(user.login, privacy: .public)")
        }
    }
}
