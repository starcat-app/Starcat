//
//  RAGRepositoryInsightsContextTests.swift
//  StarcatTests
//
//  验证仓库洞察 RAG 上下文不会扩大知识库范围、不会联网，并始终输出合法 XML。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RAG repository insights context")
struct RAGRepositoryInsightsContextTests {
    @Test("显式仓库优先，否则只使用最终保留 bundle")
    func resolvesBoundedRepositoryTargets() {
        let first = repo(id: 1, name: "first")
        let second = repo(id: 2, name: "second")
        let third = repo(id: 3, name: "third")
        let candidates = [first, second, third].map(candidate)
        let retrieval = RAGRetrievalResult(
            candidates: candidates,
            bundles: [
                bundle(candidate(second)),
                bundle(candidate(first)),
            ],
            childHits: []
        )

        let ordinary = RAGRepositoryInsightsTargetResolver.resolve(
            composerContext: .init(),
            candidates: candidates,
            retrieval: retrieval
        )
        var explicitContext = RAGComposerContext()
        explicitContext.explicitRepoIDs = [3, 1, 3]
        let explicit = RAGRepositoryInsightsTargetResolver.resolve(
            composerContext: explicitContext,
            candidates: candidates,
            retrieval: retrieval
        )

        #expect(ordinary.map(\.id) == [2, 1])
        #expect(explicit.map(\.id) == [3, 1])
        #expect(!ordinary.contains(where: { $0.id == 3 }))
    }

    @Test("多仓库加载有界并发且固定使用 cache-only")
    func loadsArtifactsWithBoundedCacheOnlyConcurrency() async {
        let repositories = (1...6).map { repo(id: Int64($0), name: "repo-\($0)") }
        let provider = RepositoryInsightsRAGProviderStub(
            artifacts: Dictionary(
                uniqueKeysWithValues: repositories.map { ($0.id, artifact(for: $0)) }
            ),
            delay: .milliseconds(20)
        )
        let loader = RAGRepositoryInsightsContextLoader(
            provider: provider,
            configuredTokenBudget: 4_096,
            maximumConcurrentLoads: 2,
            now: { Date(timeIntervalSince1970: 1_775_000_000) }
        )

        let result = await loader.load(repositories: repositories)
        let probe = await provider.probe()

        #expect(result.documents.map(\.snapshot.repoID) == repositories.map(\.id))
        #expect(result.snapshots.allSatisfy { $0.outcome == .success })
        #expect(probe.maximumActive <= 2)
        #expect(probe.modes.count == repositories.count)
        #expect(probe.modes.allSatisfy { $0 == .cacheOnly })
    }

    @Test("缺失 Artifact 只记录不可用快照")
    func recordsUnavailableArtifactWithoutInventingDocument() async {
        let repository = repo(id: 7, name: "missing")
        let provider = RepositoryInsightsRAGProviderStub(artifacts: [:])
        let loader = RAGRepositoryInsightsContextLoader(provider: provider)

        let result = await loader.load(repositories: [repository])

        #expect(result.documents.isEmpty)
        #expect(result.snapshots.count == 1)
        #expect(result.snapshots[0].outcome == .unavailable)
        #expect(result.snapshots[0].degradationReason == "artifact_unavailable")
    }

    @Test("洞察 XML 投影按结构删减并保持合法根节点")
    func projectsWellFormedInsightsXML() throws {
        let details = (0..<80).map {
            "<week commits=\"\($0)\" start=\"2026-01-\(String(format: "%02d", ($0 % 28) + 1))T00:00:00Z\" />"
        }.joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <repository_insights repository_id="42" repository="octo/demo" source_hash="source">
          <metadata stars="100" forks="10" />
          <commit_activity sample_weeks="80">
            \(details)
          </commit_activity>
          <health grade="A" overall_score="90" />
        </repository_insights>
        """

        let projection = try RAGRepositoryInsightsXMLProjector().project(
            xml,
            tokenBudget: 220
        )
        let parsed = try XMLDocument(xmlString: projection.xml)

        #expect(parsed.rootElement()?.name == "repository_insights")
        #expect(projection.wasProjected)
        #expect(projection.projectedTokens <= 220)
        #expect(projection.removedDetailCount > 0)
        #expect(projection.xml.contains("<projection "))
        #expect(!projection.xml.contains("[truncated]"))
    }

    @Test("洞察投影拒绝错误根节点")
    func rejectsInvalidInsightsXML() {
        #expect(throws: RAGRepositoryInsightsXMLProjectorError.invalidXML) {
            try RAGRepositoryInsightsXMLProjector().project(
                "<repository />",
                tokenBudget: 1_000
            )
        }
    }

    private func repo(id: Int64, name: String) -> Repo {
        var value = Repo.makeMinimal(owner: "octo", name: name)
        value.id = id
        return value
    }

    private func candidate(_ repo: Repo) -> RAGRepoCandidate {
        RAGRepoCandidate(
            repo: repo,
            status: .unread,
            libraryUpdatedAt: nil,
            tagNames: []
        )
    }

    private func bundle(_ candidate: RAGRepoCandidate) -> RepoContextBundle {
        RepoContextBundle(
            candidate: candidate,
            score: 1,
            matchedChildren: [],
            sectionParents: []
        )
    }

    private func artifact(for repo: Repo) -> RepositoryInsightsContextArtifact {
        let generatedAt = Date(timeIntervalSince1970: 1_775_000_000)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <repository_insights repository_id="\(repo.id)" repository="\(repo.fullName)" source_hash="source-\(repo.id)">
          <metadata stars="1" />
        </repository_insights>
        """
        let document = RepositoryInsightsDocument(
            repositoryID: repo.id,
            repositoryFullName: repo.fullName,
            generatedAt: generatedAt,
            sourceHash: "source-\(repo.id)",
            xml: xml
        )
        return RepositoryInsightsContextArtifact(
            document: document,
            metadata: RepositoryInsightsContextMetadata(
                schemaVersion: RepositoryInsightsContextMetadata.schemaVersion,
                repositoryID: repo.id,
                repositoryFullName: repo.fullName,
                accountStorageKey: "user-1",
                generatedAt: generatedAt,
                sourceHash: document.sourceHash,
                xmlHash: "xml-\(repo.id)"
            )
        )
    }
}

private actor RepositoryInsightsRAGProviderStub: RepositoryInsightsRAGContextProviding {
    struct Probe: Sendable {
        var maximumActive: Int
        var modes: [RepositoryInsightsContextPreparationMode]
    }

    private let artifacts: [Int64: RepositoryInsightsContextArtifact]
    private let delay: Duration
    private var active = 0
    private var maximumActive = 0
    private var modes: [RepositoryInsightsContextPreparationMode] = []

    init(
        artifacts: [Int64: RepositoryInsightsContextArtifact],
        delay: Duration = .zero
    ) {
        self.artifacts = artifacts
        self.delay = delay
    }

    func prepareArtifact(
        for repo: Repo,
        mode: RepositoryInsightsContextPreparationMode
    ) async -> RepositoryInsightsContextArtifact? {
        modes.append(mode)
        active += 1
        maximumActive = max(maximumActive, active)
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        active -= 1
        return artifacts[repo.id]
    }

    func probe() -> Probe {
        Probe(maximumActive: maximumActive, modes: modes)
    }
}
