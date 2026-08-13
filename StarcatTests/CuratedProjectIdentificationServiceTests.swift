//
//  CuratedProjectIdentificationServiceTests.swift
//  StarcatTests
//
//  覆盖精选发布台 AI 甄别的自然语言拆分、证据判断和 GitHub 防幻觉守卫。
//

import Foundation
import Testing
@testable import Starcat

@Suite("精选发布台 AI 甄别")
@MainActor
struct CuratedProjectIdentificationServiceTests {
    @Test("自然语言线索经 AI 检索式和证据判断得到官方仓库")
    func naturalLanguageUsesAIAndEvidence() async throws {
        let candidate = Self.candidate(owner: "openai", name: "codex")
        let reasoner = CuratedReasonerStub(responses: [
            .init(content: """
            {"items":[{"id":7,"original_text":"OpenAI 发布 Codex 编程智能体","title":"Codex","entity_type":"open_source_project","source_url":"https://example.com/codex","explicit_repository":null,"search_queries":["OpenAI Codex official GitHub"]}]}
            """, modelName: "test-model"),
            .init(content: """
            {"items":[{"id":0,"status":"confirmed","repository":"openai/codex","reason":"官方组织与项目描述一致","evidence_urls":["https://openai.com/codex"]}]}
            """, modelName: "test-model")
        ])
        let web = CuratedSearchProviderStub(page: Self.webPage())
        let repositories = CuratedRepositoryEvidenceStub(
            searchResults: [candidate],
            verified: ["openai/codex": candidate],
            readmes: ["openai/codex": "# Codex\nOpenAI coding agent"]
        )
        let service = CuratedProjectIdentificationService(
            reasoner: reasoner,
            webProvider: web,
            repositories: repositories
        )

        let result = try await service.identify(
            input: "OpenAI 发布 Codex 编程智能体",
            externalSearchProvider: .anySearch,
            selectedModelID: nil,
            onProgress: { _ in }
        )

        #expect(result.modelName == "test-model")
        #expect(result.findings.count == 1)
        #expect(result.findings[0].status == .confirmed)
        #expect(result.findings[0].repository?.identity.normalizedFullName == "openai/codex")
        #expect(result.findings[0].sourceURL?.absoluteString == "https://example.com/codex")
        #expect(web.queries == ["OpenAI Codex official GitHub"])
        #expect(reasoner.phases == ["curated_identification_parse", "curated_identification_judge"])
    }

    @Test("AI 选择未检索到的仓库时降级为待确认")
    func hallucinatedRepositoryIsRejected() async throws {
        let actual = Self.candidate(owner: "official", name: "project")
        let service = CuratedProjectIdentificationService(
            reasoner: CuratedReasonerStub(responses: [
                .init(content: """
                {"items":[{"id":0,"original_text":"Project 发布","title":"Project","entity_type":"open_source_project","source_url":null,"explicit_repository":null,"search_queries":["Project GitHub"]}]}
                """, modelName: "test-model"),
                .init(content: """
                {"items":[{"id":0,"status":"confirmed","repository":"invented/project","reason":"看起来相似","evidence_urls":[]}]}
                """, modelName: "test-model")
            ]),
            webProvider: CuratedSearchProviderStub(page: .empty),
            repositories: CuratedRepositoryEvidenceStub(
                searchResults: [actual],
                verified: ["official/project": actual]
            )
        )

        let result = try await service.identify(
            input: "Project 发布",
            externalSearchProvider: .anySearch,
            selectedModelID: nil,
            onProgress: { _ in }
        )

        #expect(result.findings[0].status == .needsReview)
        #expect(result.findings[0].repository == nil)
        #expect(result.findings[0].candidates.map(\.identity.normalizedFullName) == ["official/project"])
    }

    @Test("闭源产品没有官方仓库时保留未找到结论")
    func closedProductRemainsNotFound() async throws {
        let service = CuratedProjectIdentificationService(
            reasoner: CuratedReasonerStub(responses: [
                .init(content: """
                {"items":[{"id":0,"original_text":"Acme 发布闭源云服务","title":"Acme Cloud","entity_type":"service","source_url":"https://acme.example/cloud","explicit_repository":null,"search_queries":["Acme Cloud GitHub"]}]}
                """, modelName: "test-model"),
                .init(content: """
                {"items":[{"id":0,"status":"not_found","repository":null,"reason":"闭源云服务，没有主体直接对应的官方仓库","evidence_urls":[]}]}
                """, modelName: "test-model")
            ]),
            webProvider: CuratedSearchProviderStub(page: .empty),
            repositories: CuratedRepositoryEvidenceStub(searchResults: [], verified: [:])
        )

        let result = try await service.identify(
            input: "Acme 发布闭源云服务",
            externalSearchProvider: .anySearch,
            selectedModelID: nil,
            onProgress: { _ in }
        )

        #expect(result.findings[0].status == .notFound)
        #expect(result.findings[0].repository == nil)
        #expect(result.confirmedFindings.isEmpty)
    }

