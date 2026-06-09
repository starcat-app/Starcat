//
//  RepoCardConversionTests.swift
//  StarcatTests
//
//  R-01 v1.2 Phase B（2026-06-10）：覆盖 trending / weekly 领域模型 → `RepoCardViewData`
//  转换 + `TrendingRepo.makeEphemeralRepo()` 详情页兜底，保护 UnifiedRepoRow / Scaffold
//  迁移之后的核心数据流。
//
//  关注点：
//  - `TrendingRepo.asCardData(registry:)`：badge 默认走 `.trendingChange(starsInPeriod)`，
//    `isStarred` 通过 registry 查询，v8 字段（owner_avatar / subscribers / default_branch
//    / open_issues）从 DTO 经 init(card:) 一直透到 RepoCardViewData。
//  - `WeeklyProject.asCardData(registry:)`：`firstIssue > 0` 时挂 `.weeklyIssue` 徽章，
//    `firstIssue == 0` 时不挂徽章（避免 "# 0" 视觉突兀）。
//  - `TrendingRepo.makeEphemeralRepo()`：把 trending 模型转 in-memory `Repo`，仅供详情
//    页 hero 兜底，不进 DB；id = ghRepoId, isStarred = false（调用方按 registry 真值覆盖）。
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("R-01 trending/weekly 领域模型 → CardViewData 转换")
struct RepoCardConversionTests {

    // MARK: - TrendingRepo → CardData

    @Test("TrendingRepo.asCardData(registry:): 默认 badge = .trendingChange(starsInPeriod)")
    func trendingRepoToCardDataDefaultBadge() {
        let trending = makeTrendingRepo(ghRepoId: 1234, starsInPeriod: 321)
        let registry = StarredRegistry()

        let card = trending.asCardData(registry: registry)

        #expect(card.id == 1234)
        #expect(card.ghRepoId == 1234)
        #expect(card.fullName == "alice/foo")
        #expect(card.starsCount == 1000)
        #expect(card.forksCount == 50)
        #expect(card.isStarred == false)  // registry 未命中
        if case .trendingChange(let n) = card.badge {
            #expect(n == 321)
        } else {
            Issue.record("默认 badge 应为 .trendingChange，实际：\(String(describing: card.badge))")
        }
    }

    @Test("TrendingRepo.asCardData(registry:): registry 命中 → isStarred = true")
    func trendingRepoIsStarredFromRegistry() async throws {
        let trending = makeTrendingRepo(ghRepoId: 555, starsInPeriod: 0)
        let registry = try await makeRegistry(starredGhRepoIds: [555])

        let card = trending.asCardData(registry: registry)

        #expect(card.isStarred == true)
    }

    @Test("TrendingRepo.asCardData(badge:): 显式 badge 覆盖默认 .trendingChange")
    func trendingRepoExplicitBadgeOverridesDefault() {
        let trending = makeTrendingRepo(ghRepoId: 1, starsInPeriod: 99)
        let registry = StarredRegistry()

        let card = trending.asCardData(registry: registry, badge: .weeklyIssue(400))

        if case .weeklyIssue(let n) = card.badge {
            #expect(n == 400)
        } else {
            Issue.record("显式 badge 应保留")
        }
    }

    // MARK: - TrendingRepo.makeEphemeralRepo

