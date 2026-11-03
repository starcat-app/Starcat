//
//  DailyRadarProjectStore.swift
//  Starcat
//
//  日报项目快照的只读适配。服务已完成公开仓库核验，客户端只转换 DTO；
//  不重复批量查询 GitHub，不写 Star、知识库或周刊来源事件。
//

import Foundation
import Observation

/// 文章与项目面板共用同一服务端快照，账户切换不带入上一账户展示状态。
@MainActor
@Observable
final class DailyRadarProjectStore {
    private var scope: UInt64?
    private var items: [String: DiscoveryRepoDTO] = [:]
    private var failures: Set<String> = []

    func item(for fullName: String, scope: UInt64) -> DiscoveryRepoDTO? {
        self.scope == scope ? items[fullName.lowercased()] : nil
    }

    func failed(for fullName: String, scope: UInt64) -> Bool {
        self.scope == scope && failures.contains(fullName.lowercased())
    }

    /// 每次文章挂载重新适配其修订快照，不能让同名项目的另一篇文章覆盖修订语义。
    func load(project: DailyRadarReport.Project, dependencies: AppDependencies, retry: Bool = false) async {
        let revision = dependencies.databaseScopeRevision
        if scope != revision {
            items.removeAll()
            failures.removeAll()
            scope = revision
        }
        let key = project.id.lowercased()
        guard !project.repo.isPrivate, project.repo.ghRepoId > 0 else {
            items.removeValue(forKey: key)
            failures.insert(key)
            return
        }
        let repo = project.repo.toEphemeralRepo()
        items[key] = DiscoveryRepoDTO(
            repoID: repo.id, fullName: repo.fullName, owner: repo.owner, name: repo.name,
            description: repo.description, homepage: repo.homepage, language: repo.language,
            stars: repo.starsCount, forks: repo.forksCount, watchers: repo.watchersCount,
            subscribers: repo.subscribersCount ?? 0, openIssues: repo.openIssuesCount ?? 0,
            ownerAvatar: repo.ownerAvatar, defaultBranch: repo.defaultBranch,
            licenseSpdx: repo.license, topics: repo.topicsArray, platforms: [],
            pushedAt: repo.pushedAt, updatedAt: repo.updatedAt, createdAt: repo.createdAt,
            isArchived: repo.isArchived, isFork: repo.isFork,
            latestReleaseTag: nil, latestReleaseAt: nil, latestReleaseURL: nil,
            releaseDownloadCount: 0, rank: nil, score: nil, reasons: [], signals: []
        )
        failures.remove(key)
    }
}
