//
//  KnowledgeRAGCoreTests.swift
//  StarcatTests
//
//  覆盖 Query Planner 校验、结构化候选、混合融合、无命中早停和会话 citation 生命周期。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Knowledge RAG Core")
struct KnowledgeRAGCoreTests {
    @Test("Planner: 无筛选问题保持 semantic_only")
    func plannerSemanticOnly() throws {
        let plan = try KnowledgeRAGQueryPlanner.decodeAndValidate("""
            {
              "mode":"semantic_only",
              "semanticQuery":"适合本地 RAG 的 Swift 项目",
              "filters":{},
              "sort":null,
              "candidateLimit":null,
              "remoteContextRequests":[],
              "confidence":"high",
              "clarificationQuestion":null,
              "userVisiblePlan":{"scope":"知识库","chips":[],"semantic":"适合本地 RAG 的 Swift 项目"}
            }
            """, fallbackQuestion: "原问题")
        #expect(plan.mode == .semanticOnly)
        #expect(!plan.filters.hasEffectiveConditions)
    }

    @Test("Planner: 结构化条件和远程请求执行本地钳制")
    func plannerClampsRemoteRequest() throws {
        let plan = try KnowledgeRAGQueryPlanner.decodeAndValidate("""
            {
              "mode":"filtered_semantic",
              "semanticQuery":"数据库崩溃问题",
              "filters":{"status":"using","minStars":1000},
              "candidateLimit":9999,
              "remoteContextRequests":[{
                "resource":"github_issues","query":"crash","reason":"需要现场信息",
                "maxRepos":99,"perRepoLimit":99
              }],
              "confidence":"high",
              "userVisiblePlan":{"scope":"知识库","chips":[],"semantic":"数据库崩溃问题"}
            }
            """, fallbackQuestion: "原问题")
        #expect(plan.mode == .filteredSemantic)
        #expect(plan.candidateLimit == 1_000)
        #expect(plan.remoteContextRequests.first?.maxRepos == 5)
        #expect(plan.remoteContextRequests.first?.perRepoLimit == 10)
    }

    @Test("Planner: 日期歧义计划必须带追问")
    func plannerClarification() throws {
        let plan = try KnowledgeRAGQueryPlanner.decodeAndValidate("""
            {
              "mode":"needs_clarification",
              "semanticQuery":"Swift 库",
              "filters":{},
              "remoteContextRequests":[],
              "confidence":"needs_clarification",
              "clarificationQuestion":"开始是指加入知识库、Star、创建还是 push 时间？",
              "userVisiblePlan":{"scope":"知识库","chips":[],"semantic":"Swift 库"}
            }
            """, fallbackQuestion: "原问题")
        #expect(plan.mode == .needsClarification)
        #expect(plan.clarificationQuestion?.contains("加入知识库") == true)
    }

