//
//  UserProfileService.swift
//  Starcat
//
//  当前登录用户 profile（GitHubUserDTO）的离线缓存 + 后台刷新协调器。
//  2026-06-06 引入（A 方案：仿 ContributionService 的范式）。
//
//  设计动机（来自 dong4j 2026-06-06 讨论）：
//  - 当前 `AuthSession.state.user` 只活在内存——App 重启才会刷新；
//    用户改了 GitHub bio / 关注 / 头像后必须重启才能看到。
//  - 启动期 sidebar 会有 200-800ms 空白（等 `/user` 网络回来才填）。
//  - ShareCardSheet / HTML 导出读到的是"启动那一刻的快照"，可能陈旧。
//
//  本 service 同时解决以上 3 个问题：
//  - **磁盘缓存**：把 DTO 落 UserDefaults，下次启动秒显（消除 sidebar 空白）。
//  - **TTL 后台刷新**：30 min 自动刷一次（profile 变化合理感知延迟）。
//  - **手动 force refresh**：ShareCardSheet 打开 / sidebar `…` 菜单"刷新个人信息" 触发。
//  - **反向 push 给 AuthSession**：拿到新数据后调 `AuthSession.acceptRefreshedUser(_:)`，
//    让 sidebar / 详情页 / AI 窗口等 11 个观察 `authSession.state` 的地方自动更新——
//    零改动现有解构代码（dong4j 选 D2-A 决策）。
//
//  数据流：
//
//      启动期
//      ┌────────────────────────────────────────────────┐
//      │ StarcatApp.bootstrap()                          │
//      │   → AuthSession.restoreSessionIfAvailable()     │
//      │      ① 读 Keychain                              │
//      │      ② primeAuthFromCache → state 秒显（0 ms）   │
//      │      ③ 异步拉 /user → state 自然更新（覆盖②）   │
//      │      ④ accept(fetched) → service 写盘            │
//      └────────────────────────────────────────────────┘
//
//      运行期（用户在 sidebar）
//      Sidebar.task(id: user.login) →
//          userProfileService.load(login, force: false)
//          （TTL 命中 no-op；超时后台刷 → acceptRefreshedUser → state emit）
//
//      运行期（用户打开 ShareCardSheet）
//      ShareCardSheet.onAppear →
//          userProfileService.load(login, force: true)
//          （静默刷新，sheet 用 state.user 自然拿到最新）
//
//      登出 / 401
//      AuthSession.signOut / invalidateSession →
//          userProfileService.reset(login:)
//          （清内存 + 磁盘）
//
//  与 ContributionService 的对比：
//  - 模型：DTO 直接 Codable 落盘（D1-A 决策），与 ContributionCalendarPayload 同款。
//  - 信任源：DTO 持有方仍是 AuthSession；service 不直接被 sidebar 观察，靠回写 AuthSession 触发 UI 更新（D2-A 决策）。
//  - TTL：30 min（D4-B 决策；ContributionService 是 3 h，profile 比草坪敏感）。
//  - API 依赖：用 protocol `GitHubAPIClientProtocol` 注入（ContributionService 用具体 actor，因为 graphql<T> 是泛型）。
//
//  关键约束：
//  - `@MainActor`：所有状态变更必须主线程（@Observable + SwiftUI 观察规则）。
//  - 同 login 同时只允许一个 inflight 请求（`inflightTask` 互斥）。
//  - `acceptFromAuth(_:)` 是给 AuthSession 走启动期"已经拉到 user 了，顺便存一份"的快捷入口，
//    不发起网络，仅持久化 + 更新 lastFetchedAt。
//

import Foundation
import Observation

/// 当前用户 profile 缓存服务。
///
/// 单例语义（AppDependencies 持有一份），跨账号通过 `reset(login:)` + `load(newLogin)` 切换。
@MainActor
@Observable
final class UserProfileService {

    // MARK: - 状态（@Observable）

    /// 当前缓存的 profile；nil = 从未加载过 / 已 reset。
    /// 失败时不清空，保留旧数据避免 UI 抖动。
    private(set) var profile: GitHubUserDTO?

    /// 是否在后台拉取中（仅在无缓存时为 true，避免 UI 闪烁）。
    private(set) var isLoading: Bool = false

    /// 最近一次错误（一般沉默处理，UI 不必显示）。
    private(set) var lastError: (any LocalizedError)?

    /// 上次成功加载时间戳；用于 TTL 判断。
    private(set) var lastFetchedAt: Date?

    // MARK: - 依赖

    /// REST 调用入口；通过 protocol 注入便于 Mock。
    /// 与 ContributionService 不同：profile 是 REST 端点（`/user`），protocol 已暴露 `getCurrentUser()`。
    private let apiClient: any GitHubAPIClientProtocol

