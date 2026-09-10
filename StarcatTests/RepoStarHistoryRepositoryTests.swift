//
//  RepoStarHistoryRepositoryTests.swift
//  StarcatTests
//
//  验证 GitHub 官方 Star 历史的单一来源、完整替换和 repo 生命周期。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Repo Star History Repository")
struct RepoStarHistoryRepositoryTests {

    @Test("读取历史时只返回 GitHub 官方来源")
    func pointsOnlyReturnsOfficialHistory() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1, owner: "octo", name: "history")
        let repository = GRDBRepoStarHistoryRepository(database: database)
        try await database.writer.write { db in
            // 模拟升级前已存在的本地行，读路径不得再将它叠加到官方曲线。
            try db.execute(sql: """
                INSERT INTO repo_star_history_points (
                    repo_id, observed_on, stars_count, source, precision, fetched_at
                ) VALUES
                    (1, '2026-07-26', 999, 'local_snapshot', 'snapshot', '2026-07-27T00:00:00.000Z'),
                    (1, '2026-07-27', 12, 'github_history', 'reconstructed', '2026-07-27T00:00:00.000Z')
                """)
        }

        let points = try await repository.points(repoId: 1)
        #expect(points.count == 1)
        #expect(points[0].count == 12)
        #expect(points[0].source == .githubHistory)
        #expect(points[0].precision == .reconstructed)
        #expect(StarHistoryDateCodec.dayString(from: points[0].date) == "2026-07-27")
    }

    @Test("替换官方历史应清理仓库内所有旧来源")
    func officialReplacementRemovesLegacySources() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 2, owner: "octo", name: "merged")
        let repository = GRDBRepoStarHistoryRepository(database: database)
        let fetchedAt = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T08:00:00.000Z"))
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO repo_star_history_points (
                    repo_id, observed_on, stars_count, source, precision, fetched_at
                ) VALUES (2, '2026-07-25', 100, 'local_snapshot', 'snapshot', '2026-07-27T00:00:00Z')
                """)
        }

        try await repository.replaceOfficialPoints(repoId: 2, points: [
            point("2026-07-26", 95, .githubHistory, .reconstructed, fetchedAt)
        ])
        try await repository.replaceOfficialPoints(repoId: 2, points: [
            point("2026-07-27", 96, .githubHistory, .reconstructed, fetchedAt)
        ])

        let points = try await repository.points(repoId: 2)
        #expect(points.count == 1)
        #expect(points[0].count == 96)
        #expect(points[0].source == .githubHistory)
        let rawSources = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT source FROM repo_star_history_points WHERE repo_id = 2")
        }
        #expect(rawSources == ["github_history"])
    }

    @Test("批量同步与单仓 metadata 更新不应写入历史")
    func repoMetadataDoesNotWriteHistory() async throws {
        let database = try InMemoryDatabaseManager()
        let repoRepository = GRDBRepoRepository(database: database)
        let historyRepository = GRDBRepoStarHistoryRepository(database: database)
        let observedAt = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z"))
        let first = makeStarredDTO(id: 3, stars: 10)
        let updated = makeStarredDTO(id: 3, stars: 15)

        try await repoRepository.upsertStarred([first], userID: 100, syncedAt: observedAt)
        _ = try await repoRepository.upsertSingleStarred(
            repoDTO: updated.repo,
            starredAt: updated.starredAt,
            userID: 100,
            syncedAt: observedAt.addingTimeInterval(60)
        )

        let points = try await historyRepository.points(repoId: 3)
        #expect(points.isEmpty)
    }

    @Test("删除 repo 应由外键级联清理全部历史点")
    func deletingRepoCascadesHistory() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 4, owner: "octo", name: "deleted")
        let repository = GRDBRepoStarHistoryRepository(database: database)
        let now = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z"))
        try await repository.replaceOfficialPoints(repoId: 4, points: [
            point("2026-07-27", 5, .githubHistory, .reconstructed, now)
        ])

        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM repos WHERE id = 4")
        }

        #expect(try await repository.points(repoId: 4).isEmpty)
    }

    @Test("GitHub 官方重建点应完整保留")
    func officialHistoryIsNotTruncatedByMetadata() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 5, owner: "octo", name: "priority")
        let now = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z"))
        let api = StubGitHubStarHistoryAPI(pages: [
            1: .init(
                weeks: [week("2026-07-26", days: [100, 20, 0, 0, 0, 0, 0])],
                nextPage: nil,
                etag: "\"priority-v1\""
            )
        ])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: api,
            now: { now }
        )
        let repo = fixtureRepo(
            id: 5,
            name: "priority",
            stars: 120
        )

        let snapshot = try await repository.refresh(
            repo: repo,
            range: .oneYear,
            forceRefresh: true
        )

        #expect(snapshot.remoteState == .fresh)
        #expect(snapshot.points.count == 2)
        #expect(snapshot.points.last?.count == 120)
        #expect(snapshot.points.last?.source == .githubHistory)
        #expect(snapshot.points.last?.precision == .reconstructed)
        #expect(snapshot.coverage?.start == StarHistoryDateCodec.date(from: "2026-07-26"))
        #expect(snapshot.coverage?.lastEvent == StarHistoryDateCodec.date(from: "2026-07-27"))
        // 重建 Repository 模拟下次启动：覆盖元信息必须随 SQLite 缓存恢复。
        let reopened = GRDBRepoStarHistoryRepository(database: database, now: { now })
        let restored = try await reopened.cached(repo: repo, range: .all)
        #expect(restored.coverage == snapshot.coverage)
    }

    @Test("未落库的公开 README 仓库按 owner/repo 使用官方历史缓存")
    func publicEphemeralRepositoryUsesOwnerRepoCache() async throws {
        let database = try InMemoryDatabaseManager()
        let now = try #require(
            ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z")
        )
        let api = StubGitHubStarHistoryAPI(pages: [
            1: .init(
                weeks: [week("2026-07-26", days: [10, 10, 0, 0, 0, 0, 0])],
                nextPage: nil,
                etag: "\"ephemeral-v1\""
            )
        ])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: api,
            now: { now }
        )
        var repo = Repo.makeMinimal(owner: "Octo", name: "Public-README")
        repo.id = 0
        repo.starsCount = 20
        repo.cachedAt = nil

        let fresh = try await repository.refresh(
            repo: repo,
            range: .all,
            forceRefresh: true
        )

        #expect(fresh.remoteState == .fresh)
        #expect(fresh.points.count == 2)
        #expect(fresh.points.last?.count == 20)
        #expect(await api.requests().count == 1)

        let reopened = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: StubGitHubStarHistoryAPI(pages: [:]),
            now: { now.addingTimeInterval(60 * 60) }
        )
        let cached = try await reopened.cached(repo: repo, range: .all)

        #expect(cached.remoteState == .cached)
        #expect(cached.points.count == 2)
        #expect(cached.points.last?.count == 20)
    }

    @Test("AI 与洞察页并发刷新同一 Star 范围只请求一次")
    func concurrentConsumersShareStarHistoryRefresh() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 30, owner: "octo", name: "single-flight")
        let now = try #require(
            ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z")
        )
        let api = StubGitHubStarHistoryAPI(
            pages: [
                1: .init(
                    weeks: [week("2026-07-26", days: [10, 10, 0, 0, 0, 0, 0])],
                    nextPage: nil,
                    etag: "\"single-flight-v1\""
                )
            ],
            delay: .milliseconds(30)
        )
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: api,
            now: { now }
        )
        let repo = fixtureRepo(id: 30, name: "single-flight", stars: 20)

        async let ai = repository.refresh(repo: repo, range: .oneYear, forceRefresh: false)
        async let insightsPage = repository.refresh(repo: repo, range: .all, forceRefresh: true)
        let snapshots = try await [ai, insightsPage]

        #expect(Set(snapshots.map(\.range)) == Set([.oneYear, .all]))
        #expect(snapshots[0].remoteState == snapshots[1].remoteState)
        #expect(await api.requests().count == 1)
    }

    @Test("私有仓库无官方公开历史且不调用 API")
    func privateRepositoryNeverCallsAPI() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 6, owner: "octo", name: "private")
        let now = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z"))
        let api = StubGitHubStarHistoryAPI(pages: [:])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: api,
            now: { now }
        )
        var repo = fixtureRepo(id: 6, name: "private", stars: 8)
        repo.isPrivate = true

        let snapshot = try await repository.refresh(
            repo: repo,
            range: .oneYear,
            forceRefresh: true
        )

        #expect(snapshot.remoteState == .privateOnly)
        #expect(snapshot.points.isEmpty)
        #expect(await api.requests().isEmpty)
    }

    @Test("零 Star 仓库忽略旧缓存且不调用官方历史 API")
    func zeroStarRepositoryNeverReadsOrRefreshesHistory() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 7, owner: "octo", name: "zero-star")
        let fetchedAt = try #require(
            ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z")
        )
        let api = StubGitHubStarHistoryAPI(pages: [
            1: .init(
                weeks: [week("2026-07-26", days: [1, 0, 0, 0, 0, 0, 0])],
                nextPage: nil,
                etag: "\"zero-star-v1\""
            )
        ])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: api,
            now: { fetchedAt }
        )
        try await repository.replaceOfficialPoints(
            repoId: 7,
            points: [
                StarHistoryPoint(
                    date: try #require(StarHistoryDateCodec.date(from: "2026-07-26")),
                    count: 1,
                    source: .githubHistory,
                    precision: .reconstructed,
                    fetchedAt: fetchedAt
                )
            ]
        )
        let repo = fixtureRepo(id: 7, name: "zero-star", stars: 0)

        let cached = try await repository.cached(repo: repo, range: .all)
        let refreshed = try await repository.refresh(repo: repo, range: .all, forceRefresh: true)

        #expect(cached.points.isEmpty)
        #expect(refreshed.points.isEmpty)
        #expect(cached.remoteState == .unavailable)
        #expect(refreshed.remoteState == .unavailable)
        #expect(await api.requests().isEmpty)
        // 缓存不删除；未来重新获 Star 时仍可用于 SWR 首帧。
        #expect(try await repository.points(repoId: repo.id).count == 1)
    }

    @Test("个人项目应使用 OAuth 分页读取官方历史")
    func ownerProjectUsesOAuthHistory() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 8, owner: "octo", name: "owned")
        try await insertProject(
            database: database,
            repoID: 8,
            affiliation: .owner,
            permission: .admin,
            authorizationSource: .oauth
        )
        let now = try #require(
            ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z")
        )
        let oauthAPI = StubGitHubStarHistoryAPI(pages: [
            1: .init(
                weeks: [week("2026-07-26", days: [2, 0, 0, 0, 0, 0, 0])],
                nextPage: 2,
                etag: "\"owned-v1\""
            ),
            2: .init(
                weeks: [week("2026-07-19", days: [1, 0, 0, 0, 0, 0, 0])],
                nextPage: nil,
                etag: nil
            )
        ])
        let githubAppAPI = StubGitHubStarHistoryAPI(pages: [:])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            projectRepository: GRDBUserProjectRepository(database: database),
            oauthHistoryAPI: oauthAPI,
            githubAppHistoryAPI: githubAppAPI,
            now: { now }
        )

        let snapshot = try await repository.refresh(
            repo: fixtureRepo(id: 8, name: "owned", stars: 3),
            range: .oneYear,
            forceRefresh: true
        )
        let githubPoints = snapshot.points.filter { $0.source == .githubHistory }

        #expect(snapshot.remoteState == .fresh)
        // 一年视图按 ISO 周压缩远端重建点，每个有事件的周保留最后累计值。
        #expect(githubPoints.map(\.count) == [1, 3])
        #expect(githubPoints.allSatisfy { $0.precision == .reconstructed })
        #expect(await oauthAPI.requestedPages() == [1, 2])
        #expect(await githubAppAPI.requestedPages().isEmpty)
    }

    @Test("已收藏的外部协作仓库应使用 OAuth 读取 GitHub 官方历史")
    func starredCollaboratorUsesOAuthHistory() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 10, owner: "external", name: "shared")
        try await insertProject(
            database: database,
            repoID: 10,
            affiliation: .collaborator,
            // collaborator 关系本身证明可访问；即使权限矩阵缺失也应尝试受限接口。
            permission: .unknown,
            authorizationSource: .oauth
        )
        let now = try #require(
            ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z")
        )
        let oauthAPI = StubGitHubStarHistoryAPI(pages: [
            1: .init(
                weeks: [week("2026-05-31", days: [1, 0, 0, 0, 0, 0, 0]),
                        week("2026-06-28", days: [0, 0, 0, 1, 0, 0, 0])],
                nextPage: nil,
                etag: nil
            )
        ])
        let githubAppAPI = StubGitHubStarHistoryAPI(pages: [:])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            projectRepository: GRDBUserProjectRepository(database: database),
            oauthHistoryAPI: oauthAPI,
            githubAppHistoryAPI: githubAppAPI,
            now: { now }
        )
        var repo = fixtureRepo(id: 10, name: "shared", stars: 2)
        repo.owner = "external"
        repo.fullName = "external/shared"
        repo.isStarred = true
        repo.starredAt = "2026-07-20T00:00:00Z"

        let snapshot = try await repository.refresh(
            repo: repo,
            range: .oneYear,
            forceRefresh: true
        )
        let githubPoints = snapshot.points.filter { $0.source == .githubHistory }

        #expect(snapshot.remoteState == .fresh)
        #expect(githubPoints.map(\.count) == [1, 2])
        #expect(githubPoints.allSatisfy { $0.precision == .reconstructed })
        #expect(await oauthAPI.requestedPages() == [1])
        #expect(await githubAppAPI.requestedPages().isEmpty)
    }

    @Test("私有组织项目应使用 GitHub App 读取官方历史")
    func privateOrganizationProjectUsesGitHubApp() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 9, owner: "acme", name: "private-project")
        try await insertProject(
            database: database,
            repoID: 9,
            affiliation: .organizationMember,
            permission: .pull,
            authorizationSource: .githubApp
        )
        let now = try #require(
            ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z")
        )
        let oauthAPI = StubGitHubStarHistoryAPI(pages: [:])
        let githubAppAPI = StubGitHubStarHistoryAPI(pages: [
            1: .init(
                weeks: [week("2026-05-31", days: [0, 1, 0, 0, 0, 0, 0])],
                nextPage: nil,
                etag: nil
            )
        ])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            projectRepository: GRDBUserProjectRepository(database: database),
            oauthHistoryAPI: oauthAPI,
            githubAppHistoryAPI: githubAppAPI,
            now: { now }
        )
        var repo = fixtureRepo(id: 9, name: "private-project", stars: 1)
        repo.owner = "acme"
        repo.fullName = "acme/private-project"
        repo.isPrivate = true

        let snapshot = try await repository.refresh(
            repo: repo,
            range: .oneYear,
            forceRefresh: true
        )

        #expect(snapshot.remoteState == .fresh)
        #expect(snapshot.points.contains {
            $0.source == .githubHistory && $0.precision == .reconstructed
        })
        #expect(await githubAppAPI.requestedPages() == [1])
        #expect(await oauthAPI.requestedPages().isEmpty)
    }

    @Test("公开 GitHub App 项目在官方历史 403 后回退 OAuth")
    func publicGitHubAppProjectFallsBackToOAuthOnForbidden() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 11, owner: "octo", name: "public-app")
        try await insertProject(
            database: database,
            repoID: 11,
            affiliation: .owner,
            permission: .admin,
            authorizationSource: .githubApp
        )
        let now = try #require(
            ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z")
        )
        let oauthAPI = StubGitHubStarHistoryAPI(pages: [
            1: .init(
                weeks: [week("2026-05-31", days: [0, 1, 0, 0, 0, 0, 0])],
                nextPage: nil,
                etag: nil
            )
        ])
        let githubAppAPI = StubGitHubStarHistoryAPI(
            pages: [:],
            error: NetworkError.clientError(statusCode: 403, message: "forbidden")
        )
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            projectRepository: GRDBUserProjectRepository(database: database),
            oauthHistoryAPI: oauthAPI,
            githubAppHistoryAPI: githubAppAPI,
            now: { now }
        )
        var repo = fixtureRepo(id: 11, name: "public-app", stars: 1)
        repo.isPrivate = false

        let snapshot = try await repository.refresh(
            repo: repo,
            range: .oneYear,
            forceRefresh: true
        )

        #expect(snapshot.remoteState == .fresh)
        #expect(snapshot.points.contains {
            $0.source == .githubHistory && $0.precision == .reconstructed
        })
        #expect(await githubAppAPI.requestedPages() == [1])
        #expect(await oauthAPI.requestedPages() == [1])
    }

    @Test("私有 GitHub App 项目 403 后不回退 OAuth")
    func privateGitHubAppProjectDoesNotFallBackToOAuth() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 12, owner: "acme", name: "private-app")
        try await insertProject(
            database: database,
            repoID: 12,
            affiliation: .organizationMember,
            permission: .pull,
            authorizationSource: .githubApp
        )
        let now = try #require(
            ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z")
        )
        let oauthAPI = StubGitHubStarHistoryAPI(pages: [
            1: .init(
                weeks: [week("2026-05-31", days: [0, 1, 0, 0, 0, 0, 0])],
                nextPage: nil,
                etag: nil
            )
        ])
        let githubAppAPI = StubGitHubStarHistoryAPI(
            pages: [:],
            error: NetworkError.clientError(statusCode: 403, message: "forbidden")
        )
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            projectRepository: GRDBUserProjectRepository(database: database),
            oauthHistoryAPI: oauthAPI,
            githubAppHistoryAPI: githubAppAPI,
            now: { now }
        )
        var repo = fixtureRepo(id: 12, name: "private-app", stars: 1)
        repo.owner = "acme"
        repo.fullName = "acme/private-app"
        repo.isPrivate = true

        let snapshot = try await repository.refresh(
            repo: repo,
            range: .oneYear,
            forceRefresh: true
        )

        #expect(snapshot.remoteState == .privateOnly)
        #expect(!snapshot.points.contains { $0.source == .githubHistory })
        #expect(await githubAppAPI.requestedPages() == [1])
        #expect(await oauthAPI.requestedPages().isEmpty)
    }

    @Test("跨重启缓存过期后应只用第一页 ETag 轻量校验")
    func stalePersistentCacheUsesFirstPageETag() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 31, owner: "octo", name: "etag")
        let firstNow = try #require(
            ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z")
        )
        let initialAPI = StubGitHubStarHistoryAPI(pages: [
            1: .init(
                weeks: [week("2026-07-26", days: [20, 0, 0, 0, 0, 0, 0])],
                nextPage: nil,
                etag: "\"etag-v1\""
            )
        ])
        let repo = fixtureRepo(id: 31, name: "etag", stars: 20)
        let initialRepository = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: initialAPI,
            now: { firstNow }
        )
        _ = try await initialRepository.refresh(repo: repo, range: .oneYear, forceRefresh: true)

        let revalidator = StubGitHubStarHistoryAPI(
            pages: [:],
            notModifiedETag: "\"etag-v1\""
        )
        let reopened = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: revalidator,
            now: { firstNow.addingTimeInterval(2 * 24 * 60 * 60) }
        )
        let snapshot = try await reopened.refresh(
            repo: repo,
            range: .oneYear,
            forceRefresh: false
        )
        let requests = await revalidator.requests()

        #expect(snapshot.remoteState == .notModified)
        #expect(requests.count == 1)
        #expect(requests.first?.page == 1)
        #expect(requests.first?.ifNoneMatch == "\"etag-v1\"")
        #expect(snapshot.points.contains { $0.source == .githubHistory })
    }

    @Test("24 小时内的持久化周缓存应跨重启直接命中")
    func freshPersistentCacheSkipsNetworkAfterReopen() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 32, owner: "octo", name: "fresh-cache")
        let firstNow = try #require(
            ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z")
        )
        let initialAPI = StubGitHubStarHistoryAPI(pages: [
            1: .init(
                weeks: [week("2026-07-26", days: [20, 0, 0, 0, 0, 0, 0])],
                nextPage: nil,
                etag: "\"fresh-v1\""
            )
        ])
        let repo = fixtureRepo(id: 32, name: "fresh-cache", stars: 20)
        let initialRepository = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: initialAPI,
            now: { firstNow }
        )
        _ = try await initialRepository.refresh(repo: repo, range: .oneYear, forceRefresh: true)

        // 新 Repository 实例确保本次命中来自 SQLite，不是 actor 内存状态。
        let unreachableAPI = StubGitHubStarHistoryAPI(
            pages: [:],
            error: NetworkError.serverError(statusCode: 503)
        )
        let reopened = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: unreachableAPI,
            now: { firstNow.addingTimeInterval(60 * 60) }
        )
        let snapshot = try await reopened.refresh(
            repo: repo,
            range: .oneYear,
            forceRefresh: false
        )

        #expect(snapshot.remoteState == .cached)
        #expect(snapshot.points.contains { $0.source == .githubHistory && $0.count == 20 })
        #expect(await unreachableAPI.requests().isEmpty)
    }

    @Test("远端失败应保留官方历史缓存")
    func remoteFailurePreservesStaleCacheAndETag() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 7, owner: "octo", name: "stale")
        let now = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z"))
        let api = StubGitHubStarHistoryAPI(pages: [
            1: .init(
                weeks: [week("2026-07-26", days: [20, 0, 0, 0, 0, 0, 0])],
                nextPage: nil,
                etag: "\"stale-v1\""
            )
        ])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: api,
            now: { now }
        )
        let repo = fixtureRepo(id: 7, name: "stale", stars: 20)

        _ = try await repository.refresh(repo: repo, range: .oneYear, forceRefresh: true)
        let failingAPI = StubGitHubStarHistoryAPI(pages: [:], error: NetworkError.serverError(statusCode: 503))
        let reopened = GRDBRepoStarHistoryRepository(
            database: database,
            oauthHistoryAPI: failingAPI,
            now: { now.addingTimeInterval(2 * 24 * 60 * 60) }
        )
        let stale = try await reopened.refresh(repo: repo, range: .oneYear, forceRefresh: true)

        #expect(stale.remoteState == .stale(.providerUnavailable))
        #expect(stale.points.contains { $0.source == .githubHistory && $0.count == 20 })
        #expect(await failingAPI.requests().count == 1)
    }

    private func week(_ sunday: String, days: [Int]) -> GitHubStarHistoryWeekDTO {
        let date = StarHistoryDateCodec.date(from: sunday)!
        return GitHubStarHistoryWeekDTO(
            week: Int64(date.timeIntervalSince1970),
            total: days.reduce(0, +),
            days: days
        )
    }

    private func point(
        _ day: String,
        _ count: Int,
        _ source: StarHistorySource,
        _ precision: StarHistoryPrecision,
        _ fetchedAt: Date
    ) -> StarHistoryPoint {
        StarHistoryPoint(
            date: StarHistoryDateCodec.date(from: day)!,
            count: count,
            source: source,
            precision: precision,
            fetchedAt: fetchedAt
        )
    }

    private func makeStarredDTO(id: Int64, stars: Int) -> StarredRepoDTO {
        let owner = GitHubUserDTO(
            id: 1,
            login: "octo",
            name: nil,
            avatarUrl: nil,
            publicRepos: nil,
            followers: nil,
            following: nil,
            bio: nil,
            company: nil,
            location: nil,
            email: nil,
            blog: nil,
            twitterUsername: nil,
            htmlUrl: nil
        )
        let repo = GitHubRepoDTO(
            id: id,
            name: "history",
            fullName: "octo/history",
            owner: owner,
            description: nil,
            language: "Swift",
            stargazersCount: stars,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/octo/history",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            openIssuesCount: nil,
            defaultBranch: "main",
            disabled: nil,
            isTemplate: nil,
            score: nil
        )
        return StarredRepoDTO(starredAt: "2026-07-27T11:00:00Z", repo: repo)
    }

    private func fixtureRepo(id: Int64, name: String, stars: Int) -> Repo {
        var repo = Repo.makeMinimal(owner: "octo", name: name)
        repo.id = id
        repo.starsCount = stars
        repo.cachedAt = "2026-07-27T00:00:00Z"
        return repo
    }

    private func insertProject(
        database: InMemoryDatabaseManager,
        repoID: Int64,
        affiliation: ProjectAffiliation,
        permission: ProjectPermission,
        authorizationSource: ProjectAuthorizationSource
    ) async throws {
        try await database.writer.write { db in
            let relationship = switch affiliation {
            case .owner:
                (ownerLogin: "octo", ownerType: ProjectOwnerType.user, visibility: ProjectVisibility.public)
            case .organizationMember:
                (ownerLogin: "acme", ownerType: ProjectOwnerType.organization, visibility: ProjectVisibility.private)
            case .collaborator:
                (ownerLogin: "external", ownerType: ProjectOwnerType.user, visibility: ProjectVisibility.public)
            }
            var project = UserProject(
                userId: 100,
                repoId: repoID,
                affiliation: affiliation,
                ownerLogin: relationship.ownerLogin,
                ownerType: relationship.ownerType,
                visibility: relationship.visibility,
                permission: permission,
                authorizationSource: authorizationSource,
                installationId: authorizationSource == .githubApp ? 42 : nil,
                generation: "test-generation",
                lastSeenAt: "2026-07-27T00:00:00.000Z",
                createdAt: "2026-07-27T00:00:00.000Z",
                updatedAt: "2026-07-27T00:00:00.000Z"
            )
            try project.save(db)
        }
    }
}

private actor StubGitHubStarHistoryAPI: GitHubStarHistoryAPIProtocol {
    struct Page: Sendable {
        let weeks: [GitHubStarHistoryWeekDTO]
        let nextPage: Int?
        let etag: String?
    }

    private let pages: [Int: Page]
    private let error: NetworkError?
    private let notModifiedETag: String?
    private let delay: Duration
    private var recordedRequests: [(page: Int, ifNoneMatch: String?)] = []

    init(
        pages: [Int: Page],
        error: NetworkError? = nil,
        notModifiedETag: String? = nil,
        delay: Duration = .zero
    ) {
        self.pages = pages
        self.error = error
        self.notModifiedETag = notModifiedETag
        self.delay = delay
    }

    func starHistory(
        owner: String,
        repo: String,
        page: Int,
        perPage: Int,
        ifNoneMatch: String?
    ) async throws -> APIResponse<[GitHubStarHistoryWeekDTO]> {
        recordedRequests.append((page, ifNoneMatch))
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if ifNoneMatch != nil, let notModifiedETag {
            throw NetworkError.notModified(etag: notModifiedETag)
        }
        if let error {
            throw error
        }
        guard let result = pages[page] else {
            throw NetworkError.serverError(statusCode: 503)
        }
        return APIResponse(
            value: result.weeks,
            linkHeader: LinkHeader(nextPage: result.nextPage, lastPage: nil),
            rateLimit: RateLimitInfo(limit: nil, remaining: nil, reset: nil),
            statusCode: 200,
            etag: result.etag
        )
    }

    func requestedPages() -> [Int] {
        recordedRequests.map(\.page)
    }

    func requests() -> [(page: Int, ifNoneMatch: String?)] {
        recordedRequests
    }
}
