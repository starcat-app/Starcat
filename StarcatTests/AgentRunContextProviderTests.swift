//
//  AgentRunContextProviderTests.swift
//  StarcatTests
//
//  验证 Agent 业务上下文与 Star / Knowledge RAG 准入边界已经解耦：Weekly 默认
//  使用 Weekly 数据源，手选仓库可来自任意本地已知来源，知识库只提供可检索证据子集。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentRunContextProvider")
struct AgentRunContextProviderTests {

    @Test("Agent 统一目录包含本地非 Star 仓库")
    func catalogIncludesLocalUnstarredRepository() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 9)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_starred = 0, starred_at = NULL WHERE id = 9")
        }

        let candidates = try await GRDBAgentRepositoryCatalog(database: database).candidates()
        let candidate = try #require(candidates.first(where: { $0.id == 9 }))

        #expect(candidate.sources.contains(.local))
        #expect(!candidate.sources.contains(.starred))
        #expect(candidate.snapshot.isStarred == false)
    }

    @Test("Weekly 未手选仓库时自动冻结最近 7 天 Weekly 项目")
    func weeklyUsesWeeklyFeedByDefault() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .only, repoIDs: [])
        )

        #expect(context.failureReason == nil)
        #expect(context.repos.map(\.id) == [1, 2])
        #expect(context.repos.map(\.isStarred) == [true, false])
        #expect(context.knowledgeEligibleRepoIDs == [1])
    }

    @Test("Weekly only 可用非 Star 项目覆盖自动时间窗")
    func weeklyOnlyAcceptsUnstarredRepository() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .only, repoIDs: [3])
        )

        #expect(context.failureReason == nil)
        #expect(context.repos.map(\.id) == [3])
        #expect(context.repos.first?.isStarred == false)
        #expect(context.knowledgeEligibleRepoIDs == [])
    }

    @Test("Weekly prefer 将手选项目置顶后补最近 7 天 Weekly 项目")
    func weeklyPreferPinsOverrideBeforeWeeklyFeed() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .prefer, repoIDs: [3])
        )

        #expect(context.repos.map(\.id) == [3, 1, 2])
    }

    @Test("Weekly exclude 只从 Weekly 默认上下文排除手选项目")
    func weeklyExcludeRemovesWeeklyRepository() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .exclude, repoIDs: [2])
        )

        #expect(context.repos.map(\.id) == [1])
    }

    @Test("Weekly 最近 7 天没有采集项目时仍返回合法空上下文")
    func weeklyAllowsEmptyRecentWindow() async throws {
        let fixture = try await makeFixture(now: "2026-09-04T12:00:00Z")
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .only, repoIDs: [])
        )

        #expect(context.failureReason == nil)
        #expect(context.repos.isEmpty)
        #expect(context.knowledgeEligibleRepoIDs == [])
    }

    @Test("Repo Insight 可选择非 Star 且未进入知识库的项目")
    func repoInsightAcceptsUnstarredRepository() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.repoInsight,
            input: input(mode: .only, repoIDs: [3])
        )

        #expect(context.failureReason == nil)
        #expect(context.repos.map(\.id) == [3])
        #expect(context.knowledgeEligibleRepoIDs == [])
    }

    @Test("Repo Insight 拒绝多个目标仓库")
    func repoInsightRejectsMultipleRepositories() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.repoInsight,
            input: input(mode: .only, repoIDs: [1, 2])
        )

        #expect(context.repos.isEmpty)
        #expect(context.failureReason == String.l10n("agent.loop.error.contextUnavailable"))
    }

    @Test("Agent 选择器把 Star 和来源当筛选维度而不是准入条件")
    func pickerFiltersAcrossAllKnownRepositories() {
        let candidates = [
            candidate(id: 1, isStarred: true, sources: [.local, .starred, .weekly], latest: "2026-08-04T10:00:00Z"),
            candidate(id: 2, isStarred: false, sources: [.weekly], latest: "2026-08-03T10:00:00Z"),
            candidate(id: 3, isStarred: false, sources: [.discovery], latest: "2026-08-02T10:00:00Z"),
            candidate(id: 4, isStarred: false, sources: [.local], latest: "2026-08-01T10:00:00Z")
        ]
        var filters = RAGComposerMentionFilters.empty
        filters.star = .unstarred

        let unstarred = AgentRepositoryPickerLogic.build(
            candidates: candidates,
            selected: [],
            query: "",
            filters: filters,
            selectedSources: [],
            sort: .updatedDesc
        )
        let weeklyAndDiscovery = AgentRepositoryPickerLogic.build(
            candidates: candidates,
            selected: [],
            query: "",
            filters: .empty,
            selectedSources: [.weekly, .discovery],
            sort: .updatedDesc
        )

        #expect(unstarred.suggestions.map(\.id) == [2, 3, 4])
        #expect(weeklyAndDiscovery.suggestions.map(\.id) == [1, 2, 3])
        #expect(weeklyAndDiscovery.totalCount == 4)
    }

    @Test("Agent 选择器在搜索和筛选后仍固定展示已选项目")
    func pickerPinsSelectedRepositoryOutsideCurrentFilter() {
        let selectedCandidate = candidate(
            id: 3,
            isStarred: false,
            sources: [.discovery],
            latest: "2026-08-02T10:00:00Z"
        )
        let snapshot = AgentRepositoryPickerLogic.build(
            candidates: [selectedCandidate],
            selected: [AIComposerRepoReference(
                id: 3,
                owner: "octo",
                name: "demo-3",
                fullName: "octo/demo-3",
                language: "Swift",
                starsCount: 50
            )],
            query: "does-not-match",
            filters: .empty,
            selectedSources: [.weekly],
            sort: .updatedDesc
        )

        #expect(snapshot.suggestions.map(\.id) == [3])
        #expect(snapshot.matchCount == 0)
    }

    private func makeFixture(
        now nowValue: String = "2026-08-04T12:00:00Z"
    ) async throws -> (
        provider: RepositoryAgentRunContextProvider,
        database: InMemoryDatabaseManager
    ) {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1, starredAt: "2026-08-04T10:00:00Z")
        try await database.insertRepoFixture(id: 2, starredAt: "2026-07-30T10:00:00Z")
        try await database.insertRepoFixture(id: 3, starredAt: "2026-07-20T10:00:00Z")
        let notes = GRDBRepoNoteRepository(database: database)
        try await notes.updateLibraryState(repoId: 1, state: .inLibrary)
        let fixedNow = ISO8601DateFormatter().date(from: nowValue)!
        let catalog = FixedAgentRepositoryCatalog(candidates: [
            candidate(id: 1, isStarred: true, sources: [.local, .starred, .knowledge, .weekly], latest: "2026-08-04T10:00:00Z"),
            candidate(id: 2, isStarred: false, sources: [.weekly], latest: "2026-07-30T10:00:00Z"),
            candidate(id: 3, isStarred: false, sources: [.discovery], latest: "2026-08-03T10:00:00Z")
        ])
        return (
            RepositoryAgentRunContextProvider(
                repoRepository: GRDBRepoRepository(database: database),
                repositoryCatalog: catalog,
                candidateLimit: 30,
                now: { fixedNow }
            ),
            database
        )
    }

    private func input(
        mode: AIComposerExplicitRepoMode,
        repoIDs: [Int64]
    ) -> AgentRunInput {
        AgentRunInput(
            goal: "生成仓库周刊",
            agentID: BuiltInAgents.githubWeeklyReport.id,
            explicitRepos: repoIDs.map { id in
                AIComposerRepoReference(
                    id: id,
                    owner: "octo",
                    name: "demo-\(id)",
                    fullName: "octo/demo-\(id)",
                    language: "Swift",
                    starsCount: id == 1 ? 100 : 50
                )
            },
            explicitRepoMode: mode,
            selectedModelID: nil,
            attachments: [],
            githubLinks: [],
            webSearchEnabled: false,
            source: "Agent Workspace"
        )
    }

    private func candidate(
        id: Int64,
        isStarred: Bool,
        sources: Set<AgentRepositorySource>,
        latest: String
    ) -> AgentRepositoryCandidate {
        let fullName = "octo/demo-\(id)"
        return AgentRepositoryCandidate(
            snapshot: AgentRepoSnapshot(
                id: id,
                owner: "octo",
                name: "demo-\(id)",
                fullName: fullName,
                description: nil,
                language: "Swift",
                starsCount: id == 1 ? 100 : 50,
                topics: [],
                isPrivate: false,
                isStarred: isStarred,
                starredAt: isStarred ? latest : nil,
                htmlUrl: "https://github.com/\(fullName)",
                sourceIDs: sources.map(\.rawValue).sorted(),
                latestObservedAt: latest
            ),
            ownerAvatar: nil,
            sources: sources,
            status: .unread,
            isArchived: false,
            isFork: false,
            pushedAt: latest,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: latest,
            libraryUpdatedAt: nil,
            firstObservedAt: nil,
            latestObservedAt: latest,
            normalizedSearchText: RAGMentionCandidate.normalize(fullName)
        )
    }
}

private struct FixedAgentRepositoryCatalog: AgentRepositoryCatalogProviding {
    let candidatesValue: [AgentRepositoryCandidate]

    init(candidates: [AgentRepositoryCandidate]) {
        candidatesValue = candidates
    }

    func candidates() async throws -> [AgentRepositoryCandidate] {
        candidatesValue
    }
}