    /// 缓存 key 前缀；按 login 分桶（同一台机器可能切换账号）。
    private let cacheKeyPrefix = "userprofile.snapshot."

    /// TTL：30 min。profile 比草坪敏感（followers 秒变 / bio 用户改了想立刻看到），
    /// 但又不能太短（sidebar 长开会频繁刷）。
    /// dong4j 2026-06-06 选 D4-B。
    private let ttl: TimeInterval = 30 * 60

    /// inflight 任务；同 login 重复 load 直接复用，不重复请求。
    private var inflightTask: Task<Void, Never>?

    /// 反向回写 AuthSession 的引用；可能为 nil（测试场景 / 装配顺序未完成）。
    /// 用 weak 避免 AppDependencies → AuthSession 与 AuthSession → UserProfileService 双向强引用。
    /// 但 AuthSession 在 AppDependencies 是强持有的，service 持弱引用更安全。
    weak var authSession: AuthSession?

    // MARK: - lastLogin（启动期 prime 时需要的 key）

    /// 上次成功登录的 login 名；OAuth 成功 / accept 时写，登出 / 401 时清。
    /// 启动期 prime 时拿这个去找磁盘缓存。
    /// D3-A 决策：单独一个 UserDefaults key，不污染 Keychain。
    ///
    /// `nonisolated`：本类整体 `@MainActor`，但 `loadLastLogin / saveLastLogin /
    /// clearLastLogin` 三个静态方法标了 `nonisolated`（只调线程安全的 UserDefaults），
    /// 它们引用本常量时若 key 仍是 main-actor isolated 会触发 Swift 6 报错
    /// "main actor-isolated static property cannot be referenced from a nonisolated
    /// context"。常量本身不可变、读取无副作用，标 `nonisolated` 是最干净的对齐方式。
    nonisolated static let lastLoginKey = "auth.lastLogin"

    /// 读取上次登录的 login（启动期 prime 入口）。
    nonisolated static func loadLastLogin() -> String? {
        let s = UserDefaults.standard.string(forKey: lastLoginKey)
        return (s?.isEmpty ?? true) ? nil : s
    }

    /// 写入 lastLogin。OAuth 成功后调用。
    nonisolated static func saveLastLogin(_ login: String) {
        UserDefaults.standard.set(login, forKey: lastLoginKey)
    }

    /// 清掉 lastLogin。登出 / 401 时调用。
    nonisolated static func clearLastLogin() {
        UserDefaults.standard.removeObject(forKey: lastLoginKey)
    }

    // MARK: - 初始化

    init(apiClient: any GitHubAPIClientProtocol) {
        self.apiClient = apiClient
    }

    // MARK: - 启动期 prime（不发请求，仅读磁盘）

    /// 启动期由 AuthSession 调用：尝试从磁盘读 cached profile（如果 lastLogin 有的话）。
    /// 拿到即返回 → AuthSession 可以立刻 `state = .authenticated(user: cached)`，sidebar 秒显。
    ///
    /// 返回 nil 的情况：
    /// - 没有 lastLogin（首次安装 / 已登出）
    /// - 磁盘缓存损坏 / schema 不兼容
    ///
    /// 此方法不发起网络请求；网络刷新由 AuthSession 后续的 `apiClient.getCurrentUser()` 路径走。
    func primeFromCache() -> GitHubUserDTO? {
        guard let login = Self.loadLastLogin() else { return nil }
        guard restoreFromDisk(login: login) else { return nil }
        return profile
    }

    // MARK: - 公开 API（手动刷新 + 自动 TTL 刷新）

    /// 加载指定 login 的 profile。
    ///
    /// - Parameters:
    ///   - login: 目标用户 login（一般是当前登录用户）
    ///   - force: true = 跳过 TTL 强制刷；false = TTL 命中直接返回
    ///
    /// 行为：
    /// 1. 内存空 → 先尝试 restoreFromDisk
    /// 2. !force && TTL 命中 → no-op
    /// 3. inflight → no-op（同 login 不重复发）
    /// 4. 仅在无缓存时 isLoading = true（避免后台刷新闪烁）
    /// 5. 成功：内存 + 磁盘双写 + lastLogin 写入 + 反向 push 给 AuthSession
    /// 6. 失败：保留旧数据 + 设 lastError（沉默处理，UI 不必显式提示）
    func load(login: String, force: Bool = false) {
        // 首次：先把磁盘里有的捞出来兜底（与 ContributionService 同范式）
        if profile == nil {
            _ = restoreFromDisk(login: login)
        }

        // TTL 命中且非强制 → 不发网络
        if !force, let last = lastFetchedAt, Date().timeIntervalSince(last) < ttl {
            return
        }

        // 已有 inflight → 复用
        if inflightTask != nil { return }

        // 无缓存时才显示 loading；有缓存的后台刷新不闪烁
        if profile == nil {
            isLoading = true
        }

        inflightTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoading = false
                self.inflightTask = nil
            }

