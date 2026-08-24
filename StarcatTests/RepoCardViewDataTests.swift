//
//  RepoCardViewDataTests.swift
//  StarcatTests
//
//  覆盖 R-01 适配层 RepoCardViewData 的关键路径：
//  1. Repo.asCardData() 字段映射 + isStarred 直接读 self.isStarred
//  2. StarcatRepoCardDTO.asCardData(registry:badge:) 字段映射 + isStarred 通过 registry 查询
//  3. id == Int64 (ghRepoId)，而非 fullName（rename 不影响 SwiftUI diff）
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("RepoCardViewData (R-01 适配层)")
struct RepoCardViewDataTests {

    // MARK: - 1. Repo → CardData

    @Test("Repo.asCardData(): 字段映射正确，isStarred 直接读 self")
    func repoToCardData() {
        let repo = Repo(
            id: 12345,
            owner: "alice",
            name: "foo",
            fullName: "alice/foo",
            description: "desc",
            language: "Swift",
            starsCount: 100,
            forksCount: 10,
            watchersCount: 5,
            topics: nil,
            license: "MIT",
            homepage: nil,
            htmlUrl: "https://github.com/alice/foo",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: true,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )

        let card = repo.asCardData()
        #expect(card.id == 12345)              // id = ghRepoId Int64
        #expect(card.ghRepoId == 12345)
        #expect(card.fullName == "alice/foo")
        #expect(card.owner == "alice")
        #expect(card.repo == "foo")
        #expect(card.starsCount == 100)
        #expect(card.forksCount == 10)
        #expect(card.isArchived == true)
        #expect(card.isStarred == true)        // 直接读 Repo.isStarred
        #expect(card.badge == nil)
    }

    @Test("Repo.asCardData(badge:): 传入 badge 正确携带")
    func repoToCardDataWithBadge() {
        let repo = sampleRepo(id: 1, isStarred: false)
        // v2.0（2026-06-11）：`.activityKind` 第二参 Date 已删除（详见 RepoCardViewData.swift 注释）。
        let card = repo.asCardData(badge: .activityKind(.star))
        if case .activityKind(let cat) = card.badge {
            #expect(cat == .star)
        } else {
            Issue.record("badge case 不匹配")
        }
    }

    // MARK: - 2. DTO → CardData，isStarred 来自 registry

    @Test("DTO.asCardData(registry:): registry 命中 → isStarred = true")
    func dtoToCardDataIsStarredFromRegistry() async throws {
        // 用 InMemoryDB + bootstrapper 把 ghRepoId=42 写入 registry
        let db = try InMemoryDatabaseManager()
        let repoRepo = GRDBRepoRepository(database: db)
        let dto42 = StarredRepoDTO(
            starredAt: "2026-06-09T00:00:00Z",
            repo: GitHubRepoDTO(
                id: 42, name: "x", fullName: "u/x",
                owner: GitHubUserDTO(id: 1, login: "u", name: nil, avatarUrl: nil,
                                     publicRepos: nil, followers: nil, following: nil,
                                     bio: nil, company: nil, location: nil, email: nil,
                                     blog: nil, twitterUsername: nil, htmlUrl: nil),
                description: nil, language: nil, stargazersCount: 0,
                forksCount: 0, watchersCount: 0, topics: nil, license: nil,
                homepage: nil, htmlUrl: "https://github.com/u/x", cloneUrl: nil, sshUrl: nil,
                isPrivate: false, fork: false, archived: false,
                pushedAt: nil, createdAt: nil, updatedAt: nil,
                openIssuesCount: nil, defaultBranch: nil,
                disabled: nil, isTemplate: nil, score: nil
            )
        )
        try await repoRepo.upsertStarred([dto42], userID: 100, syncedAt: Date())

        let registry = StarredRegistry()
        let bootstrapper = StarredRegistryBootstrapper(registry: registry, repoRepository: repoRepo)
        await bootstrapper.reload()

        let dto = StarcatRepoCardDTO(
            ghRepoId: 42, fullName: "u/x", owner: "u", repo: "x",
            stars: 100, forks: 5
        )
        let card = dto.asCardData(registry: registry)
        #expect(card.isStarred == true)
        #expect(card.id == 42)
        #expect(card.starsCount == 100)
        #expect(card.forksCount == 5)
    }

