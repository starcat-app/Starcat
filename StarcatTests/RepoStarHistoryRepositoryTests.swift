//
//  RepoStarHistoryRepositoryTests.swift
//  StarcatTests
//
//  验证本机 Star 精确快照的 UTC 日幂等、远端替换隔离和 repo 生命周期。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Repo Star History Repository")
struct RepoStarHistoryRepositoryTests {

    @Test("同一 UTC 日期的本机快照应幂等更新")
    func localSnapshotIsIdempotentPerUTCDay() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1, owner: "octo", name: "history")
        let repository = GRDBRepoStarHistoryRepository(database: database)
        let first = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T01:00:00.000Z"))
        let second = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T23:30:00.000Z"))

        try await repository.recordLocalSnapshot(
            repoId: 1,
            starsCount: 10,
            observedAt: first,
            fetchedAt: first
        )
        try await repository.recordLocalSnapshot(
            repoId: 1,
            starsCount: 12,
            observedAt: second,
            fetchedAt: second
        )

        let points = try await repository.points(repoId: 1)
        #expect(points.count == 1)
        #expect(points[0].count == 12)
        #expect(points[0].source == .localSnapshot)
        #expect(points[0].precision == .snapshot)
        #expect(StarHistoryDateCodec.dayString(from: points[0].date) == "2026-07-27")
        #expect(points[0].fetchedAt == second)
    }

    @Test("替换远端点不得删除本机精确快照")
    func remoteReplacementPreservesLocalSnapshot() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 2, owner: "octo", name: "merged")
        let repository = GRDBRepoStarHistoryRepository(database: database)
        let fetchedAt = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T08:00:00.000Z"))
        let localDate = try #require(StarHistoryDateCodec.date(from: "2026-07-27"))

        try await repository.recordLocalSnapshot(
            repoId: 2,
            starsCount: 100,
            observedAt: localDate,
            fetchedAt: fetchedAt
        )
        try await repository.replaceRemotePoints(repoId: 2, points: [
            point("2026-07-25", 80, .ghArchive, .estimated, fetchedAt),
            point("2026-07-26", 95, .discoverySnapshot, .snapshot, fetchedAt)
        ])
        try await repository.replaceRemotePoints(repoId: 2, points: [
            point("2026-07-26", 96, .ghArchive, .estimated, fetchedAt)
        ])

        let points = try await repository.points(repoId: 2)
        #expect(points.count == 2)
        #expect(points.contains { $0.source == .localSnapshot && $0.count == 100 })
        #expect(points.contains { $0.source == .ghArchive && $0.count == 96 })
        #expect(!points.contains { $0.source == .discoverySnapshot })
    }

    @Test("批量同步与单仓 metadata 更新应复用当天精确点")
    func repoMetadataWritesLocalSnapshotWithoutExtraFetch() async throws {
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
        #expect(points.count == 1)
        #expect(points[0].count == 15)
        #expect(points[0].source == .localSnapshot)
    }

    @Test("删除 repo 应由外键级联清理全部历史点")
    func deletingRepoCascadesHistory() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 4, owner: "octo", name: "deleted")
        let repository = GRDBRepoStarHistoryRepository(database: database)
        let now = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z"))
        try await repository.recordLocalSnapshot(
            repoId: 4,
            starsCount: 5,
            observedAt: now,
            fetchedAt: now
        )

        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM repos WHERE id = 4")
        }

        #expect(try await repository.points(repoId: 4).isEmpty)
    }

    @Test("同日精确快照应覆盖 GH Archive 估算")
    func exactSnapshotWinsSameDayEstimate() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 5, owner: "octo", name: "priority")
        let now = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z"))
        let api = StubStarHistoryAPI(results: [
            .success(.ready(
                series: StarHistoryRemoteSeries(
                    repoID: 5,
                    fullName: "octo/priority",
                    currentStars: 120,
                    range: .oneYear,
                    coverageStart: StarHistoryDateCodec.date(from: "2026-07-26"),
                    generatedAt: now,
                    points: [
                        point("2026-07-26", 100, .ghArchive, .estimated, now),
                        point("2026-07-27", 118, .ghArchive, .estimated, now)
                    ]
                ),
                etag: "\"priority-v1\""
            ))
        ])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            api: api,
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
        #expect(snapshot.points.last?.source == .localSnapshot)
        #expect(snapshot.points.last?.precision == .snapshot)
    }

    @Test("AI 与洞察页并发刷新同一 Star 范围只请求一次")
    func concurrentConsumersShareStarHistoryRefresh() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 30, owner: "octo", name: "single-flight")
        let now = try #require(
            ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z")
        )
        let api = StubStarHistoryAPI(
            results: [
                .success(.ready(
                    series: StarHistoryRemoteSeries(
                        repoID: 30,
                        fullName: "octo/single-flight",
                        currentStars: 20,
                        range: .oneYear,
                        coverageStart: StarHistoryDateCodec.date(from: "2026-07-01"),
                        generatedAt: now,
                        points: [
                            point("2026-07-01", 10, .ghArchive, .estimated, now)
                        ]
                    ),
                    etag: "\"single-flight-v1\""
                ))
            ],
            delay: .milliseconds(30)
        )
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            api: api,
            now: { now }
        )
        let repo = fixtureRepo(id: 30, name: "single-flight", stars: 20)

        async let ai = repository.refresh(repo: repo, range: .oneYear, forceRefresh: false)
        async let insightsPage = repository.refresh(
            repo: repo,
            range: .oneYear,
            forceRefresh: true
        )
        let snapshots = try await [ai, insightsPage]

        #expect(snapshots[0] == snapshots[1])
        #expect(await api.requests().count == 1)
    }

    @Test("私有仓库只返回本机快照且不调用 API")
    func privateRepositoryNeverCallsAPI() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 6, owner: "octo", name: "private")
        let now = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z"))
        let api = StubStarHistoryAPI(results: [])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            api: api,
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
        #expect(snapshot.points.count == 1)
        #expect(snapshot.points.first?.source == .localSnapshot)
        #expect(await api.requests().isEmpty)
    }

    @Test("个人项目应使用 OAuth 分页重建当前 Stargazers 历史")
    func ownerProjectUsesOAuthStargazersHistory() async throws {
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
        let discoveryAPI = StubStarHistoryAPI(results: [])
        let oauthAPI = StubGitHubStargazersAPI(pages: [
            1: .init(
                starredAt: [
                    "2026-07-01T01:00:00Z",
                    "2026-07-01T10:00:00Z"
                ],
                nextPage: 2
            ),
            2: .init(
                starredAt: ["2026-07-02T03:00:00Z"],
                nextPage: nil
            )
        ])
        let githubAppAPI = StubGitHubStargazersAPI(pages: [:])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            api: discoveryAPI,
            projectRepository: GRDBUserProjectRepository(database: database),
            oauthStargazersAPI: oauthAPI,
            githubAppStargazersAPI: githubAppAPI,
            now: { now }
        )

        let snapshot = try await repository.refresh(
            repo: fixtureRepo(id: 8, name: "owned", stars: 3),
            range: .oneYear,
            forceRefresh: true
        )
        let githubPoints = snapshot.points.filter { $0.source == .githubStargazers }

        #expect(snapshot.remoteState == .fresh)
        #expect(githubPoints.map(\.count) == [2, 3])
        #expect(githubPoints.allSatisfy { $0.precision == .reconstructed })
        #expect(await oauthAPI.requestedPages() == [1, 2])
        #expect(await githubAppAPI.requestedPages().isEmpty)
        #expect(await discoveryAPI.requests().isEmpty)
    }

    @Test("已收藏的外部协作仓库应使用 OAuth Stargazers 且不得调用 Discovery")
    func starredCollaboratorUsesOAuthStargazersHistory() async throws {
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
        let discoveryAPI = StubStarHistoryAPI(results: [])
        let oauthAPI = StubGitHubStargazersAPI(pages: [
            1: .init(
                starredAt: [
                    "2026-06-01T01:00:00Z",
                    "2026-07-01T01:00:00Z"
                ],
                nextPage: nil
            )
        ])
        let githubAppAPI = StubGitHubStargazersAPI(pages: [:])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            api: discoveryAPI,
            projectRepository: GRDBUserProjectRepository(database: database),
            oauthStargazersAPI: oauthAPI,
            githubAppStargazersAPI: githubAppAPI,
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
        let githubPoints = snapshot.points.filter { $0.source == .githubStargazers }

        #expect(snapshot.remoteState == .fresh)
        #expect(githubPoints.map(\.count) == [1, 2])
        #expect(githubPoints.allSatisfy { $0.precision == .reconstructed })
        #expect(await oauthAPI.requestedPages() == [1])
        #expect(await githubAppAPI.requestedPages().isEmpty)
        #expect(await discoveryAPI.requests().isEmpty)
    }

    @Test("私有组织项目应使用 GitHub App 且不得调用公共 Discovery")
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
        let discoveryAPI = StubStarHistoryAPI(results: [])
        let oauthAPI = StubGitHubStargazersAPI(pages: [:])
        let githubAppAPI = StubGitHubStargazersAPI(pages: [
            1: .init(
                starredAt: ["2026-06-01T01:00:00Z"],
                nextPage: nil
            )
        ])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            api: discoveryAPI,
            projectRepository: GRDBUserProjectRepository(database: database),
            oauthStargazersAPI: oauthAPI,
            githubAppStargazersAPI: githubAppAPI,
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
            $0.source == .githubStargazers && $0.precision == .reconstructed
        })
        #expect(await githubAppAPI.requestedPages() == [1])
        #expect(await oauthAPI.requestedPages().isEmpty)
        #expect(await discoveryAPI.requests().isEmpty)
    }

    @Test("远端失败应保留陈旧缓存并复用 ETag")
    func remoteFailurePreservesStaleCacheAndETag() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 7, owner: "octo", name: "stale")
        let now = try #require(ISO8601DateFormatter.shared.date(from: "2026-07-27T12:00:00.000Z"))
        let api = StubStarHistoryAPI(results: [
            .success(.ready(
                series: StarHistoryRemoteSeries(
                    repoID: 7,
                    fullName: "octo/stale",
                    currentStars: 20,
                    range: .oneYear,
                    coverageStart: StarHistoryDateCodec.date(from: "2026-07-26"),
                    generatedAt: now,
                    points: [point("2026-07-26", 10, .ghArchive, .estimated, now)]
                ),
                etag: "\"stale-v1\""
            )),
            .failure(.providerUnavailable)
        ])
        let repository = GRDBRepoStarHistoryRepository(
            database: database,
            api: api,
            now: { now }
        )
        let repo = fixtureRepo(id: 7, name: "stale", stars: 20)

        _ = try await repository.refresh(repo: repo, range: .oneYear, forceRefresh: true)
        let stale = try await repository.refresh(repo: repo, range: .oneYear, forceRefresh: true)
        let requests = await api.requests()

        #expect(stale.remoteState == .stale(.providerUnavailable))
        #expect(stale.points.map(\.count) == [10, 20])
        #expect(requests.count == 2)
        #expect(requests.last?.ifNoneMatch == "\"stale-v1\"")
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

