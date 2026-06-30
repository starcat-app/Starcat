//
//  ReadmePrefetchServiceTests.swift
//  StarcatTests
//
//  README 后台预拉服务的行为级测试。
//
//  本套测试使用真实内存 SQLite + MockGitHubAPIClient，覆盖预拉服务最关键的三条约束：
//  - 缺缓存时补齐 HTML 与 raw Markdown；
//  - 新鲜 HTML 不重复请求，只补缺失 Markdown；
//  - GitHub rate limit 会进入冷却并停止本轮，避免后台任务抢占配额。
//  - 候选查询这类底层错误不会把 SQL / GRDB 细节暴露给用户态状态。
//

import Foundation
import Testing
@testable import Starcat

@Suite("README 后台预拉服务")
@MainActor
struct ReadmePrefetchServiceTests {

    @Test("缺缓存时补齐 HTML 和 Markdown")
    func runBatchFillsHTMLAndMarkdown() async throws {
        let sut = try await makeSUT()
        try await sut.db.insertRepoFixture(id: 1, owner: "alice", name: "foo")

        sut.api.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.ok(data: Data("<h1>README</h1>".utf8), etag: "\"html\"")
        }
        sut.api.readmeMarkdownHandler = { _, _, _, _ in
            BytesResponse.ok(data: Data("# README".utf8), etag: "\"md\"")
        }

        let processed = await sut.service.runBatch(limit: 1, delayBetweenRepos: 0)

        #expect(processed == 1)
        #expect(sut.api.readmeHTMLCalls.count == 1)
        #expect(sut.api.readmeMarkdownCalls.count == 1)
        #expect(try await sut.readmeRepository.find(repoId: 1)?.renderedHtml == "<h1>README</h1>")
        #expect(try await sut.readmeRepository.findContent(repoId: 1) == "# README")