    @Test("DTO.asCardData(registry:): registry 未命中 → isStarred = false")
    func dtoToCardDataIsStarredFalse() {
        let registry = StarredRegistry()
        let dto = StarcatRepoCardDTO(
            ghRepoId: 999, fullName: "a/b", owner: "a", repo: "b"
        )
        let card = dto.asCardData(registry: registry)
        #expect(card.isStarred == false)
        #expect(card.id == 999)
    }

    @Test("DTO.asCardData(badge:): trending +N 徽章正确携带")
    func dtoToCardDataWithTrendingBadge() {
        let registry = StarredRegistry()
        let dto = StarcatRepoCardDTO(
            ghRepoId: 1, fullName: "a/b", owner: "a", repo: "b"
        )
        let card = dto.asCardData(registry: registry, badge: .trendingChange(321))
        if case .trendingChange(let n) = card.badge {
            #expect(n == 321)
        } else {
            Issue.record("badge case 不匹配")
        }
    }

    // MARK: - 3. id 稳定性（rename 不影响）

    @Test("id 是 Int64 (ghRepoId)：rename 不破坏 SwiftUI diff")
    func idIsGhRepoIdNotFullName() {
        let r1 = sampleRepo(id: 7, isStarred: true)
        var r2 = r1
        r2.fullName = "alice/renamed-foo"
        r2.name = "renamed-foo"

        let c1 = r1.asCardData()
        let c2 = r2.asCardData()

        #expect(c1.id == c2.id)                   // id 不变（同 gh_repo_id）
        #expect(c1.fullName != c2.fullName)        // 但显示文案变了
        #expect(c1.id == 7)
    }

    // MARK: - 4. readStatus 注入（v2 阅读状态角标）

    @Test("Repo.asCardData(): 默认 readStatus = nil（其他场景无注入）")
    func readStatusDefaultsToNil() {
        let repo = sampleRepo(id: 1, isStarred: true)
        let card = repo.asCardData()
        #expect(card.readStatus == nil)
    }

    @Test("Repo.asCardData(readStatus:): unread / read / using 显式注入正确携带")
    func readStatusExplicitlyPassed() {
        let repo = sampleRepo(id: 1, isStarred: true)

        let unread = repo.asCardData(readStatus: .unread)
        #expect(unread.readStatus == .unread)

        let read = repo.asCardData(readStatus: .read)
        #expect(read.readStatus == .read)

        let using = repo.asCardData(readStatus: .using)
        #expect(using.readStatus == .using)
    }

    @Test("DTO.asCardData(): readStatus 强制 nil（trending/weekly 不显角标策略）")
    func dtoReadStatusAlwaysNil() {
        let registry = StarredRegistry()
        let dto = StarcatRepoCardDTO(
            ghRepoId: 999, fullName: "a/b", owner: "a", repo: "b"
        )
        let card = dto.asCardData(registry: registry)
        #expect(card.readStatus == nil)
    }

    @Test("远端卡片转换支持显式注入知识库状态")
    func remoteCardDataAcceptsLibraryStateInjection() {
        let registry = StarredRegistry()
        let cardDTO = StarcatRepoCardDTO(
            ghRepoId: 1001,
            fullName: "a/lib",
            owner: "a",
            repo: "lib"
        )

        let dtoCard = cardDTO.asCardData(registry: registry, isInLibrary: true)
        #expect(dtoCard.isInLibrary)

        let trending = TrendingRepo(card: cardDTO, since: .daily)
        let trendingCard = trending.asCardData(registry: registry, isInLibrary: true)
        #expect(trendingCard.isInLibrary)

        let weeklyDTO = WeeklyFeedRepoDTO(
            card: cardDTO,
            isAvailable: true,
            sourceTypes: [.weekly],
            firstEventAt: "2026-07-01T00:00:00Z",
            latestEventAt: "2026-07-02T00:00:00Z",
            weekly: nil,
            zread: nil,
            discovery: nil
        )
        let weekly = WeeklyFeedItem(dto: weeklyDTO)
        let weeklyCard = weekly.asCardData(registry: registry, isInLibrary: true)
        #expect(weeklyCard.isInLibrary)

        let discovery = DiscoveryRepoDTO(
            repoID: 1001,
            fullName: "a/lib",
            owner: "a",
            name: "lib",
            description: nil,
            homepage: nil,
            language: "Swift",
            stars: 10,
            forks: 1,
            watchers: 10,
            subscribers: 0,
            openIssues: 0,
            ownerAvatar: nil,
            defaultBranch: nil,
            licenseSpdx: nil,
            topics: [],
            platforms: [],
            pushedAt: nil,
            updatedAt: nil,
            createdAt: nil,
            isArchived: false,
            isFork: false,
            latestReleaseTag: nil,
            latestReleaseAt: nil,
            latestReleaseURL: nil,
            releaseDownloadCount: 0,
            rank: nil,
            score: nil,
            reasons: [],
            signals: []
        )
        let discoveryCard = discovery.asCardData(registry: registry, isInLibrary: true)
        #expect(discoveryCard.isInLibrary)
    }

