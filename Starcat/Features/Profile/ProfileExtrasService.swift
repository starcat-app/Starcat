//
//  ProfileExtrasService.swift
//  Starcat
//
//  浮层资料按账号缓存并独立刷新；不会把非公开组织合并回 AuthSession 的公开资料。
//

import Foundation
import Observation

/// 主线程发布展示状态，网络通过 Sendable 数据源并行读取；关闭浮层后保留本次账号结果。
@MainActor
@Observable
final class ProfileExtrasService {
    enum Section: String, CaseIterable, Sendable {
        case achievements, organizations, sponsors
    }

    private(set) var snapshot = Snapshot()
    private(set) var loading: Set<Section> = []
    private(set) var failures: Set<Section> = []
    private(set) var userID: Int64?

    var isLoading: Bool { !loading.isEmpty }

    private let api: any GitHubProfileExtrasProviding
    private let defaults: UserDefaults
    private var inflightTask: Task<Void, Never>?
    private var requestID = UUID()

    init(api: any GitHubProfileExtrasProviding, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
    }

    /// 首次打开只恢复当前账号缓存；各分区按自己的 TTL 判断，不用一次成功掩盖另一分区失败。
    func load(user: GitHubUserDTO, force: Bool = false) {
        if userID != user.id {
            if userID != nil { reset() }
            userID = user.id
            if let data = defaults.data(forKey: cacheKey),
               let cached = try? JSONDecoder().decode(Snapshot.self, from: CacheJSONCodec.unpack(data)) {
                snapshot = cached
                if let upgraded = CacheJSONCodec.upgradeIfSmaller(data) {
                    defaults.set(upgraded, forKey: cacheKey)
                }
            }
        }
        guard force || inflightTask == nil else { return }
        let pending = Section.allCases.filter { section in
            let ttl: TimeInterval = section == .achievements ? 24 * 60 * 60 : 30 * 60
            return force || (snapshot.fetchedAt(for: section).map { Date().timeIntervalSince($0) >= ttl } ?? true)
        }
        guard !pending.isEmpty else { return }
        inflightTask?.cancel()
        let identity = UUID()
        requestID = identity
        loading = Set(pending)
        failures.subtract(pending)
        let api = self.api
        let login = user.login
        inflightTask = Task { [weak self] in
            await withTaskGroup(of: LoadResult.self) { group in
                for section in pending {
                    group.addTask {
                        do {
                            switch section {
                            case .achievements:
                                return .achievements(try await api.getProfileAchievements(login: login, forceRefresh: force))
                            case .organizations:
                                return .organizations(try await api.getProfileOrganizations(login: login, forceRefresh: force))
                            case .sponsors:
                                return .sponsors(try await api.getProfileSponsors())
                            }
                        } catch {
                            return .failed(section)
                        }
                    }
                }
                for await result in group {
                    // 登出、换账号或主动刷新会取消旧任务；即使底层不响应取消，也不能回填上个账号的数据。
                    guard !Task.isCancelled, let self, self.requestID == identity else { return }
                    self.accept(result)
                }
            }
            guard let self, self.requestID == identity else { return }
            self.loading = []
            self.inflightTask = nil
        }
    }

    /// 主动登出和 Token 失效共用清理入口，清掉包含非公开成员关系的本地快照。
    func reset() {
        inflightTask?.cancel()
        inflightTask = nil
        requestID = UUID()
        // 重启后还未打开过浮层时 userID 仍为空；退出也应删除上次运行留下的非公开组织快照。
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("profile.extras.") {
            defaults.removeObject(forKey: key)
        }
        userID = nil
        snapshot = Snapshot()
        loading = []
        failures = []
    }

    /// 成功的空结果替换旧列表；失败只记录提示，保留同账号的旧内容与上次成功时间。
    private func accept(_ result: LoadResult) {
        let now = Date()
        switch result {
        case .achievements(let achievements):
            snapshot.achievements = achievements
            snapshot.achievementsFetchedAt = now
            loading.remove(.achievements)
        case .organizations(let organizations):
            snapshot.organizations = organizations
            snapshot.organizationsFetchedAt = now
            loading.remove(.organizations)
        case .sponsors(let sponsors):
            snapshot.sponsors = sponsors
            snapshot.sponsorsFetchedAt = now
            loading.remove(.sponsors)
        case .failed(let section):
            failures.insert(section)
            loading.remove(section)
        }
        if let data = try? CacheJSONCodec.pack(JSONEncoder().encode(snapshot)) {
            defaults.set(data, forKey: cacheKey)
        }
    }

    private var cacheKey: String { "profile.extras.\(userID ?? 0)" }

    /// 只有该服务持有这份缓存；分享卡继续使用公开 GitHubUserDTO。
    struct Snapshot: Codable, Equatable {
        var achievements: [GitHubAchievement]?
        var organizations: GitHubProfileOrganizations?
        var sponsors: GitHubSponsors?
        var achievementsFetchedAt: Date?
        var organizationsFetchedAt: Date?
        var sponsorsFetchedAt: Date?

        func fetchedAt(for section: Section) -> Date? {
            switch section {
            case .achievements: achievementsFetchedAt
            case .organizations: organizationsFetchedAt
            case .sponsors: sponsorsFetchedAt
            }
        }
    }

    private enum LoadResult: Sendable {
        case achievements([GitHubAchievement])
        case organizations(GitHubProfileOrganizations)
        case sponsors(GitHubSponsors)
        case failed(Section)
    }
}