    @Test("候选 SQL 同时执行知识库、状态、语言和 stars 条件")
    func structuredCandidateFiltering() async throws {
        let database = try InMemoryDatabaseManager()
        for id in Int64(1)...3 {
            try await database.insertRepoFixture(id: id)
            try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: id, state: .inLibrary)
        }
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE repos SET stars_count = 5000, language = 'Swift' WHERE id = 1")
            try db.execute(sql: "UPDATE repo_notes SET status = 'using' WHERE repo_id = 1")
            try db.execute(sql: "UPDATE repos SET stars_count = 100, language = 'Swift' WHERE id = 2")
            try db.execute(sql: "UPDATE repo_notes SET status = 'using' WHERE repo_id = 2")
            try db.execute(sql: "UPDATE repos SET stars_count = 9000, language = 'Go' WHERE id = 3")
            try db.execute(sql: "UPDATE repo_notes SET status = 'using' WHERE repo_id = 3")
        }
        let plan = RAGQueryPlan(
            mode: .filteredSemantic,
            semanticQuery: "RAG",
            filters: RAGRepoFilter(status: .using, languages: ["Swift"], minStars: 1_000)
        )
        let repository = GRDBRAGRepoCandidateRepository(database: database)
        let candidates = try await repository.fetchCandidates(plan: plan, explicitRepoIDs: [], explicitMode: .only)
        #expect(candidates.map(\.repo.id) == [1])
    }

    @Test("@repo only 由本地候选层强制收窄")
    func explicitRepoOnly() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 10)
        try await database.insertRepoFixture(id: 11)
        let notes = GRDBRepoNoteRepository(database: database)
        try await notes.updateLibraryState(repoId: 10, state: .inLibrary)
        try await notes.updateLibraryState(repoId: 11, state: .inLibrary)
        let repository = GRDBRAGRepoCandidateRepository(database: database)
        let plan = RAGQueryPlan(mode: .semanticOnly, semanticQuery: "compare")
        let candidates = try await repository.fetchCandidates(plan: plan, explicitRepoIDs: [11], explicitMode: .only)
        #expect(candidates.map(\.repo.id) == [11])
    }

    @Test("混合融合合并命中并限制每个 repo 的 child 数")
    func hybridFusionDeduplicatesAndCapsRepo() {
        let chunks = (1...5).map { index in fixtureChunk(id: Int64(index), repoID: index <= 4 ? 1 : 2, source: index == 1 ? .notes : .readme) }
        let keyword = chunks.map { RAGChildHit(chunk: $0, score: 1, kind: .keyword) }
        let vector = chunks.reversed().map {
            RAGChildHit(chunk: $0, score: 0.9, kind: .vector, vectorSimilarity: 0.9)
        }
        let engine = RAGHybridFusionEngine(configuration: .init(perRepoLimit: 2, totalLimit: 10))
        let hits = engine.fuse(keywordHits: keyword, vectorHits: vector)
        #expect(hits.filter { $0.chunk.repoId == 1 }.count == 2)
        #expect(hits.contains { $0.kind == .hybrid })
        #expect(hits.first(where: { $0.kind == .hybrid })?.vectorSimilarity == 0.9)
    }

    @Test("纯 keyword 首名超过证据阈值")
    func keywordOnlyHitSurvivesEvidenceThreshold() throws {
        let chunk = fixtureChunk(id: 8, repoID: 1, source: .readme)
        let hits = RAGHybridFusionEngine().fuse(
            keywordHits: [RAGChildHit(chunk: chunk, score: 1, kind: .keyword)],
            vectorHits: []
        )
        let hit = try #require(hits.first)
        #expect(hit.kind == .keyword)
        #expect(hit.score >= 0.08)
    }

    @Test("query embedding 失败时保留 keyword 检索结果")
    func embeddingFailureKeepsKeywordResults() async throws {
        let database = try InMemoryDatabaseManager()
        let chunk = fixtureChunk(id: 81, repoID: 1, source: .readme)
        let retriever = KnowledgeRAGRetriever(
            chunkRepository: GRDBRAGChunkRepository(database: database),
            keywordProvider: StubRAGKeywordProvider(
                backendName: "SQLite",
                hits: [RAGChildHit(chunk: chunk, score: 1, kind: .keyword)],
                shouldThrow: false
            ),
            vectorProvider: StubRAGVectorProvider(backendName: "SQLite", hits: [], shouldThrow: false),
            embeddingClient: SpyRAGAIClient(failEmbedding: true),
            embeddingModel: "embed"
        )

        let result = try await retriever.retrieve(
            semanticQuery: "database",
            candidates: [RAGRepoCandidate(
                repo: fixtureRepo(id: 1, isPrivate: false),
                status: .using,
                libraryUpdatedAt: nil,
                tagNames: []
            )],
            explicitMode: .only,
            explicitRepoIDs: []
        )

        #expect(result.childHits.count == 1)
        #expect(result.childHits.first?.kind == .keyword)
    }

    @Test("Parent context 围绕后段命中而不是只取章节开头")
    func parentContextIncludesAnchorChunk() throws {
        let chunks = (1...4).map { index -> RAGChunk in
            var chunk = fixtureChunk(id: Int64(index), repoID: 1, source: .readme)
            chunk.chunkIndex = index - 1
            chunk.tokenCount = 900
            chunk.content = String(repeating: "content ", count: 450)
            return chunk
        }
        let selected = RAGParentContextPacker().select(
            chunks: chunks,
            anchorChunkID: 4,
            tokenLimit: 1_000
        )
        #expect(selected.map(\.id) == [4])
    }

    @Test("私有 repo 的两路检索不发送给外部 provider")
    func privateReposUseLocalProviders() async throws {
        let database = try InMemoryDatabaseManager()
        let publicRecorder = RAGRepoIDRecorder()
        let privateRecorder = RAGRepoIDRecorder()
        let chunks = GRDBRAGChunkRepository(database: database)
        let retriever = KnowledgeRAGRetriever(
            chunkRepository: chunks,
            keywordProvider: RecordingRAGKeywordProvider(backendName: "external", recorder: publicRecorder),
            vectorProvider: RecordingRAGVectorProvider(backendName: "external", recorder: publicRecorder),
            privateRepoKeywordProvider: RecordingRAGKeywordProvider(backendName: "local", recorder: privateRecorder),
            privateRepoVectorProvider: RecordingRAGVectorProvider(backendName: "local", recorder: privateRecorder),
            embeddingClient: SpyRAGAIClient(),
            embeddingModel: "embed"
        )
        let candidates = [
            RAGRepoCandidate(repo: fixtureRepo(id: 1, isPrivate: false), status: .unread, libraryUpdatedAt: nil, tagNames: []),
            RAGRepoCandidate(repo: fixtureRepo(id: 2, isPrivate: true), status: .unread, libraryUpdatedAt: nil, tagNames: [])
        ]

        _ = try await retriever.retrieve(
            semanticQuery: "database",
            candidates: candidates,
            explicitMode: .only,
            explicitRepoIDs: []
        )
        let publicIDs = await publicRecorder.recordedRepoIDs()
        let privateIDs = await privateRecorder.recordedRepoIDs()
        #expect(Set(publicIDs) == [1])
        #expect(Set(privateIDs) == [2])
    }

    @Test("无候选时不调用 embedding 或 Generator")
    func noCandidatesStopsBeforeAI() async throws {
        let database = try InMemoryDatabaseManager()
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient()
        let retriever = KnowledgeRAGRetriever(
            chunkRepository: chunks,
            keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
            vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
            embeddingClient: spy,
            embeddingModel: "embed"
        )
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "anything")),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: retriever,
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )
        var states: [RAGAnswerState] = []
        for try await event in service.ask(request: RAGServiceRequest(rawQuestion: "anything", composerContext: .init(), conversationID: nil)) {
            if case .state(let state) = event { states.append(state) }
        }
        #expect(states.contains(.noKnowledgeRepos))
        #expect(spy.callCount == 0)
    }

    @Test("会话标题只发送首个问题并清理模型输出")
    func conversationTitleUsesOnlyFirstQuestion() async throws {
        let database = try InMemoryDatabaseManager()
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient(chatResponse: "\n“SQLite 与 GRDB 选型比较”\n补充说明")
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "unused")),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: KnowledgeRAGRetriever(
                chunkRepository: chunks,
                keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
                vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
                embeddingClient: spy,
                embeddingModel: "embed"
            ),
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )

        let result = await service.generateConversationTitle(
            firstQuestion: "帮我比较一下这个项目的 SQLite 和 GRDB 选型",
            isDebugEnabled: true,
            debugEndpoint: "https://example.com/v1"
        )

        guard case .completed(let title, let debugEvents) = result else {
            Issue.record("预期返回标题")
            return
        }
        #expect(title == "SQLite 与 GRDB 选型比较")
        #expect(debugEvents.map(\.stage) == [.titlePrompt, .titleResponse])
        #expect(spy.callCount == 1)
        #expect(spy.lastChatRequest?.history.isEmpty == true)
        #expect(spy.lastChatRequest?.images.isEmpty == true)
        #expect(spy.lastChatRequest?.userPrompt == "用户的第一个问题：\n帮我比较一下这个项目的 SQLite 和 GRDB 选型")
        #expect(spy.lastChatRequest?.parameters.streamEnabled == false)
    }

    @Test("调用方未提供确认器时默认跳过远程上下文")
    func missingConsentDoesNotFetchRemoteContext() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 21)
        try await GRDBRepoNoteRepository(database: database).updateLibraryState(repoId: 21, state: .inLibrary)
        let chunks = GRDBRAGChunkRepository(database: database)
        let spy = SpyRAGAIClient()
        let remoteRecorder = RemoteFetchRecorder()
        let retriever = KnowledgeRAGRetriever(
            chunkRepository: chunks,
            keywordProvider: SQLiteRAGKeywordSearchProvider(repository: chunks),
            vectorProvider: SQLiteRAGVectorSearchProvider(repository: chunks),
            embeddingClient: spy,
            embeddingModel: "embed"
        )
        let remoteRequest = RAGRemoteContextRequest(
            resource: .githubIssues,
            query: "crash",
            reason: "需要当前 issue",
            maxRepos: 1,
            perRepoLimit: 1
        )
        let service = KnowledgeRAGService(
            planner: FixedRAGPlanner(plan: RAGQueryPlan(
                mode: .structuredOnly,
                semanticQuery: "",
                remoteContextRequests: [remoteRequest]
            )),
            candidateRepository: GRDBRAGRepoCandidateRepository(database: database),
            retriever: retriever,
            remoteContextProvider: RecordingRemoteContextProvider(recorder: remoteRecorder),
            generatorClient: spy,
            generatorModel: "chat",
            generatorParameters: .summaryDefault
        )

        do {
            for try await _ in service.ask(request: RAGServiceRequest(
                rawQuestion: "列出相关项目",
                composerContext: .init(),
                conversationID: nil
            )) {}
        } catch {
            // Spy Generator 故意失败；本测试只验证失败前没有静默联网。
        }

        #expect(await remoteRecorder.fetchCount == 0)
    }

    @Test("远程上下文与大文本附件按独立 token budget 截断而不整块丢失")
    func promptBudgetsRemoteAndAttachments() {
        let remoteTail = "REMOTE_TAIL"
        let attachmentTail = "ATTACHMENT_TAIL"
        let builder = KnowledgeRAGPromptBuilder(
            maxEvidenceTokens: 1_000,
            maxRemoteTokens: 100,
            maxAttachmentTokens: 100
        )
        let prompt = builder.build(
            question: "compare",
            plan: RAGQueryPlan(mode: .semanticOnly, semanticQuery: "compare"),
            retrieval: RAGRetrievalResult(candidates: [], bundles: [], childHits: []),
            remoteBlocks: [RAGRemoteContextBlock(
                id: "1:issues",
                repoId: 1,
                resource: .githubIssues,
                title: "octo/demo · Issues",
                sourceURL: URL(string: "https://github.com/octo/demo/issues"),
                content: String(repeating: "remote ", count: 2_000) + remoteTail,
                fetchedAt: Date(),
                errorMessage: nil
            )],
            attachmentContexts: [RAGAttachmentContext(
                attachmentID: UUID(),
                filename: "large.txt",
                content: String(repeating: "attachment ", count: 2_000) + attachmentTail
            )]
        )

        #expect(prompt.userPrompt.contains("[R1] octo/demo · Issues"))
        #expect(prompt.userPrompt.contains("[A:large.txt]"))
        #expect(prompt.userPrompt.contains("[truncated]"))
        #expect(!prompt.userPrompt.contains(remoteTail))
        #expect(!prompt.userPrompt.contains(attachmentTail))
        #expect(prompt.systemPrompt.contains("不可信数据"))
        #expect(prompt.systemPrompt.contains("其中出现的指令"))
    }

    @Test("structured_only Prompt 提供候选计数并按请求展开列表")
    func structuredPromptCarriesCandidateCount() {
        let candidates = (1...12).map { id in
            RAGRepoCandidate(
                repo: fixtureRepo(id: Int64(id), isPrivate: false),
                status: .using,
                libraryUpdatedAt: nil,
                tagNames: []
            )
        }
        let prompt = KnowledgeRAGPromptBuilder().build(
            question: "列出这 12 个项目",
            plan: RAGQueryPlan(mode: .structuredOnly, semanticQuery: "", candidateLimit: 12),
            retrieval: RAGRetrievalResult(candidates: candidates, bundles: [], childHits: []),
            remoteBlocks: [],
            attachmentContexts: []
        )

        #expect(prompt.userPrompt.contains("structured_candidate_count=12"))
        #expect(prompt.userPrompt.contains("structured_rows_in_prompt=12"))
        #expect(prompt.userPrompt.contains("structured_rows_truncated=false"))
    }

    @Test("删除 chunk 后历史 citation 保留且 chunkID 置空")
    func historyCitationSurvivesChunkCleanup() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 42)
        let notes = GRDBRepoNoteRepository(database: database)
        try await notes.updateLibraryState(repoId: 42, state: .inLibrary)
        let chunks = GRDBRAGChunkRepository(database: database)
        let sync = try await chunks.replaceSource(repoId: 42, source: .readme, drafts: [
            RAGChunkDraft(
                repoId: 42,
                source: .readme,
                sourceId: "",
                parentType: .readmeSection,
                parentKey: "readme:intro",
                parentTitle: "README > Intro",
                chunkKey: "readme:intro:0",
                chunkIndex: 0,
                sectionPath: "Intro",
                title: "Intro",
                content: "Evidence",
                tokenCount: 2,
                isTruncated: false
            )
        ])
        let chunkID = try #require(sync.pendingChunkIDs.first)
        let store = GRDBRAGConversationStore(database: database)
        let conversation = try await store.createConversation(title: nil)
        try await store.appendTurn(
            conversationID: conversation.id,
            question: "Q",
            answer: "A [S1]",
            model: "chat",
            citations: [RAGCitation(
                id: UUID(),
                marker: "S1",
                chunkID: chunkID,
                repoID: 42,
                repoFullName: "octo/demo-42",
                source: .readme,
                sectionTitle: "Intro",
                score: 0.9,
                hitKind: .hybrid,
                vectorSimilarity: 0.91,
                sourceURL: URL(string: "https://github.com/octo/demo-42")
            )]
        )
        try await chunks.deleteAll()
        let detail = try #require(try await store.loadConversation(id: conversation.id))
        let citation = try #require(detail.messages.last?.citations.first)
        #expect(citation.chunkID == nil)
        #expect(citation.repoFullName == "octo/demo-42")
        #expect(citation.marker == "S1")
        #expect(citation.vectorSimilarity == 0.91)
    }

    @Test("外部后端配置拒绝无效 endpoint")
    func backendValidation() {
        var meili = RAGMeilisearchConfiguration()
        meili.endpoint = "not a url"
        #expect(meili.validationMessage != nil)
        meili.endpoint = "ftp://localhost:7700"
        #expect(meili.validationMessage != nil)
        var qdrant = RAGQdrantConfiguration()
        qdrant.collectionName = "other/collection"
        #expect(qdrant.validationMessage != nil)
    }

    @Test("Meilisearch 报错或空命中时回退 SQLite provider")
    func keywordBackendFallback() async throws {
        let expected = RAGChildHit(chunk: fixtureChunk(id: 90, repoID: 9, source: .readme), score: 0.8, kind: .keyword)
        let fallback = StubRAGKeywordProvider(backendName: "SQLite", hits: [expected], shouldThrow: false)

        let errorProvider = FallbackRAGKeywordSearchProvider(
            primary: StubRAGKeywordProvider(backendName: "Meilisearch", hits: [], shouldThrow: true),
            fallback: fallback
        )
        let emptyProvider = FallbackRAGKeywordSearchProvider(
            primary: StubRAGKeywordProvider(backendName: "Meilisearch", hits: [], shouldThrow: false),
            fallback: fallback
        )

        #expect(try await errorProvider.search(query: "RAG", model: "embed", repoIDs: [9], limit: 10) == [expected])
        #expect(try await emptyProvider.search(query: "RAG", model: "embed", repoIDs: [9], limit: 10) == [expected])
    }

    @Test("Meilisearch replace 等待异步 tasks 真正完成")
    func meilisearchReplaceWaitsForTasks() async throws {
        let database = try InMemoryDatabaseManager()
        let httpClient = SequencedRAGHTTPClient(responses: [
            (Data(#"{"taskUid":1}"#.utf8), 202),
            (Data(#"{"status":"succeeded"}"#.utf8), 200),
            (Data(#"{"taskUid":2}"#.utf8), 202),
            (Data(#"{"status":"succeeded"}"#.utf8), 200)
        ])
        let provider = MeilisearchRAGProvider(
            configuration: RAGMeilisearchConfiguration(),
            apiKey: nil,
            repository: GRDBRAGChunkRepository(database: database),
            httpClient: httpClient
        )

        try await provider.replaceAll(chunks: [])

        #expect(await httpClient.requestCount == 4)
    }

    @Test("Qdrant 报错或空命中时回退本地向量 provider")
    func vectorBackendFallback() async throws {
        let expected = RAGChildHit(chunk: fixtureChunk(id: 91, repoID: 9, source: .notes), score: 0.9, kind: .vector)
        let fallback = StubRAGVectorProvider(backendName: "SQLite", hits: [expected], shouldThrow: false)

        let errorProvider = FallbackRAGVectorSearchProvider(
            primary: StubRAGVectorProvider(backendName: "Qdrant", hits: [], shouldThrow: true),
            fallback: fallback
        )
        let emptyProvider = FallbackRAGVectorSearchProvider(
            primary: StubRAGVectorProvider(backendName: "Qdrant", hits: [], shouldThrow: false),
            fallback: fallback
        )

        #expect(try await errorProvider.search(queryVector: [1, 0], model: "embed", repoIDs: [9], limit: 10) == [expected])
        #expect(try await emptyProvider.search(queryVector: [1, 0], model: "embed", repoIDs: [9], limit: 10) == [expected])
    }

    @Test("Qdrant 已有 collection 的命名向量不匹配时在清理前失败")
    func qdrantCollectionCompatibility() async throws {
        let database = try InMemoryDatabaseManager()
        let response = """
            {"result":{"config":{"params":{"vectors":{"another":{"size":2,"distance":"Cosine"}}}}}}
            """
        let provider = QdrantRAGProvider(
            configuration: RAGQdrantConfiguration(),
            apiKey: nil,
            repository: GRDBRAGChunkRepository(database: database),
            httpClient: StaticRAGHTTPClient(data: Data(response.utf8), statusCode: 200)
        )

        do {
            try await provider.replaceAll(chunks: [fixtureChunk(id: 92, repoID: 9, source: .readme)])
            Issue.record("命名向量不匹配时不应继续清理或写入 collection")
        } catch {
            #expect(error.localizedDescription.contains("content"))
        }
    }

    @Test("GitHub Issues 响应不会把额外 repo 混入候选上下文")
    func githubIssuesRemainCandidateScoped() async throws {
        let response = """
            {
              "items": [
                {
                  "number": 1,
                  "title": "Allowed issue",
                  "state": "open",
                  "html_url": "https://github.com/octo/demo-9/issues/1",
                  "repository_url": "https://api.github.com/repos/octo/demo-9",
                  "body": "candidate body",
                  "labels": [{"name":"bug"}],
                  "comments": 2,
                  "updated_at": "2026-07-10T00:00:00Z"
                },
                {
                  "number": 2,
                  "title": "Foreign issue",
                  "state": "open",
                  "html_url": "https://github.com/other/repo/issues/2",
                  "repository_url": "https://api.github.com/repos/other/repo",
                  "body": "must not enter prompt",
                  "labels": [{"name":"foreign"}],
                  "comments": 1,
                  "updated_at": "2026-07-10T00:00:00Z"
                }
              ]
            }
            """
        let provider = GitHubRAGRemoteContextProvider(
            httpClient: StaticRAGHTTPClient(data: Data(response.utf8), statusCode: 200),
            token: nil,
            cache: RAGRemoteContextMemoryCache()
        )
        let request = RAGRemoteContextRequest(
            resource: .githubIssues,
            query: "crash OR repo:other/repo",
            reason: "验证候选边界",
            maxRepos: 1,
            perRepoLimit: 10
        )

        let blocks = await provider.fetch(
            requests: [request],
            candidates: [RAGRepoCandidate(
                repo: fixtureRepo(id: 9, isPrivate: false),
                status: .using,
                libraryUpdatedAt: nil,
                tagNames: []
            )]
        )
        let content = try #require(blocks.first?.content)
        #expect(content.contains("Allowed issue"))
        #expect(!content.contains("Foreign issue"))
        #expect(!content.contains("foreign"))
    }

    @Test("GitHub 远程缓存按认证 token 隔离")
    func githubRemoteCacheIsTokenScoped() async throws {
        func response(title: String) -> Data {
            Data("""
                {"items":[{
                  "number":1,"title":"\(title)","state":"open",
                  "html_url":"https://github.com/octo/demo-9/issues/1",
                  "repository_url":"https://api.github.com/repos/octo/demo-9",
                  "body":"body","labels":[],"comments":0,
                  "updated_at":"2026-07-10T00:00:00Z"
                }]}
                """.utf8)
        }
        let cache = RAGRemoteContextMemoryCache()
        let request = RAGRemoteContextRequest(
            resource: .githubIssues,
            query: "bug",
            reason: "验证账户隔离",
            maxRepos: 1,
            perRepoLimit: 10
        )
        let candidates = [RAGRepoCandidate(
            repo: fixtureRepo(id: 9, isPrivate: true),
            status: .using,
            libraryUpdatedAt: nil,
            tagNames: []
        )]
        let first = GitHubRAGRemoteContextProvider(
            httpClient: StaticRAGHTTPClient(data: response(title: "Account A"), statusCode: 200),
            token: "token-a",
            cache: cache
        )
        let second = GitHubRAGRemoteContextProvider(
            httpClient: StaticRAGHTTPClient(data: response(title: "Account B"), statusCode: 200),
            token: "token-b",
            cache: cache
        )

        _ = await first.fetch(requests: [request], candidates: candidates)
        let secondBlocks = await second.fetch(requests: [request], candidates: candidates)

        #expect(secondBlocks.first?.content.contains("Account B") == true)
        #expect(secondBlocks.first?.content.contains("Account A") == false)
    }

    @Test("远程上下文只持久化审计元数据")
    func remoteContextAuditPersistsMetadataOnly() async throws {
        let database = try InMemoryDatabaseManager()
        try await database.insertRepoFixture(id: 43)
        let store = GRDBRAGConversationStore(database: database)
        let conversation = try await store.createConversation()
        let fetchedAt = Date(timeIntervalSince1970: 1_784_000_000)

        try await store.appendTurn(
            conversationID: conversation.id,
            question: "近期 issue 有什么风险？",
            answer: "有一个待处理问题。",
            model: "test-model",
            citations: [],
            remoteContexts: [RAGRemoteContextBlock(
                id: "issues-43",
                repoId: 43,
                resource: .githubIssues,
                title: "GitHub Issues",
                sourceURL: URL(string: "https://github.com/octo/demo-43/issues"),
                content: "这段远程正文不应写入历史表。",
                fetchedAt: fetchedAt,
                errorMessage: nil
            )]
        )

        let loaded = try await store.loadConversation(id: conversation.id)
        let detail = try #require(loaded)
        let audit = try #require(detail.messages.last?.remoteContextAudits.first)
        #expect(audit.resource == .githubIssues)
        #expect(audit.repoID == 43)
        #expect(audit.sourceURL?.absoluteString == "https://github.com/octo/demo-43/issues")
        #expect(audit.fetchedAt == ISO8601DateFormatter.shared.string(from: fetchedAt))
        let columns = try await database.writer.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(rag_message_remote_contexts)")
                .map { (row: Row) -> String in row["name"] }
        }
        #expect(!columns.contains("content"))
    }

    @Test("多轮历史保留最近三轮并压缩早期消息")
    func conversationHistoryIsBounded() {
        let conversationID = UUID()
        let messages = (0..<8).map { index in
            RAGStoredMessage(
                id: UUID(),
                conversationID: conversationID,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "消息 \(index) " + String(repeating: "内容", count: 200),
                model: index.isMultiple(of: 2) ? nil : "test-model",
                citations: [],
                remoteContextAudits: [],
                createdAt: "2026-07-11T00:00:0\(index)Z"
            )
        }

        let history = RAGConversationHistoryBuilder.build(from: messages)
        #expect(history.count == 7)
        #expect(history.first?.role == .user)
        #expect(history.first?.content.contains("受限摘要") == true)
        #expect(history.first?.content.contains("消息 0") == true)
        #expect(history.last?.content.contains("消息 7") == true)
        #expect(history.dropFirst().allSatisfy { $0.content.count <= 500 })
    }

    @Test("大纲轨只投影完整问答轮次，跳过未完成用户消息")
    func outlineRailUsesCompleteTurnsOnly() {
        let conversationID = UUID()
        let user1 = UUID()
        let assistant1 = UUID()
        let orphanUser = UUID()
        let messages = [
            RAGStoredMessage(
                id: user1,
                conversationID: conversationID,
                role: .user,
                content: "第一问\n第二行",
                model: nil,
                citations: [],
                remoteContextAudits: [],
                createdAt: "2026-07-13T01:00:00Z"
            ),
            RAGStoredMessage(
                id: assistant1,
                conversationID: conversationID,
                role: .assistant,
                content: String(repeating: "答", count: 160),
                model: "test-model",
                citations: [],
                remoteContextAudits: [],
                createdAt: "2026-07-13T01:00:05Z"
            ),
            RAGStoredMessage(
                id: orphanUser,
                conversationID: conversationID,
                role: .user,
                content: "还在生成中的问题",
                model: nil,
                citations: [],
                remoteContextAudits: [],
                createdAt: "2026-07-13T01:01:00Z"
            )
        ]

        let turns = RAGConversationOutlineBuilder.completeTurns(from: messages)
        #expect(turns.count == 1)
        #expect(turns[0].userMessageID == user1)
        #expect(turns[0].title == "第一问")
        #expect(turns[0].preview.hasSuffix("…"))
        #expect(turns[0].timestampISO8601 == "2026-07-13T01:00:05Z")
    }

    private func fixtureChunk(id: Int64, repoID: Int64, source: RAGChunkSource) -> RAGChunk {
        RAGChunk(
            id: id,
            repoId: repoID,
            source: source,
            sourceId: "",
            parentType: .readmeSection,
            parentKey: "readme:test",
            parentTitle: "Test",
            chunkKey: "chunk:\(id)",
            chunkIndex: Int(id),
            sectionPath: "Test",
            title: "Test",
            content: "content \(id)",
            contentHash: "hash-\(id)",
            tokenCount: 2,
            isTruncated: false,
            embeddingModel: "embed",
            embeddingDim: 2,
            embedding: RepoEmbedding.encode([1, 0]),
            embeddingStatus: .ready,
            embeddingError: nil,
            indexedAt: "2026-07-10T00:00:00.000Z",
            createdAt: "2026-07-10T00:00:00.000Z",
            updatedAt: "2026-07-10T00:00:00.000Z"
        )
    }

    private func fixtureRepo(id: Int64, isPrivate: Bool) -> Repo {
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
            isPrivate: isPrivate,
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
}

private actor RAGRepoIDRecorder {
    private var repoIDs: [Int64] = []

    func record(_ values: [Int64]) {
        repoIDs.append(contentsOf: values)
    }

    func recordedRepoIDs() -> [Int64] {
        repoIDs
    }
}

private struct RecordingRAGKeywordProvider: RAGKeywordSearchProvider {
    let backendName: String
    let recorder: RAGRepoIDRecorder

    func search(query: String, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        await recorder.record(repoIDs)
        return []
    }
}

private struct RecordingRAGVectorProvider: RAGVectorSearchProvider {
    let backendName: String
    let recorder: RAGRepoIDRecorder

    func search(queryVector: [Float], model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        await recorder.record(repoIDs)
        return []
    }
}

private enum StubRAGProviderError: Error {
    case unavailable
}

private struct StubRAGKeywordProvider: RAGKeywordSearchProvider {
    let backendName: String
    let hits: [RAGChildHit]
    let shouldThrow: Bool

    func search(query: String, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        if shouldThrow { throw StubRAGProviderError.unavailable }
        return hits
    }
}

private struct StubRAGVectorProvider: RAGVectorSearchProvider {
    let backendName: String
    let hits: [RAGChildHit]
    let shouldThrow: Bool

    func search(queryVector: [Float], model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        if shouldThrow { throw StubRAGProviderError.unavailable }
        return hits
    }
}

private struct StaticRAGHTTPClient: RAGHTTPClientProtocol {
    let data: Data
    let statusCode: Int

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

private actor SequencedRAGHTTPClient: RAGHTTPClientProtocol {
    private var responses: [(Data, Int)]
    private(set) var requestCount = 0

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        requestCount += 1
        let (data, statusCode) = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

private struct FixedRAGPlanner: KnowledgeRAGQueryPlanning {
    var plan: RAGQueryPlan
    func plan(question: String, composerContext: RAGComposerContext) async throws -> RAGQueryPlan { plan }
}

private actor RemoteFetchRecorder {
    private(set) var fetchCount = 0

    func record() {
        fetchCount += 1
    }
}

private struct RecordingRemoteContextProvider: KnowledgeRAGRemoteContextProviding {
    let recorder: RemoteFetchRecorder

    func fetch(
        requests: [RAGRemoteContextRequest],
        candidates: [RAGRepoCandidate]
    ) async -> [RAGRemoteContextBlock] {
        await recorder.record()
        return []
    }
}

private final class SpyRAGAIClient: @unchecked Sendable, AIClientProtocol {
    private let lock = NSLock()
    private var calls = 0
    private var latestChatRequest: AIChatRequest?
    private let failEmbedding: Bool
    private let chatResponse: String?
    var callCount: Int { lock.withLock { calls } }
    var lastChatRequest: AIChatRequest? { lock.withLock { latestChatRequest } }

    init(failEmbedding: Bool = false, chatResponse: String? = nil) {
        self.failEmbedding = failEmbedding
        self.chatResponse = chatResponse
    }

    func chat(request: AIChatRequest) async throws -> AIChatResponse {
        lock.withLock {
            calls += 1
            latestChatRequest = request
        }
        if let chatResponse {
            return AIChatResponse(content: chatResponse, model: request.model, finishReason: "stop")
        }
        throw AIClientError.emptyResponse
    }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        lock.withLock { calls += 1 }
        return AsyncThrowingStream { $0.finish(throwing: AIClientError.emptyResponse) }
    }

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        lock.withLock { calls += 1 }
        throw AIClientError.emptyResponse
    }

    func embedding(input: String, model: String?) async throws -> [Float] {
        lock.withLock { calls += 1 }
        if failEmbedding { throw StubRAGProviderError.unavailable }
        return [1, 0]
    }

    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] {
        lock.withLock { calls += 1 }
        return inputs.map { _ in [1, 0] }
    }

    func listModels() async throws -> [AIModelDescriptor] {
        lock.withLock { calls += 1 }
        return []
    }

    func testConnection() async throws {
        lock.withLock { calls += 1 }
    }
}
