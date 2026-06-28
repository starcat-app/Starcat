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
    /// 用 var + 外部注入而非构造器参数:装配时 AppDependencies 先建 AuthSession,
    /// 再建 UserProfileService(持有 AuthSession weak 反向引用),最后回填 `session.userProfileService = svc`。
    /// 这样避免两者构造器循环依赖。
    var userProfileService: UserProfileService?

    /// 2026-06-15 ContributionService 联动清理:与 `userProfileService` 对称的"登出清缓存"hook。
    ///
    /// **修复的 bug**(dong4j 2026-06-15 报):用户 A 登出 → B 登录后,sidebar 草坪仍显示 A 的数据,
    /// 必须手动点账号菜单"刷新个人信息"才会更新。
    ///
    /// **根因**:之前 `signOut` / `invalidateSession` 只调 `userProfileService.reset`,漏了
    /// `contributionService`。导致 service 内存里 `payload` + `lastFetchedAt` 仍是 A 的;
    /// B 登录后 sidebar `.task(id: user.login)` 触发 `contributionService.load(login: B)`,
    /// 因 `lastFetchedAt` 还在 3h TTL 窗口内,`load` 直接 no-op 返回,**根本不发请求**。
    ///
    /// **修复**:本字段与 `userProfileService` 对称注入,在登出 / 401 时调 `reset(login:)`
    /// 把内存 + 磁盘缓存清掉。B 登录后 sidebar `.task` 再调 `load` 时,`lastFetchedAt == nil`,
    /// 自然走网络拉新数据,不需要额外的 force 刷新。
    ///
    /// 持有语义同 `userProfileService`:`var` 而非构造器参数避免双向构造依赖;`AppDependencies`
    /// 装配末尾回填 `session.contributionService = contributionService`。
    var contributionService: ContributionService?

    /// 分享卡开发语言服务联动：登录 / 恢复成功后后台预热，登出 / 401 时清缓存。
    ///
    /// 这份数据统计“用户自己拥有的公开仓库语言”，不同于 HomeViewModel 的 starred 语言分布。
    /// 挂在 AuthSession 上的原因与 ContributionService 相同：账号切换时必须同步 reset，
    /// 否则 B 登录后分享卡可能短暂显示 A 的语言画像。
    var developerLanguageService: DeveloperLanguageService?

    /// R-01（2026-06-09）：登出 / 会话失效时的回调。
    ///
    /// 注入方：`AppDependencies` 用此 hook 让 `StarredRegistryBootstrapper.clearOnSignOut()`
    /// 在 token 被清除的瞬间把 registry 也清空，避免下个用户登录后看到上个用户的
    /// star 状态（registry 与 token 必须同步）。
    ///
    /// 调用时机：① `signOut()` 主动登出末尾;② `invalidateSession()` 401 被动失效末尾。
    /// 仅在状态成功切到 `.unauthenticated` 之后调用。
    var onSignOut: (@MainActor () -> Void)?

    /// 2026-06-12 多账号 DB 隔离：登录态变化时通知 `AppDependencies` 切换 SQLite 数据库。
    ///
    /// **触发时机**（参数语义：非 nil = 切到该 user 的 DB，nil = 切到 `_anonymous`）：
    /// - `runDeviceFlow` 拿到 user 后、emit `.authenticated` 之前 → 传 `user.id`
    /// - `restoreSessionIfAvailable` `/user` 验证成功后、emit `.authenticated` 之前 → 传 `user.id`
    /// - `signOut` 末尾、调 `onSignOut?()` 之前 → 传 `nil`
    /// - `invalidateSession` 末尾、调 `onSignOut?()` 之前 → 传 `nil`
    ///
    /// **时序约束（关键！）**：必须 `await` 完成 DB 切换后再 emit state。
    /// 否则 HomeView `.task` 观察到 `.authenticated` 后立刻启动 SyncManager 拉 stars，
    /// Repository.database.writer 还指向上一个用户的 pool，会把新账号数据写到旧 DB。
    ///
    /// **场景**：dong4j 拍板"先退出再登录"，不存在登录态硬切，
    /// 因此 DB reopen 时所有后台任务都该已停（由 onSignOut 链路保证）。
    var onUserSessionChanged: (@MainActor (Int64?) async -> Void)?

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
        // 详见 docs/4-工程进度/踩坑与故障记录/2026-05-30-Keychain-临时绕过方案.md
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
            // 多账号 DB 隔离：先把 SQLite 切到该 user 的目录，再 emit state。
            // 注入方 AppDependencies 拿到 user.id 调 database.reopen，
            // 让后续 SyncManager 等所有 Repository query 都打到正确的 DB 文件。
            await onUserSessionChanged?(user.id)
            self.state = .authenticated(user: user)
            // ② 用真实数据覆盖 prime 出来的快照，并让 service 写盘
            userProfileService?.acceptFromAuth(user)
            contributionService?.load(login: user.login)
            developerLanguageService?.load(login: user.login)
            AppLog.auth.info("restore: success login=\(user.login, privacy: .public)")
        } catch NetworkError.unauthorized {
            AppLog.auth.warning("restore: token invalid (401); clearing")
            try? keychain.deleteGithubToken()
            // 401 时清掉 cached profile，避免下次启动 prime 出错误账号的数据
            let staleLogin = state.user?.login
            userProfileService?.reset(login: staleLogin)
            // 2026-06-15 修复:与 userProfileService 对称清掉草坪缓存。
            // 启动期 401 极少能命中(此时 ContributionService 多半还没 load 过、payload/lastFetchedAt 都是 nil),
            // 但保持与 signOut / invalidateSession 三处对称,任何"token 失效"路径都同款清理,语义更可靠。
            contributionService?.reset(login: staleLogin)
            developerLanguageService?.reset(login: staleLogin)
            // 多账号 DB 隔离：token 失效 = 进入未登录态，DB 切到 _anonymous
            await onUserSessionChanged?(nil)
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
            // 多账号 DB 隔离：先把 SQLite 切到该 user 的目录，再 emit state。
            // 必须在 emit .authenticated 之前完成，否则 HomeView 观察到状态变化
            // 启动的 SyncManager 会把新账号 stars 写到老 DB。
            await onUserSessionChanged?(user.id)
            self.state = .authenticated(user: user)
            // 让 UserProfileService 持久化这次 user，下次启动可以秒显
            userProfileService?.acceptFromAuth(user)
            contributionService?.load(login: user.login)
            developerLanguageService?.load(login: user.login)
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

    /// 主动登出。
    ///
    /// **2026-06-12 起改为 async**：内部要 `await onUserSessionChanged?(nil)`
    /// 让 SQLite 在本调用返回前切到 `_anonymous` 占位库。否则会出现
    /// "signOut 同步返回 → 用户立即点登录 B → reopen(nil) 与 reopen(B.id) 并发，
    /// 后排队的 reopen(nil) 把刚切到 B 的 DB 又切回 anonymous" 的时序 bug。
    /// 调用方（SidebarHeaderView）需在 Button action 内 `Task { await ... }` 包一下。
    func signOut() async {
        let currentLogin = state.user?.login
        do {
            try keychain.deleteGithubToken()
        } catch {
            AppLog.auth.error("Logout: failed to delete token: \(error.localizedDescription, privacy: .public)")
        }
        // 清掉 cached profile（含磁盘 + lastLogin），下次启动是干净的未登录态
        userProfileService?.reset(login: currentLogin)
        // 2026-06-15 修复:与 userProfileService 对称清掉草坪 service 的内存 + 磁盘缓存。
        // 否则切到 B 账号后 sidebar `.task` 触发 `load(login: B)` 会因 lastFetchedAt 还在 A
        // 那次成功的 3h TTL 窗口内被直接 no-op,草坪一直挂着 A 的数据(详见 contributionService 字段注释)。
        contributionService?.reset(login: currentLogin)
        developerLanguageService?.reset(login: currentLogin)
        state = .unauthenticated
        lastError = nil
        // R-01：清空 StarredRegistry，避免下个用户登录看到上个用户的 star 状态
        onSignOut?()
        // 多账号 DB 隔离：DB 切到 _anonymous 占位库（同步 await，保证返回前 DB 已切换）
        await onUserSessionChanged?(nil)
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
    /// **2026-06-12 起改为 async**：与 `signOut()` 同源，需 await `onUserSessionChanged?(nil)`
    /// 同步完成 DB 切换。调用方（GitHubAPIClient 的 unauthorizedHandler）已在 Task 里，
    /// 加 await 即可。
    func invalidateSession() async {
        guard state.isAuthenticated else { return }
        AppLog.auth.warning("Session invalidated (401/unauthorized in use); clearing token")
        let currentLogin = state.user?.login
        do {
            try keychain.deleteGithubToken()
        } catch {
            AppLog.auth.error("invalidateSession: failed to delete token: \(error.localizedDescription, privacy: .public)")
        }
        userProfileService?.reset(login: currentLogin)
        // 2026-06-15 修复:与 signOut 路径同步清草坪 service,避免 B 登录后 sidebar 显示 A 的草坪。
        contributionService?.reset(login: currentLogin)
        developerLanguageService?.reset(login: currentLogin)
        state = .unauthenticated
        // 复用 network.error.unauthorized 文案（"未授权，请重新登录。"）在登录页提示用户。
        lastError = NetworkError.unauthorized
        // R-01：清空 StarredRegistry（与 token 同步失效）
        onSignOut?()
        // 多账号 DB 隔离：401 被动失效时也切到 _anonymous，与主动 signOut 同语义
        await onUserSessionChanged?(nil)
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