        let state = try await sut.prefetchRepository.state(repoId: 1)
        #expect(state?.htmlStatus == .succeeded)
        #expect(state?.markdownStatus == .succeeded)
        #expect(state?.nextRetryAt == nil)
    }

    @Test("已有新鲜 HTML 时只补 Markdown")
    func freshHTMLOnlyFillsMarkdown() async throws {
        let sut = try await makeSUT()
        try await sut.db.insertRepoFixture(id: 2, owner: "alice", name: "bar")
        try await sut.readmeRepository.upsert(Readme(
            repoId: 2,
            renderedHtml: "<p>cached</p>",
            etag: "\"html\"",
            lastModified: nil,
            cachedAt: ISO8601DateFormatter.shared.string(from: Date()),
            size: "<p>cached</p>".utf8.count
        ))

        sut.api.readmeMarkdownHandler = { _, _, _, _ in
            BytesResponse.ok(data: Data("# cached".utf8), etag: "\"md\"")
        }

        let processed = await sut.service.runBatch(limit: 1, delayBetweenRepos: 0)

        #expect(processed == 1)
        #expect(sut.api.readmeHTMLCalls.isEmpty)
        #expect(sut.api.readmeMarkdownCalls.count == 1)
        #expect(try await sut.readmeRepository.findContent(repoId: 2) == "# cached")

        let state = try await sut.prefetchRepository.state(repoId: 2)
        #expect(state?.htmlStatus == .skipped)
        #expect(state?.markdownStatus == .succeeded)
    }

    @Test("Rate limit 进入冷却并停止本轮")
    func rateLimitCoolsDownAndStopsBatch() async throws {
        let sut = try await makeSUT()
        try await sut.db.insertRepoFixture(id: 3, owner: "alice", name: "rate", starredAt: "2026-05-31T00:00:00Z")
        try await sut.db.insertRepoFixture(id: 4, owner: "alice", name: "later", starredAt: "2026-05-30T00:00:00Z")

        sut.api.readmeHTMLHandler = { _, _, _, _ in
            throw NetworkError.rateLimited(retryAfter: 120)
        }

        let processed = await sut.service.runBatch(limit: 2, delayBetweenRepos: 0)

        #expect(processed == 1)
        #expect(sut.api.readmeHTMLCalls.count == 1)
        #expect(sut.api.readmeMarkdownCalls.isEmpty)
        guard case .coolingDown(let until) = sut.service.status else {
            Issue.record("期望进入 coolingDown，实际: \(sut.service.status)")
            return
        }
        #expect(until > Date())

        let state = try await sut.prefetchRepository.state(repoId: 3)
        #expect(state?.htmlStatus == .failed)
        #expect(state?.markdownStatus == .skipped)
        #expect(state?.lastErrorKind == "rateLimited")
        #expect(state?.nextRetryAt != nil)
    }

    @Test("候选查询失败进入安全重试状态且不保留 SQL 文本")
    func candidateQueryFailureUsesSafeRetryState() async throws {
        let sut = try await makeSUT()
        try await sut.db.insertRepoFixture(id: 5, owner: "alice", name: "schema")
        try await sut.db.writer.write { db in
            try db.execute(sql: "DROP TABLE readme_prefetch_states")
        }

        let processed = await sut.service.runBatch(limit: 1, delayBetweenRepos: 0)

        #expect(processed == 0)
        #expect(sut.api.readmeHTMLCalls.isEmpty)
        #expect(sut.api.readmeMarkdownCalls.isEmpty)
        #expect(sut.service.status == .waitingForRetry)
        #expect(sut.service.lastFailureKind?.contains("SELECT") == false)
        #expect(sut.service.lastFailureKind?.contains("readme_prefetch_states") == false)
    }

    @Test("全部 Star 仓库已有 README 缓存时显示已全部拉取")
    func allPrefetchedWhenCoverageMatchesStarredTotal() async throws {
        let sut = try await makeSUT()
        try await sut.db.insertRepoFixture(id: 6, owner: "alice", name: "done-a")
        try await sut.db.insertRepoFixture(id: 7, owner: "alice", name: "done-b")

        for id in [Int64(6), Int64(7)] {
            try await sut.readmeRepository.upsert(Readme(
                repoId: id,
                renderedHtml: "<p>cached-\(id)</p>",
                etag: "\"html-\(id)\"",
                lastModified: nil,
                cachedAt: ISO8601DateFormatter.shared.string(from: Date()),
                size: "<p>cached-\(id)</p>".utf8.count
            ))
            try await sut.readmeRepository.upsertContent(
                repoId: id,
                content: "# cached-\(id)",
                at: Date()
            )
        }

        let processed = await sut.service.runBatch(limit: 10, delayBetweenRepos: 0)

        #expect(processed == 0)
        #expect(sut.api.readmeHTMLCalls.isEmpty)
        #expect(sut.api.readmeMarkdownCalls.isEmpty)
        #expect(sut.service.status == .allPrefetched(total: 2))
        #expect(sut.service.processed == 2)
        #expect(sut.service.total == 2)
    }

    @Test("手动触发会绕过 retry 冷却处理剩余缺失仓库")
    func manualBatchBypassesRetryCooldown() async throws {
        let sut = try await makeSUT()
        try await sut.db.insertRepoFixture(id: 8, owner: "alice", name: "retrying")
        try await sut.prefetchRepository.upsert(ReadmePrefetchStateRecord(
            repoId: 8,
            htmlStatus: .failed,
            markdownStatus: .skipped,
            lastAttemptAt: ISO8601DateFormatter.shared.string(from: Date()),
            nextRetryAt: ISO8601DateFormatter.shared.string(from: Date().addingTimeInterval(60 * 60)),
            failureCount: 1,
            lastErrorKind: "transport"
        ))

        sut.api.readmeHTMLHandler = { _, _, _, _ in
            BytesResponse.ok(data: Data("<h1>retrying</h1>".utf8), etag: "\"html-retrying\"")
        }
        sut.api.readmeMarkdownHandler = { _, _, _, _ in
            BytesResponse.ok(data: Data("# retrying".utf8), etag: "\"md-retrying\"")
        }

        let automaticProcessed = await sut.service.runBatch(limit: 1, delayBetweenRepos: 0)
        #expect(automaticProcessed == 0)
        #expect(sut.api.readmeHTMLCalls.isEmpty)
        #expect(sut.service.status == .completed(processed: 0, total: 1))

        let manualProcessed = await sut.service.runBatch(
            limit: 1,
            delayBetweenRepos: 0,
            respectRetryCooldown: false
        )

        #expect(manualProcessed == 1)
        #expect(sut.api.readmeHTMLCalls.count == 1)
        #expect(sut.api.readmeMarkdownCalls.count == 1)
        #expect(try await sut.readmeRepository.find(repoId: 8)?.renderedHtml == "<h1>retrying</h1>")
        #expect(try await sut.readmeRepository.findContent(repoId: 8) == "# retrying")

        let state = try await sut.prefetchRepository.state(repoId: 8)
        #expect(state?.htmlStatus == .succeeded)
        #expect(state?.markdownStatus == .succeeded)
        #expect(state?.nextRetryAt == nil)
    }

    private func makeSUT() async throws -> (
        service: ReadmePrefetchService,
        prefetchRepository: ReadmePrefetchRepository,
        readmeRepository: ReadmeRepository,
        api: MockGitHubAPIClient,
        db: any DatabaseManaging
    ) {
        let db = try InMemoryDatabaseManager()
        let readmeRepository = ReadmeRepository(database: db)
        let prefetchRepository = ReadmePrefetchRepository(database: db)
        let api = MockGitHubAPIClient()
        let readmeAPI = ReadmeAPI(
            client: api,
            repository: readmeRepository,
            trendingRepository: TrendingReadmeRepository(database: db),
            inflightTracker: ReadmeInflightTracker(),
            metrics: ReadmeMetrics()
        )
        let service = ReadmePrefetchService(
            repository: prefetchRepository,
            readmeRepository: readmeRepository,
            readmeAPI: readmeAPI
        )
        return (service, prefetchRepository, readmeRepository, api, db)
    }
}