    @Test("TrendingRepo.makeEphemeralRepo: id = ghRepoId, isStarred = false, v8 字段透传")
    func trendingMakeEphemeralRepoFieldsPassThrough() {
        let trending = makeTrendingRepo(
            ghRepoId: 9876,
            starsInPeriod: 50,
            ownerAvatar: URL(string: "https://avatars.githubusercontent.com/u/1"),
            subscribersCount: 12,
            defaultBranch: "main",
            openIssuesCount: 7
        )

        let ephemeral = trending.makeEphemeralRepo()

        #expect(ephemeral.id == 9876)
        #expect(ephemeral.isStarred == false)  // ephemeral 永远 false，调用方按 registry 覆盖
        #expect(ephemeral.fullName == "alice/foo")
        #expect(ephemeral.owner == "alice")
        #expect(ephemeral.name == "foo")
        #expect(ephemeral.starsCount == 1000)
        #expect(ephemeral.forksCount == 50)
        #expect(ephemeral.htmlUrl == "https://github.com/alice/foo")
        // v8 字段
        #expect(ephemeral.ownerAvatar == "https://avatars.githubusercontent.com/u/1")
        #expect(ephemeral.subscribersCount == 12)
        #expect(ephemeral.defaultBranch == "main")
        #expect(ephemeral.openIssuesCount == 7)
        // 缺失字段（trending 模型本就没有的）应是默认值
        #expect(ephemeral.watchersCount == 0)
        #expect(ephemeral.topicsArray.isEmpty)
        #expect(ephemeral.license == nil)
        #expect(ephemeral.homepage == nil)
    }

    @Test("TrendingRepo.makeEphemeralRepo: ghRepoId == 0 退化（过渡 row）")
    func trendingMakeEphemeralRepoSentinelGhRepoId() {
        let trending = makeTrendingRepo(ghRepoId: 0, starsInPeriod: 0)
        let ephemeral = trending.makeEphemeralRepo()

        #expect(ephemeral.id == 0)
        // 调用方应通过 id == 0 判断「无法 star/unstar」
    }

    // MARK: - WeeklyProject → CardData

    @Test("WeeklyProject.asCardData(registry:): firstIssue > 0 → .weeklyIssue 徽章")
    func weeklyProjectToCardDataWithIssueBadge() {
        let project = makeWeeklyProject(ghRepoId: 333, firstIssue: 399)
        let registry = StarredRegistry()

        let card = project.asCardData(registry: registry)

        #expect(card.id == 333)
        #expect(card.fullName == "bob/tiny")
        #expect(card.starsCount == 200)
        if case .weeklyIssue(let n) = card.badge {
            #expect(n == 399)
        } else {
            Issue.record("firstIssue > 0 时应挂 .weeklyIssue 徽章")
        }
    }

    @Test("WeeklyProject.asCardData(registry:): firstIssue == 0 → 不挂徽章")
    func weeklyProjectToCardDataNoIssueBadge() {
        let project = makeWeeklyProject(ghRepoId: 444, firstIssue: 0)
        let registry = StarredRegistry()

        let card = project.asCardData(registry: registry)

        #expect(card.badge == nil, "firstIssue == 0 时不应挂徽章（避免 # 0 视觉突兀）")
    }

    @Test("WeeklyProject.asCardData(registry:): registry 命中 → isStarred = true")
    func weeklyProjectIsStarredFromRegistry() async throws {
        let project = makeWeeklyProject(ghRepoId: 555, firstIssue: 1)
        let registry = try await makeRegistry(starredGhRepoIds: [555])

        let card = project.asCardData(registry: registry)

        #expect(card.isStarred == true)
    }

    // MARK: - Helpers

    /// 构造一个 TrendingRepo，便于覆盖各场景。
    ///
    /// `StarcatRepoCardDTO` 的 `subscribers` / `openIssues` 是 `Int`（默认 0），传入参数
    /// 用 `Int` 而非 `Int?` 与之对齐；TrendingRepo 内会把 0 当作"未设置"在 UI 隐藏。
    private func makeTrendingRepo(
        ghRepoId: Int64,
        starsInPeriod: Int,
        ownerAvatar: URL? = nil,
        subscribersCount: Int = 0,
        defaultBranch: String? = nil,
        openIssuesCount: Int = 0
    ) -> TrendingRepo {
        let card = StarcatRepoCardDTO(
            ghRepoId: ghRepoId,
            fullName: "alice/foo",
            owner: "alice",
            repo: "foo",
            ownerAvatar: ownerAvatar,
            description: "desc",
            language: "Swift",
            stars: 1000,
            forks: 50,
            watchers: 1000,
            subscribers: subscribersCount,
            topics: [],
            homepage: nil,
            licenseSpdx: nil,
            isArchived: false,
            isFork: false,
            isPrivate: false,
            defaultBranch: defaultBranch,
            openIssues: openIssuesCount,
            pushedAt: nil,
            updatedAt: nil,
            createdAt: nil,
            htmlUrl: URL(string: "https://github.com/alice/foo"),
            trending: StarcatRepoCardDTO.TrendingExtension(
                change: starsInPeriod,
                contributors: []
            )
        )
        return TrendingRepo(card: card, since: .daily)
    }

