//
//  AgentRunContextProviderTests.swift
//  StarcatTests
//
//  验证 Agent 业务上下文与 Knowledge RAG 范围已经解耦：Weekly 按最近 7 天 Star
//  自动取数，Repo Insight 接受一个普通 Star，知识库只提供可检索证据子集。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentRunContextProvider")
struct AgentRunContextProviderTests {
    private let now = ISO8601DateFormatter().date(from: "2026-08-04T12:00:00Z")!

    @Test("Weekly 未手选仓库时自动冻结最近 7 天新增 Star")
    func weeklyUsesRecentStarsByDefault() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .only, repoIDs: [])
        )

        #expect(context.failureReason == nil)
        #expect(context.repos.map(\.id) == [1, 2])
        #expect(context.knowledgeEligibleRepoIDs == [1])
    }

    @Test("Weekly only 可用普通 Star 覆盖自动时间窗")
    func weeklyOnlyOverridesRecentWindow() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .only, repoIDs: [3])
        )

        #expect(context.failureReason == nil)
        #expect(context.repos.map(\.id) == [3])
        #expect(context.knowledgeEligibleRepoIDs == [])
    }

    @Test("Weekly prefer 将手选仓库置顶后补最近 7 天 Star")
    func weeklyPreferPinsOverrideBeforeRecentStars() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .prefer, repoIDs: [3])
        )

        #expect(context.repos.map(\.id) == [3, 1, 2])
    }

    @Test("Weekly exclude 只从最近 7 天业务上下文排除手选仓库")
    func weeklyExcludeRemovesRecentStar() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .exclude, repoIDs: [2])
        )

        #expect(context.repos.map(\.id) == [1])
    }

    @Test("Weekly 最近 7 天没有新增 Star 时仍返回合法空上下文")
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

    @Test("Repo Insight 可选择未进入知识库的普通 Star")
    func repoInsightAcceptsOrdinaryStar() async throws {
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
        return (
            RepositoryAgentRunContextProvider(
                repoRepository: GRDBRepoRepository(database: database),
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
                    starsCount: 0
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
}
