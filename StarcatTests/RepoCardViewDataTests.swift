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
        let card = repo.asCardData(badge: .activityKind(.star, Date(timeIntervalSince1970: 0)))
        if case .activityKind(let cat, _) = card.badge {
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
                pushedAt: nil, createdAt: nil, updatedAt: nil
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
