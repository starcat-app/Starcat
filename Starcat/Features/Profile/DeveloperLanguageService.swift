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

/// 分享卡使用的开发语言快照。
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

    /// TTL：12 小时。开发语言画像变化频率低，而 `/languages` 是逐仓库请求，适合长缓存。
    private let ttl: TimeInterval = 12 * 60 * 60

    private var inflightTask: Task<Void, Never>?
    private var inflightLogin: String?

    init(apiClient: GitHubAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - 公开 API

    /// 加载当前用户开发语言快照。
    ///
    /// - Parameters:
    ///   - login: 当前登录用户 login。
    ///   - force: true = 跳过 TTL 强制刷新；false = 命中 TTL 直接复用。
    func load(login: String, force: Bool = false) {
        let normalizedLogin = login.lowercased()

        if snapshot?.login.lowercased() != normalizedLogin {
            snapshot = nil
            lastFetchedAt = nil
        }

        if snapshot == nil {
            restoreFromDisk(login: login)
        }

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
        inflightTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoading = false
                self.inflightTask = nil
                self.inflightLogin = nil
            }

            do {
                let fetched = try await self.fetchSnapshot(login: login)
                guard !Task.isCancelled else { return }
                self.snapshot = fetched
                self.lastFetchedAt = fetched.fetchedAt
                self.lastError = nil
                self.persistToDisk(login: login, snapshot: fetched)
                AppLog.network.info("Developer languages fetched: login=\(login, privacy: .public), repos=\(fetched.repositoryCount, privacy: .public), languages=\(fetched.languages.count, privacy: .public)")
            } catch is CancellationError {
                AppLog.network.info("Developer languages fetch cancelled: login=\(login, privacy: .public)")
            } catch let err as LocalizedError {
                self.lastError = err
                AppLog.network.error("Developer languages fetch failed: \(err.localizedDescription, privacy: .public)")
            } catch {
                AppLog.network.error("Developer languages fetch failed (unknown): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 登出 / 401 时清掉当前账号快照。
    func reset(login: String?) {
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

    private struct RepositoryRef {
        let owner: String
        let name: String
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
        for repository in repositories {
            try Task.checkCancellation()
            do {
                let languages = try await apiClient.repositoryLanguages(owner: repository.owner, repo: repository.name)
                for (language, bytes) in languages where bytes > 0 {
                    totals[language, default: 0] += bytes
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 单仓库失败不应让整张分享卡空掉。最常见场景是仓库刚删除 / 重命名后的 404。
                AppLog.network.warning("Developer language repo skipped: \(repository.owner, privacy: .public)/\(repository.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
            let data = try JSONEncoder().encode(envelope)
            UserDefaults.standard.set(data, forKey: cacheKey(for: login))
        } catch {
            AppLog.network.warning("Developer languages persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restoreFromDisk(login: String) {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: login)) else { return }
        do {
            let envelope = try JSONDecoder().decode(DiskEnvelope.self, from: data)
            snapshot = envelope.snapshot
            lastFetchedAt = Date(timeIntervalSince1970: envelope.fetchedAt)
            AppLog.network.debug("Developer languages restored from disk: login=\(login, privacy: .public)")
        } catch {
            UserDefaults.standard.removeObject(forKey: cacheKey(for: login))
            AppLog.network.warning("Developer languages disk decode failed, dropping cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}