    /// 构造一个 WeeklyProject。
    ///
    /// 注：`WeeklyExtension` 没有 memberwise init（Decodable 自动合成依赖于 JSON 解码），
    /// 因此直接构造时通过 JSON 解码绕一圈，比手动 mirror struct 字段更稳。
    private func makeWeeklyProject(
        ghRepoId: Int64,
        firstIssue: Int
    ) -> WeeklyProject {
        let weekly: StarcatRepoCardDTO.WeeklyExtension? = {
            guard firstIssue > 0 else { return nil }
            let json = #"""
            {
              "first_issue": \#(firstIssue),
              "issue_url": "https://github.com/ruanyf/weekly/blob/master/docs/issue-\#(firstIssue).md"
            }
            """#.data(using: .utf8)!
            return try? JSONDecoder().decode(StarcatRepoCardDTO.WeeklyExtension.self, from: json)
        }()

        let card = StarcatRepoCardDTO(
            ghRepoId: ghRepoId,
            fullName: "bob/tiny",
            owner: "bob",
            repo: "tiny",
            description: "tiny tool",
            language: "Go",
            stars: 200,
            forks: 10,
            watchers: 200,
            topics: [],
            isArchived: false,
            isFork: false,
            isPrivate: false,
            htmlUrl: URL(string: "https://github.com/bob/tiny"),
            weekly: weekly
        )
        return WeeklyProject(card: card)
    }

    /// 构造一个已含指定 ghRepoIds 的 `StarredRegistry`。
    ///
    /// `StarredRegistry._add` 是 fileprivate（设计 §4.3.2 强制约束：只有
    /// `StarringSubsystem` 文件能写入 registry），单测必须走 `Bootstrapper.reload()`
    /// 全量重建路径——先把对应的 starred repos 落到 InMemoryDB，再让 bootstrapper
    /// 从 DB 拉一次重建 registry。
    private func makeRegistry(starredGhRepoIds: [Int64]) async throws -> StarredRegistry {
        let db = try InMemoryDatabaseManager()
        let repoRepo = GRDBRepoRepository(database: db)
        let dtos: [StarredRepoDTO] = starredGhRepoIds.map { id in
            StarredRepoDTO(
                starredAt: "2026-06-09T00:00:00Z",
                repo: GitHubRepoDTO(
                    id: id, name: "x", fullName: "u/x-\(id)",
                    owner: GitHubUserDTO(
                        id: 1, login: "u", name: nil, avatarUrl: nil,
                        publicRepos: nil, followers: nil, following: nil,
                        bio: nil, company: nil, location: nil, email: nil,
                        blog: nil, twitterUsername: nil, htmlUrl: nil
                    ),
                    description: nil, language: nil, stargazersCount: 0,
                    forksCount: 0, watchersCount: 0, topics: nil, license: nil,
                    homepage: nil, htmlUrl: "https://github.com/u/x-\(id)",
                    cloneUrl: nil, sshUrl: nil,
                    isPrivate: false, fork: false, archived: false,
                    pushedAt: nil, createdAt: nil, updatedAt: nil
                )
            )
        }
        try await repoRepo.upsertStarred(dtos, userID: 100, syncedAt: Date())

        let registry = StarredRegistry()
        let bootstrapper = StarredRegistryBootstrapper(registry: registry, repoRepository: repoRepo)
        await bootstrapper.reload()
        return registry
    }
}
