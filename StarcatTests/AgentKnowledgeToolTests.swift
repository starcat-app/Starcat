//
//  AgentKnowledgeToolTests.swift
//  StarcatTests
//
//  验证 AgentKnowledgeTool 不会突破冻结的 run scope，并保留 RAG 降级与审计语义。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentKnowledgeTool")
struct AgentKnowledgeToolTests {
    @Test("knowledge.search capability 不依赖 AgentRunContext")
    func sharedCapabilityExecutesWithExplicitScopeRequest() async throws {
        let candidates = RecordingKnowledgeCandidateProvider()
        let retriever = RecordingKnowledgeRetriever()
        let executor = KnowledgeSearchCapabilityExecutor(
            candidateProvider: candidates,
            retriever: retriever
        )

        _ = try await executor.execute(KnowledgeSearchCapabilityRequest(
            query: "Swift persistence",
            repositoryScopeIDs: [5, 2],
            explicitRepoIDs: [5],
            explicitMode: .prefer,
            maxRepositories: 30
        ))

        #expect(KnowledgeSearchCapabilities.search.id == "knowledge.search")
        #expect(KnowledgeSearchCapabilities.search.permission == .readOnly)
        #expect(await candidates.requestedRepoIDs() == [5, 2])
        let request = try #require(await retriever.latestRequest())
        #expect(request.candidateIDs == [5, 2])
        #expect(request.explicitMode == .prefer)
        #expect(request.explicitRepoIDs == [5])
    }

    @Test("only prefer exclude 都只检索冻结仓库并向 Retriever 传递原模式")
    func frozenScopeAndExplicitModeReachRetriever() async throws {
        let cases: [(AIComposerExplicitRepoMode, [Int64], [Int64])] = [
            (.only, [3, 1], [3, 1]),
            (.prefer, [3, 1, 2], [3]),
            (.exclude, [1, 3], [2])
        ]

        for (mode, frozenIDs, explicitIDs) in cases {
            let candidates = RecordingKnowledgeCandidateProvider()
            let retriever = RecordingKnowledgeRetriever()
            let service = AgentKnowledgeCapabilityAdapter(
                executor: KnowledgeSearchCapabilityExecutor(
                    candidateProvider: candidates,
                    retriever: retriever
                )
            )

            _ = try await service.search(
                query: AgentKnowledgeQuery(text: "Swift database", maxRepositories: 30),
                context: context(mode: mode, frozenIDs: frozenIDs, explicitIDs: explicitIDs)
            )

            #expect(await candidates.requestedRepoIDs() == frozenIDs)
            let request = try #require(await retriever.latestRequest())
            #expect(request.candidateIDs == frozenIDs)
            #expect(request.explicitMode.rawValue == mode.rawValue)
            #expect(request.explicitRepoIDs == explicitIDs)
        }
    }

    @Test("maxRepositories 只能缩小冻结范围")
    func maximumRepositoryLimitOnlyNarrowsScope() async throws {
        let candidates = RecordingKnowledgeCandidateProvider()
        let retriever = RecordingKnowledgeRetriever()
        let service = AgentKnowledgeCapabilityAdapter(
            executor: KnowledgeSearchCapabilityExecutor(candidateProvider: candidates, retriever: retriever)
        )

        _ = try await service.search(
            query: AgentKnowledgeQuery(text: "RAG", maxRepositories: 2),
            context: context(mode: .prefer, frozenIDs: [4, 2, 1], explicitIDs: [4])
        )

        #expect(await candidates.requestedRepoIDs() == [4, 2])
        #expect(await retriever.latestRequest()?.candidateIDs == [4, 2])
    }

