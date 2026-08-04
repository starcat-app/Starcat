//
//  AgentRunContextProviderTests.swift
//  StarcatTests
//
//  验证 Agent 复用 RAG 候选层后的 only / prefer / exclude 范围契约。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentRunContextProvider")
struct AgentRunContextProviderTests {
    @Test("only 严格保留显式仓库及选择顺序")
    func onlyKeepsExplicitRepositories() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .only, repoIDs: [3, 1])
        )

        #expect(context.failureReason == nil)
        #expect(context.repos.map(\.id) == [3, 1])
        #expect(context.explicitRepoMode == .only)
    }

    @Test("prefer 将显式仓库置顶后补足知识库候选")
    func preferPinsExplicitRepositoriesBeforeCandidates() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .prefer, repoIDs: [3])
        )

        #expect(context.failureReason == nil)
        #expect(context.repos.map(\.id) == [3, 1, 2])
        #expect(context.explicitRepoMode == .prefer)
    }

    @Test("exclude 从冻结候选中排除所有显式仓库")
    func excludeRemovesExplicitRepositories() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .exclude, repoIDs: [2])
        )

        #expect(context.failureReason == nil)
        #expect(context.repos.map(\.id) == [1, 3, 4])
        #expect(context.explicitRepos?.map(\.id) == [2])
        #expect(context.explicitRepoMode == .exclude)
    }

    @Test("显式仓库离开知识库后不会静默扩大范围")
    func missingExplicitRepositoryFailsClosed() async throws {
        let fixture = try await makeFixture()
        let context = await fixture.provider.makeContext(
            definition: BuiltInAgents.githubWeeklyReport,
            input: input(mode: .prefer, repoIDs: [999])
        )

        #expect(context.repos.isEmpty)
        #expect(context.failureReason == String.l10n("agent.loop.error.contextUnavailable"))
    }

    private func makeFixture() async throws -> (
        provider: RepositoryAgentRunContextProvider,
        database: InMemoryDatabaseManager
    ) {
        let database = try InMemoryDatabaseManager()
        let notes = GRDBRepoNoteRepository(database: database)
        for id in Int64(1)...4 {
            try await database.insertRepoFixture(id: id)
            try await notes.updateLibraryState(repoId: id, state: .inLibrary)
        }
        return (
            RepositoryAgentRunContextProvider(
                candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
                candidateLimit: 3
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