    @Test("AI 返回非法 JSON 时给出明确失败而不回退猜测")
    func invalidAIResponseFailsClosed() async {
        let service = CuratedProjectIdentificationService(
            reasoner: CuratedReasonerStub(responses: [
                .init(content: "not json", modelName: "test-model")
            ]),
            webProvider: CuratedSearchProviderStub(page: .empty),
            repositories: CuratedRepositoryEvidenceStub(searchResults: [], verified: [:])
        )

        await #expect(throws: CuratedProjectIdentificationError.self) {
            _ = try await service.identify(
                input: "任意自然语言",
                externalSearchProvider: .anySearch,
                selectedModelID: nil,
                onProgress: { _ in }
            )
        }
    }

    private static func webPage() -> SearchProviderPage {
        let url = URL(string: "https://openai.com/codex")!
        return SearchProviderPage(
            repositories: [],
            references: [
                ReferenceCandidate(
                    normalizedURL: url,
                    originalURL: url,
                    title: "Codex | OpenAI",
                    snippet: "OpenAI coding agent",
                    domain: "openai.com",
                    source: .web,
                    providerID: .anySearch
                )
            ],
            totalCount: 1,
            hasNextPage: false
        )
    }

    private static func candidate(owner: String, name: String) -> RepositoryCandidate {
        RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: 1, owner: owner, name: name),
            card: RepoCardViewData(
                ghRepoId: 1,
                fullName: "\(owner)/\(name)",
                owner: owner,
                repo: name,
                avatarURL: nil,
                description: "Official project",
                language: "Swift",
                starsCount: 100,
                forksCount: 10,
                isArchived: false,
                isFork: false,
                isPrivate: false,
                isStarred: false,
                isInLibrary: false,
                badge: nil,
                weeklySources: [],
                weeklySourceLabel: nil,
                inlineMetadata: nil,
                footerMetadata: nil,
                readStatus: nil,
                openSSFScore: nil,
                healthBadge: nil
            ),
            sources: [.github],
            localRepo: nil,
            remoteRepo: nil,
            semanticScore: nil
        )
    }
}

@MainActor
private final class CuratedReasonerStub: CuratedProjectAIReasoning {
    private var responses: [CuratedProjectAICompletion]
    private(set) var phases: [String] = []

    init(responses: [CuratedProjectAICompletion]) {
        self.responses = responses
    }

    func completeJSON(
        systemPrompt: String,
        userPrompt: String,
        phase: String,
        selectedModelID: String?
    ) async throws -> CuratedProjectAICompletion {
        phases.append(phase)
        guard !responses.isEmpty else { throw CuratedProjectIdentificationError.invalidAIResponse }
        return responses.removeFirst()
    }
}

private final class CuratedSearchProviderStub: SearchProvider, @unchecked Sendable {
    let source: SearchSource = .web
    private let page: SearchProviderPage
    private let lock = NSLock()
    private(set) var queries: [String] = []

    init(page: SearchProviderPage) {
        self.page = page
    }

    func search(_ request: SearchRequest) async throws -> SearchProviderPage {
        lock.withLock { queries.append(request.query) }
        return page
    }
}

private final class CuratedRepositoryEvidenceStub: CuratedRepositoryEvidenceProviding, @unchecked Sendable {
    private let searchResults: [RepositoryCandidate]
    private let verified: [String: RepositoryCandidate]
    private let readmes: [String: String]

    init(
        searchResults: [RepositoryCandidate],
        verified: [String: RepositoryCandidate],
        readmes: [String: String] = [:]
    ) {
        self.searchResults = searchResults
        self.verified = verified
        self.readmes = readmes
    }

    func search(query: String) async throws -> [RepositoryCandidate] {
        searchResults
    }

    func verify(address: GitHubRepositoryAddress) async throws -> RepositoryCandidate {
        guard let candidate = verified[address.normalizedFullName] else {
            throw CuratedProjectResolverError.repositoryNotFound(address.normalizedFullName)
        }
        return candidate
    }

    func readmeExcerpt(address: GitHubRepositoryAddress) async -> String? {
        readmes[address.normalizedFullName]
    }
}