            do {
                let fetched = try await self.apiClient.getCurrentUser()
                // 防御：网络回来时用户切账号 / 登出了——丢弃过期结果
                guard !Task.isCancelled else { return }
                guard fetched.login.lowercased() == login.lowercased() else {
                    AppLog.network.info("UserProfile fetch: login mismatch (request=\(login, privacy: .public), got=\(fetched.login, privacy: .public)); drop")
                    return
                }

                self.profile = fetched
                self.lastFetchedAt = Date()
                self.lastError = nil
                self.persistToDisk(login: fetched.login, profile: fetched, fetchedAt: Date())
                Self.saveLastLogin(fetched.login)

                // 反向 push 给 AuthSession（D2-A 决策）：让 sidebar 等观察方自然更新
                self.authSession?.acceptRefreshedUser(fetched)

                AppLog.network.info("UserProfile fetched: login=\(fetched.login, privacy: .public), followers=\(fetched.followers ?? 0, privacy: .public)")
            } catch is CancellationError {
                AppLog.network.info("UserProfile fetch cancelled: login=\(login, privacy: .public)")
            } catch let err as LocalizedError {
                self.lastError = err
                AppLog.network.error("UserProfile fetch failed: \(err.localizedDescription, privacy: .public)")
            } catch {
                AppLog.network.error("UserProfile fetch failed (unknown): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// AuthSession 在已经成功拉到 user（启动 restore / OAuth 登录）时调用：
    /// 把 DTO 收下来持久化，不再额外发请求。
    ///
    /// 这是 service 与 AuthSession 之间的"省一次网络"快捷入口——
    /// 如果没有它，启动期 AuthSession 拉了一次，TTL 到期后 service 又会拉一次，浪费。
    ///
    /// 调用方契约：仅当 AuthSession.state 真的更新为 .authenticated 时调用。
    func acceptFromAuth(_ user: GitHubUserDTO) {
        self.profile = user
        self.lastFetchedAt = Date()
        self.lastError = nil
        self.persistToDisk(login: user.login, profile: user, fetchedAt: Date())
        Self.saveLastLogin(user.login)
        AppLog.network.debug("UserProfile acceptFromAuth: login=\(user.login, privacy: .public)")
    }

    /// 登出 / 401 时调用：清内存 + 磁盘 + lastLogin。
    func reset(login: String?) {
        inflightTask?.cancel()
        inflightTask = nil
        profile = nil
        isLoading = false
        lastError = nil
        lastFetchedAt = nil
        if let login {
            UserDefaults.standard.removeObject(forKey: cacheKey(for: login))
        }
        Self.clearLastLogin()
    }

    // MARK: - 磁盘缓存

    private func cacheKey(for login: String) -> String {
        cacheKeyPrefix + login.lowercased()
    }

    /// 磁盘落盘信封：`{ "fetchedAt": <epoch>, "profile": <jsonEncoded GitHubUserDTO> }`。
    /// 用 JSONEncoder 而非 PropertyListEncoder，文本调试可读（与 ContributionService 一致）。
    private struct DiskEnvelope: Codable {
        let fetchedAt: TimeInterval
        let profile: GitHubUserDTO
    }

    private func persistToDisk(login: String, profile: GitHubUserDTO, fetchedAt: Date) {
        let envelope = DiskEnvelope(fetchedAt: fetchedAt.timeIntervalSince1970, profile: profile)
        do {
            let data = try JSONEncoder().encode(envelope)
            UserDefaults.standard.set(data, forKey: cacheKey(for: login))
        } catch {
            AppLog.network.warning("UserProfile persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 从磁盘恢复 cached profile。返回 true = 成功填充 `self.profile`。
    @discardableResult
    private func restoreFromDisk(login: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: login)) else { return false }
        do {
            let envelope = try JSONDecoder().decode(DiskEnvelope.self, from: data)
            self.profile = envelope.profile
            self.lastFetchedAt = Date(timeIntervalSince1970: envelope.fetchedAt)
            AppLog.network.debug("UserProfile restored from disk: login=\(login, privacy: .public)")
            return true
        } catch {
            // 解码失败（schema 演进 / 损坏）→ 清掉脏数据避免反复尝试
            UserDefaults.standard.removeObject(forKey: cacheKey(for: login))
            AppLog.network.warning("UserProfile disk decode failed, dropping cache: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