    @Test("RepoDetailHero 从 Repo 透传订阅数与 GitHub 时间")
    func repoDetailHeroKeepsSubscribersAndDates() {
        let repo = Repo(
            id: 2001,
            owner: "alice",
            name: "metadata",
            fullName: "alice/metadata",
            description: "Metadata fixture",
            language: "Swift",
            starsCount: 120,
            forksCount: 12,
            watchersCount: 18,
            topics: nil,
            license: "MIT",
            homepage: nil,
            htmlUrl: "https://github.com/alice/metadata",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: false,
            pushedAt: "2026-08-24T10:30:00Z",
            createdAt: "2024-02-03T04:05:06Z",
            updatedAt: "2026-08-23T12:34:56Z",
            starredAt: nil,
            cachedAt: nil,
            subscribersCount: 9
        )

        let hero = RepoDetailHero(repo: repo)

        #expect(hero.watchersCount == 18)
        #expect(hero.subscribersCount == 9)
        #expect(hero.createdAt == ISO8601DateFormatter().date(from: "2024-02-03T04:05:06Z"))
        #expect(hero.updatedAt == ISO8601DateFormatter().date(from: "2026-08-23T12:34:56Z"))
    }

    @Test("Awesome 同仓库元数据刷新会改变详情任务 identity")
    func awesomeMetadataRefreshChangesDiscoveryDetailIdentity() {
        let cached = AwesomeRepositoryItem(
            id: 3001,
            owner: "james-proxy",
            name: "james",
            fullName: "james-proxy/james",
            description: nil,
            ownerAvatarURL: nil,
            language: nil,
            stars: 1_438,
            isArchived: false,
            updatedAt: nil,
            evidence: []
        ).discoveryDTO
        let refreshed = AwesomeRepositoryItem(
            id: 3001,
            owner: "james-proxy",
            name: "james",
            fullName: "james-proxy/james",
            description: "Web Debugging Proxy Application",
            ownerAvatarURL: nil,
            language: nil,
            stars: 1_438,
            isArchived: false,
            updatedAt: Date(timeIntervalSince1970: 1_723_462_774),
            createdAt: Date(timeIntervalSince1970: 1_435_217_234),
            evidence: []
        ).discoveryDTO

        // 详情页保留稳定 repoID，但视图和任务 identity 必须能观察完整元数据快照变化。
        #expect(cached.repoID == refreshed.repoID)
        #expect(cached != refreshed)

        let repo = refreshed.toEphemeralRepo(isStarred: false)
        #expect(repo.description == "Web Debugging Proxy Application")
        #expect(repo.createdAt != nil)
        #expect(repo.updatedAt != nil)
    }

    // MARK: - Helpers

    private func sampleRepo(id: Int64, isStarred: Bool) -> Repo {
        Repo(
            id: id, owner: "alice", name: "foo", fullName: "alice/foo",
            description: nil, language: nil,
            starsCount: 0, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil,
            htmlUrl: "https://github.com/alice/foo", cloneUrl: nil, sshUrl: nil,
            isPrivate: false, isFork: false, isArchived: false,
            isStarred: isStarred,
            pushedAt: nil, createdAt: nil, updatedAt: nil,
            starredAt: nil, cachedAt: nil
        )
    }
}