    @Test("冻结仓库无法完整回填时 fail closed")
    func missingFrozenRepositoryFailsClosed() async {
        let candidates = RecordingKnowledgeCandidateProvider(omittedRepoID: 2)
        let service = AgentKnowledgeCapabilityAdapter(
            executor: KnowledgeSearchCapabilityExecutor(
                candidateProvider: candidates,
                retriever: RecordingKnowledgeRetriever()
            )
        )

        await #expect(throws: AgentKnowledgeError.repositoryScopeChanged) {
            _ = try await service.search(
                query: AgentKnowledgeQuery(text: "RAG", maxRepositories: 10),
                context: context(mode: .only, frozenIDs: [1, 2], explicitIDs: [1, 2])
            )
        }
    }

    @Test("向量分支失败时保留关键词降级说明与原始诊断")
    func vectorFailureIsReportedAsKeywordFallback() async throws {
        let diagnostics = RAGRetrievalDiagnostics(
            settings: .balanced,
            candidateRepoCount: 1,
            vectorErrorDescription: "embedding unavailable",
            outcome: .noEvidence
        )
        let retriever = RecordingKnowledgeRetriever(diagnostics: diagnostics)
        let service = AgentKnowledgeCapabilityAdapter(
            executor: KnowledgeSearchCapabilityExecutor(
                candidateProvider: RecordingKnowledgeCandidateProvider(),
                retriever: retriever
            )
        )

        let result = try await service.search(
            query: AgentKnowledgeQuery(text: "SQLite", maxRepositories: 1),
            context: context(mode: .only, frozenIDs: [1], explicitIDs: [1])
        )

        #expect(result.diagnostics?.vectorErrorDescription == "embedding unavailable")
        #expect(result.limitations.contains {
            $0.contains("Vector retrieval was unavailable")
        })
    }

    @Test("未配置 Embedding 时真实 Retriever 仍通过 SQLite FTS 返回证据")
    func missingEmbeddingStillUsesKeywordRetrieval() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 1)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(
            repoId: 1,
            state: .inLibrary
        )
        let chunks = GRDBRAGChunkRepository(database: database)
        _ = try await chunks.replaceSource(repoId: 1, source: .metadata, drafts: [
            RAGChunkDraft(
                repoId: 1,
                source: .metadata,
                sourceId: "",
                parentType: .metadata,
                parentKey: "metadata",
                parentTitle: "Repository metadata",
                chunkKey: "metadata:0",
                chunkIndex: 0,
                sectionPath: "Metadata",
                title: "Metadata",
                content: "Database SQLite concurrency toolkit",
                tokenCount: 4,
                isTruncated: false
            )
        ])
        let keyword = SQLiteRAGKeywordSearchProvider(repository: chunks)
        let vector = SQLiteRAGVectorSearchProvider(repository: chunks)
        let service = AgentKnowledgeCapabilityAdapter(
            executor: KnowledgeSearchCapabilityExecutor(
                candidateProvider: RAGKnowledgeSearchCandidateProvider(
                    repository: GRDBRAGRepoCandidateRepository(database: database)
                ),
                retriever: KnowledgeRAGRetriever(
                    chunkRepository: chunks,
                    keywordProvider: keyword,
                    vectorProvider: vector,
                    embeddingClient: nil,
                    embeddingModel: nil
                )
            )
        )

        let result = try await service.search(
            query: AgentKnowledgeQuery(text: "SQLite database", maxRepositories: 1),
            context: context(mode: .only, frozenIDs: [1], explicitIDs: [1])
        )

        #expect(!result.evidenceBlocks.isEmpty)
        #expect(result.evidenceMarkdown.contains("Database SQLite concurrency toolkit"))
        #expect(result.diagnostics?.keywordRawCount == 1)
        #expect(result.diagnostics?.vectorRawCount == 0)
        #expect(result.diagnostics?.vectorErrorDescription == nil)
    }

    @Test("工具输出 evidence citation source 与 retrieval audit")
    func toolReturnsBoundedEvidenceAndAudit() async throws {
        let citation = RAGCitation(
            id: UUID(),
            marker: "S1",
            chunkID: 9,
            repoID: 1,
            repoFullName: "octo/demo-1",
            repoLanguage: "Swift",
            source: .readme,
            sectionTitle: "Usage",
            score: 0.9,
            hitKind: .hybrid,
            vectorSimilarity: 0.8,
            sourceURL: URL(string: "https://github.com/octo/demo-1")
        )
        let result = AgentKnowledgeResult(
            evidenceBlocks: [AgentKnowledgeEvidenceBlock(
                marker: "S1",
                repositoryName: "octo/demo-1",
                sectionTitle: "Usage",
                content: "Use the database queue for serialized writes.",
                chunkIDs: [9]
            )],
            citations: [citation],
            retrievalTrace: RAGRetrievalTrace(
                candidates: [RAGRetrievalCandidateTrace(
                    repoID: 1,
                    fullName: "octo/demo-1",
                    language: "Swift",
                    stars: 100
                )]
            ),
            diagnostics: RAGRetrievalDiagnostics(
                settings: .balanced,
                candidateRepoCount: 1,
                finalChildHitCount: 1,
                bundleCount: 1,
                outcome: .completed
            ),
            limitations: []
        )
        let tool = AgentKnowledgeTool(searcher: FixedKnowledgeSearcher(result: result))

        let toolResult = await tool.execute(AgentToolInput(
            arguments: .object(["query": .string("database writes")]),
            prompt: "Analyze the repository",
            context: context(mode: .only, frozenIDs: [1], explicitIDs: [1])
        ))

        #expect(toolResult.status == .completed)
        #expect(toolResult.output.output.contains("[S1] octo/demo-1 / Usage"))
        #expect(toolResult.output.detail.contains("scope_mode: only"))
        #expect(toolResult.sources.map(\.id) == ["S1"])
        let audit = try #require(toolResult.toolAudit?.knowledgeRetrieval)
        #expect(audit.scopeMode == .only)
        #expect(audit.frozenRepoIDs == [1])
        #expect(audit.citations.map(\.marker) == ["S1"])
        #expect(audit.metrics.candidateCount == 1)
        #expect(audit.metrics.finalEvidenceCount == 1)
        guard case .knowledge(let payload) = toolResult.payload else {
            Issue.record("Expected knowledge payload")
            return
        }
        #expect(payload.citations.map(\.marker) == ["S1"])
    }

    private func context(
        mode: AIComposerExplicitRepoMode,
        frozenIDs: [Int64],
        explicitIDs: [Int64]
    ) -> AgentRunContext {
        AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: frozenIDs.map(repoSnapshot),
            explicitRepos: explicitIDs.map(repoReference),
            explicitRepoMode: mode
        )
    }

    private func repoSnapshot(id: Int64) -> AgentRepoSnapshot {
        AgentRepoSnapshot(
            id: id,
            owner: "octo",
            name: "demo-\(id)",
            fullName: "octo/demo-\(id)",
            description: "Demo",
            language: "Swift",
            starsCount: 100,
            topics: [],
            isPrivate: false,
            isStarred: true,
            starredAt: nil,
            htmlUrl: "https://github.com/octo/demo-\(id)"
        )
    }

    private func repoReference(id: Int64) -> AIComposerRepoReference {
        AIComposerRepoReference(
            id: id,
            owner: "octo",
            name: "demo-\(id)",
            fullName: "octo/demo-\(id)",
            language: "Swift",
            starsCount: 100
        )
    }
}

