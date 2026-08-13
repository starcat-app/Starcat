//
//  CuratedProjectIdentificationSessionTests.swift
//  StarcatTests
//
//  验证 AI 甄别结果的默认入选、人工候选确认与手工仓库核验状态转换。
//

import Foundation
import Testing
@testable import Starcat

@Suite("精选发布台甄别会话")
@MainActor
struct CuratedProjectIdentificationSessionTests {
    @Test("识别完成后仅默认入选已确认项目")
    func identifyIncludesOnlyConfirmedFindings() async {
        let confirmed = Self.finding(id: 1, status: .confirmed, repository: Self.candidate(owner: "openai", name: "codex"))
        let pending = Self.finding(id: 2, status: .needsReview, repository: nil)
        let service = IdentificationSessionStub(result: .init(findings: [confirmed, pending], modelName: "test-model"))
        let session = CuratedProjectIdentificationSession(service: service)
        session.input = "OpenAI Codex 与另一个待确认项目"

        await session.identify(externalSearchProvider: .anySearch)

        #expect(session.findings.count == 2)
        #expect(session.publishableFindings.map(\.id) == [1])
        #expect(session.selectedFindingID == 1)
        #expect(session.modelName == "test-model")
        #expect(service.identifyCallCount == 1)
    }

    @Test("选择已核验候选后待确认项目升级并自动入选")
    func confirmCandidatePromotesFinding() async {
        let candidate = Self.candidate(owner: "official", name: "project")
        let pending = Self.finding(id: 7, status: .needsReview, repository: nil, candidates: [candidate])
        let session = CuratedProjectIdentificationSession(
            service: IdentificationSessionStub(result: .init(findings: [pending], modelName: "test-model"))
        )
        session.input = "Project"
        await session.identify(externalSearchProvider: .anySearch)

        session.confirmCandidate(candidate, for: 7)

        #expect(session.findings[0].status == .confirmed)
        #expect(session.findings[0].repository?.identity.normalizedFullName == "official/project")
        #expect(session.publishableFindings.map(\.id) == [7])
    }

    @Test("手工地址必须经过服务核验后才替换当前结果")
    func manualURLUsesVerificationService() async {
        let verified = Self.candidate(owner: "apple", name: "swift")
        let pending = Self.finding(id: 3, status: .needsReview, repository: nil)
        let service = IdentificationSessionStub(
            result: .init(findings: [pending], modelName: "test-model"),
            verifiedCandidate: verified
        )
        let session = CuratedProjectIdentificationSession(service: service)
        session.input = "Swift"
        await session.identify(externalSearchProvider: .anySearch)
        session.manualRepositoryURL = "https://github.com/apple/swift"

        await session.verifyManualRepository()

        #expect(service.verifiedURLs == ["https://github.com/apple/swift"])
        #expect(session.publishableFindings.first?.repository?.identity.normalizedFullName == "apple/swift")
        #expect(session.manualRepositoryURL.isEmpty)
    }

    private static func finding(
        id: Int,
        status: CuratedProjectIdentificationStatus,
        repository: RepositoryCandidate?,
        candidates: [RepositoryCandidate] = []
    ) -> CuratedProjectFinding {
        CuratedProjectFinding(
            id: id,
            originalText: "Project \(id)",
            title: "Project \(id)",
            sourceURL: URL(string: "https://example.com/project-\(id)"),
            status: status,
            reason: "测试判断",
            repository: repository,
            candidates: candidates,
            evidence: []
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
private final class IdentificationSessionStub: CuratedProjectIdentifying {
    let result: CuratedProjectIdentification
    let verifiedCandidate: RepositoryCandidate?
    private(set) var identifyCallCount = 0
    private(set) var verifiedURLs: [String] = []

    init(result: CuratedProjectIdentification, verifiedCandidate: RepositoryCandidate? = nil) {
        self.result = result
        self.verifiedCandidate = verifiedCandidate
    }

    func identify(
        input: String,
        externalSearchProvider: ExternalSearchProviderID,
        selectedModelID: String?,
        onProgress: @escaping @MainActor (CuratedProjectIdentificationPhase) -> Void
    ) async throws -> CuratedProjectIdentification {
        identifyCallCount += 1
        onProgress(.understanding)
        onProgress(.judging)
        return result
    }

    func verify(repositoryURL: String) async throws -> RepositoryCandidate {
        verifiedURLs.append(repositoryURL)
        return try #require(verifiedCandidate)
    }
}