private actor StubGitHubStargazersAPI: GitHubStargazersAPIProtocol {
    struct Page: Sendable {
        let starredAt: [String]
        let nextPage: Int?
    }

    private let pages: [Int: Page]
    private var recordedPages: [Int] = []

    init(pages: [Int: Page]) {
        self.pages = pages
    }

    func stargazers(
        owner: String,
        repo: String,
        page: Int,
        perPage: Int
    ) async throws -> APIResponse<[GitHubStargazerDTO]> {
        recordedPages.append(page)
        guard let result = pages[page] else {
            throw StarHistoryAPIError.providerUnavailable
        }
        return APIResponse(
            value: result.starredAt.map(GitHubStargazerDTO.init(starredAt:)),
            linkHeader: LinkHeader(nextPage: result.nextPage, lastPage: nil),
            rateLimit: RateLimitInfo(limit: nil, remaining: nil, reset: nil),
            statusCode: 200,
            etag: nil
        )
    }

    func requestedPages() -> [Int] {
        recordedPages
    }
}

private actor StubStarHistoryAPI: StarHistoryAPIProtocol {
    struct RecordedRequest: Sendable {
        let request: StarHistoryRequest
        let range: StarHistoryRange
        let ifNoneMatch: String?
    }

    private var queuedResults: [Result<StarHistoryAPIResult, StarHistoryAPIError>]
    private var recordedRequests: [RecordedRequest] = []
    private let delay: Duration

    init(
        results: [Result<StarHistoryAPIResult, StarHistoryAPIError>],
        delay: Duration = .zero
    ) {
        queuedResults = results
        self.delay = delay
    }

    func fetch(
        request: StarHistoryRequest,
        range: StarHistoryRange,
        ifNoneMatch: String?
    ) async throws -> StarHistoryAPIResult {
        recordedRequests.append(
            RecordedRequest(request: request, range: range, ifNoneMatch: ifNoneMatch)
        )
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        guard !queuedResults.isEmpty else {
            throw StarHistoryAPIError.providerUnavailable
        }
        return try queuedResults.removeFirst().get()
    }

    func requests() -> [RecordedRequest] {
        recordedRequests
    }
}