private actor RecordingKnowledgeCandidateProvider: KnowledgeSearchCandidateProviding {
    private let omittedRepoID: Int64?
    private var repoIDs: [Int64] = []

    init(omittedRepoID: Int64? = nil) {
        self.omittedRepoID = omittedRepoID
    }

    func candidates(repoIDs: [Int64], query: String) async throws -> [RAGRepoCandidate] {
        self.repoIDs = repoIDs
        return repoIDs.filter { $0 != omittedRepoID }.map { id in
            RAGRepoCandidate(
                repo: agentKnowledgeFixtureRepo(id: id),
                status: .using,
                libraryUpdatedAt: nil,
                tagNames: []
            )
        }
    }

    func requestedRepoIDs() -> [Int64] { repoIDs }
}

private actor RecordingKnowledgeRetriever: KnowledgeSearchRetrieving {
    struct Request: Sendable {
        var candidateIDs: [Int64]
        var explicitMode: RAGExplicitRepoMode
        var explicitRepoIDs: [Int64]
    }

    private var request: Request?
    private let diagnostics: RAGRetrievalDiagnostics?

    init(diagnostics: RAGRetrievalDiagnostics? = nil) {
        self.diagnostics = diagnostics
    }

    func retrieve(
        semanticQuery: String,
        keywordQueries: [String],
        candidates: [RAGRepoCandidate],
        explicitMode: RAGExplicitRepoMode,
        explicitRepoIDs: [Int64]
    ) async throws -> RAGRetrievalResult {
        request = Request(
            candidateIDs: candidates.map(\.repo.id),
            explicitMode: explicitMode,
            explicitRepoIDs: explicitRepoIDs
        )
        return RAGRetrievalResult(
            candidates: candidates,
            bundles: [],
            childHits: [],
            diagnostics: diagnostics,
            trace: RAGRetrievalTrace(candidates: candidates.map {
                RAGRetrievalCandidateTrace(
                    repoID: $0.repo.id,
                    fullName: $0.repo.fullName,
                    language: $0.repo.language,
                    stars: $0.repo.starsCount
                )
            })
        )
    }

    func latestRequest() -> Request? { request }
}

private struct FixedKnowledgeSearcher: AgentKnowledgeSearching {
    var result: AgentKnowledgeResult

    func search(query: AgentKnowledgeQuery, context: AgentRunContext) async throws -> AgentKnowledgeResult {
        result
    }
}

private func agentKnowledgeFixtureRepo(id: Int64) -> Repo {
    Repo(
        id: id,
        owner: "octo",
        name: "demo-\(id)",
        fullName: "octo/demo-\(id)",
        description: "Demo",
        language: "Swift",
        starsCount: 100,
        forksCount: 10,
        watchersCount: 5,
        topics: "[]",
        license: "MIT",
        homepage: nil,
        htmlUrl: "https://github.com/octo/demo-\(id)",
        cloneUrl: nil,
        sshUrl: nil,
        isPrivate: false,
        isFork: false,
        isArchived: false,
        isStarred: true,
        pushedAt: nil,
        createdAt: nil,
        updatedAt: nil,
        starredAt: nil,
        cachedAt: nil
    )
}
