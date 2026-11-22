//
//  DeveloperLanguageService.swift
//  Starcat
//
//  当前登录用户“自己开发的公开仓库”语言统计服务。
//
//  设计动机：
//  - `HomeViewModel.languageStats` 统计的是用户 star 过的项目语言，代表兴趣画像；
//  - 分享卡 Top Languages 需要展示用户自己的开发语言，必须从用户拥有的公开仓库重新聚合；
//  - 语言接口是 N+1 请求，必须有 TTL + 磁盘快照，避免打开分享页时反复打 GitHub API。
//
//  数据口径：
//  - 仓库列表：`GET /user/repos?visibility=public&affiliation=owner`
//  - 仓库过滤：公开、非 fork
//  - 语言占比：逐仓库 `/languages` 返回的字节数聚合后统一计算
//  - 私有仓库不纳入统计：Starcat 当前 OAuth scope 不读取私有仓库内容，分享图也不应暗示私有数据。
//

import Foundation
import Observation

/// 侧栏与分享卡共用的开发语言快照。
///
/// `languages` 保留完整排序列表，View 层再决定显示前 5 还是折叠为 Other。
struct DeveloperLanguageSnapshot: Codable, Equatable {
    let login: String
    let fetchedAt: Date
    let repositoryCount: Int
    let totalBytes: Int
    let languages: [DeveloperLanguageEntry]
}

/// 单个语言的聚合结果。
struct DeveloperLanguageEntry: Codable, Equatable, Identifiable {
    let name: String
    let bytes: Int
    /// 0...1 的占比，展示时再转为百分比。
    let ratio: Double

    var id: String { name }
}

/// 用户开发语言统计服务，单例语义（由 AppDependencies 持有）。
@MainActor
@Observable
final class DeveloperLanguageService {

    // MARK: - 状态（UI 观察）

    /// 当前语言快照。nil = 从未成功加载。
    /// 失败时不清空，分享卡继续显示上次成功数据。
    private(set) var snapshot: DeveloperLanguageSnapshot?

    /// 首次无缓存加载时为 true；后台刷新不强制 UI 进入 loading。
    private(set) var isLoading: Bool = false

    /// 最近一次仓库列表级错误。单仓库 languages 失败只跳过并写日志，不污染本字段。
    private(set) var lastError: (any LocalizedError)?

    /// 上次成功加载时间。
    private(set) var lastFetchedAt: Date?

    // MARK: - 依赖

    /// 这里直接持有具体 `GitHubAPIClient` actor，避免把分享卡专属的 N+1 端点塞进
    /// 全局 mock 协议，保持其它调用方的协议面稳定。
    private let apiClient: GitHubAPIClient

    private let cacheKeyPrefix = "developer.languages.snapshot."

    /// TTL：7 天。开发语言只需近似画像，避免频繁遍历所有公开仓库请求 `/languages`。
    private let ttl: TimeInterval = 7 * 24 * 60 * 60

    private var inflightTask: Task<Void, Never>?
    private var inflightLogin: String?

    /// 在途任务代数：每次真正启动新 load 或 reset 都递增。
    /// 为什么需要：换号 / reset 取消旧任务后，旧任务可能在「新任务已登记」之后
    /// 才恢复执行它的 defer 与 catch；没有代数校验时，旧 defer 会把新任务的
    /// inflight 登记清掉（同 login 在途去重失效、isLoading 提前复位），旧 catch
    /// 还可能把取消误记成 lastError 污染新一轮加载（全仓性能专项 P2-6 修正）。
    private var inflightGeneration = 0

    init(apiClient: GitHubAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - 公开 API

    /// 仅从本地恢复指定账号的快照，不触发网络，也不因过期丢弃数据。
    ///
    /// 启动时要与缓存的用户资料一起恢复，不能等 `/user` 校验成功后才显示语言条；
    /// 联网更新仍由 `load` 在会话验证成功后按 TTL 触发。
    func primeFromCache(login: String) {
        if snapshot?.login.lowercased() != login.lowercased() {
            snapshot = nil
            lastFetchedAt = nil
        }

        if snapshot == nil {
            restoreFromDisk(login: login)
        }
    }

    /// 加载当前用户开发语言快照，过期时保留旧值并在后台刷新。
    ///
    /// - Parameters:
    ///   - login: 当前登录用户 login。
    ///   - force: true = 跳过 TTL 强制刷新；false = 命中 TTL 直接复用。
    func load(login: String, force: Bool = false) {
        let normalizedLogin = login.lowercased()
        primeFromCache(login: login)

        if !force, let last = lastFetchedAt, Date().timeIntervalSince(last) < ttl {
            return
        }

        if inflightTask != nil {
            if inflightLogin == normalizedLogin { return }
            inflightTask?.cancel()
            inflightTask = nil
            inflightLogin = nil
        }

        if snapshot == nil {
            isLoading = true
        }

        inflightLogin = normalizedLogin
        // 代数递增与 Task 创建同在本 actor 上、之间无挂起点；Task 闭包内的所有
        // 状态写入都先校验自己仍是最新一代，避免被取消的旧任务污染新一轮状态。
        inflightGeneration += 1
        let generation = inflightGeneration
        inflightTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // 只有自己仍是最新一代时才清登记：换号 / reset 取消旧任务后，旧
                // defer 可能在新任务已登记 in-flight 之后才恢复执行，无条件清理会
                // 弄丢新任务的同 login 去重登记并提前复位 isLoading。
                // defer 闭包内禁止 return（编译器禁止控制流逸出），用条件块等价表达守卫。
                if generation == self.inflightGeneration {
                    self.isLoading = false
                    self.inflightTask = nil
                    self.inflightLogin = nil
                }
            }

            do {
                let fetched = try await self.fetchSnapshot(login: login)
                guard generation == self.inflightGeneration, !Task.isCancelled else { return }
                self.snapshot = fetched
                self.lastFetchedAt = fetched.fetchedAt
                self.lastError = nil
                self.persistToDisk(login: login, snapshot: fetched)
                AppLog.network.info("Developer languages fetched: login=\(login, privacy: .public), repos=\(fetched.repositoryCount, privacy: .public), languages=\(fetched.languages.count, privacy: .public)")
            } catch is CancellationError {
                AppLog.network.info("Developer languages fetch cancelled: login=\(login, privacy: .public)")
            } catch NetworkError.cancelled {
                // API 客户端会把底层 URLsession 的任务取消包装成 NetworkError.cancelled
                // 抛出；语义上就是取消，必须先于 LocalizedError 分支拦截，否则会把
                // lastError 污染成「取消错误」并干扰调用方对新一次加载的判断。
                AppLog.network.info("Developer languages fetch cancelled: login=\(login, privacy: .public)")
            } catch let err as LocalizedError {
                guard generation == self.inflightGeneration else { return }
                self.lastError = err
                AppLog.network.error("Developer languages fetch failed: \(err.localizedDescription, privacy: .public)")
            } catch {
                guard generation == self.inflightGeneration else { return }
                AppLog.network.error("Developer languages fetch failed (unknown): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 登出 / 401 时清掉当前账号快照。
    func reset(login: String?) {
        // 先递增代数再取消：被取消的旧任务随后恢复执行时，其 defer / catch 因代数
        // 不匹配而不再触碰这里正在重建的状态。
        inflightGeneration += 1
        inflightTask?.cancel()
        inflightTask = nil
        inflightLogin = nil
        snapshot = nil
        isLoading = false
        lastError = nil
        lastFetchedAt = nil
        if let login {
            UserDefaults.standard.removeObject(forKey: cacheKey(for: login))
        }
    }

    // MARK: - 拉取与聚合

    /// 仓库引用（仅 owner + name），值类型且 Sendable，可安全进入任务组子任务。
    private struct RepositoryRef: Sendable {
        let owner: String
        let name: String
    }

    /// `/languages` 单仓请求的有界并发上限（全仓性能专项 P2-6）。
    ///
    /// 并发只省等待时间，总请求数与旧串行版一致（每仓恰好一次）；6 是后台批量
    /// 刷新的保守值，避免顶到 GitHub 二级限流。`nonisolated` 让任务组子任务
    /// （@Sendable 闭包）可以读取该常量，不必跳回主 actor。
    private nonisolated static let languageFetchConcurrency = 6

    /// 任务组子任务入口：单仓 `/languages` 取数。
    ///
    /// `nonisolated static`：子任务闭包是 @Sendable，不能调用 @MainActor 隔离的
    /// 成员。取消类错误（CancellationError 与 NetworkError.cancelled）统一映射回
    /// CancellationError 向上抛，终止整组补位调度；其余单仓失败降级为空结果只记
    /// 日志——与旧串行版「单仓失败只跳过」的隔离语义一致（最常见是仓库刚删除 /
    /// 重命名后的 404）。
    nonisolated private static func fetchRepoLanguages(
        _ repository: RepositoryRef,
        client: GitHubAPIClient
    ) async throws -> [String: Int] {
        try Task.checkCancellation()
        do {
            return try await client.repositoryLanguages(owner: repository.owner, repo: repository.name)
        } catch is CancellationError {
            throw CancellationError()
        } catch NetworkError.cancelled {
            throw CancellationError()
        } catch {
            AppLog.network.warning("Developer language repo skipped: \(repository.owner, privacy: .public)/\(repository.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func fetchSnapshot(login: String) async throws -> DeveloperLanguageSnapshot {
        var page = 1
        var repositories: [RepositoryRef] = []

        while true {
            try Task.checkCancellation()
            let response = try await apiClient.ownedPublicRepositories(page: page, perPage: 100)
            let refs = response.value
                .filter { !$0.isPrivate && !$0.fork }
                .map { RepositoryRef(owner: $0.owner.login, name: $0.name) }
            repositories.append(contentsOf: refs)

            guard let next = response.linkHeader.nextPage else { break }
            page = next
        }

        var totals: [String: Int] = [:]
        // 有界并发任务组（全仓性能专项 P2-6）：先填满并发窗口，每完成一个补一个
        // 新任务。补位循环恰好执行 repositories.count 次，总请求数与旧串行版一致。
        // 取消时 group.next() 抛 CancellationError 向上传播，任务组自动取消其余
        // 子任务，补位循环随即终止。
        try await withThrowingTaskGroup(of: [String: Int].self) { group in
            // 组体闭包继承本 actor 隔离，可以安全改 totals / next；子任务闭包是
            // @Sendable，不能捕获 @MainActor self，只捕获 actor 引用与值类型数组。
            let client = apiClient
            let refs = repositories
            var next = 0
            while next < min(Self.languageFetchConcurrency, refs.count) {
                // @Sendable 子闭包捕获 var 是数据竞争，先拷贝为 let 再进闭包。
                let index = next
                group.addTask { try await Self.fetchRepoLanguages(refs[index], client: client) }
                next += 1
            }
            for _ in 0..<refs.count {
                guard let languages = try await group.next() else { break }
                for (language, bytes) in languages where bytes > 0 {
                    totals[language, default: 0] += bytes
                }
                if next < refs.count {
                    let index = next
                    group.addTask { try await Self.fetchRepoLanguages(refs[index], client: client) }
                    next += 1
                }
            }
        }

        let totalBytes = totals.values.reduce(0, +)
        let languages = totals
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                }
                return lhs.value > rhs.value
            }
            .map { name, bytes in
                DeveloperLanguageEntry(
                    name: name,
                    bytes: bytes,
                    ratio: totalBytes > 0 ? Double(bytes) / Double(totalBytes) : 0
                )
            }

        return DeveloperLanguageSnapshot(
            login: login,
            fetchedAt: Date(),
            repositoryCount: repositories.count,
            totalBytes: totalBytes,
            languages: languages
        )
    }

    // MARK: - 磁盘缓存

    private struct DiskEnvelope: Codable {
        let fetchedAt: TimeInterval
        let snapshot: DeveloperLanguageSnapshot
    }

    private func cacheKey(for login: String) -> String {
        cacheKeyPrefix + login.lowercased()
    }

    private func persistToDisk(login: String, snapshot: DeveloperLanguageSnapshot) {
        let envelope = DiskEnvelope(
            fetchedAt: snapshot.fetchedAt.timeIntervalSince1970,
            snapshot: snapshot
        )
        do {
            let data = try CacheJSONCodec.pack(JSONEncoder().encode(envelope))
            UserDefaults.standard.set(data, forKey: cacheKey(for: login))
        } catch {
            AppLog.network.warning("Developer languages persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restoreFromDisk(login: String) {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: login)) else { return }
        do {
            let envelope = try JSONDecoder().decode(DiskEnvelope.self, from: CacheJSONCodec.unpack(data))
            snapshot = envelope.snapshot
            lastFetchedAt = Date(timeIntervalSince1970: envelope.fetchedAt)
            if let upgraded = CacheJSONCodec.upgradeIfSmaller(data) {
                UserDefaults.standard.set(upgraded, forKey: cacheKey(for: login))
            }
            AppLog.network.debug("Developer languages restored from disk: login=\(login, privacy: .public)")
        } catch {
            UserDefaults.standard.removeObject(forKey: cacheKey(for: login))
            AppLog.network.warning("Developer languages disk decode failed, dropping cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
