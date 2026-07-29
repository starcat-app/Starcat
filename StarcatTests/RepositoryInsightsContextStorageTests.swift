//
//  RepositoryInsightsContextStorageTests.swift
//  StarcatTests
//
//  验证仓库洞察 XML Artifact 的原子写入、去重、删除抑制与账号隔离。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Repository insights context storage")
struct RepositoryInsightsContextStorageTests {
    private let generatedAt = Date(timeIntervalSince1970: 1_775_100_000)

    @Test("写入后可校验读取 metadata 与纯 XML")
    func storesAndLoadsValidatedArtifact() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = makeDocument(repositoryID: 100, stars: 10)

        let outcome = try await fixture.storage.store(
            document,
            scope: fixture.scope,
            force: false
        )
        let loaded = try #require(
            try await fixture.storage.load(
                repositoryID: document.repositoryID,
                repositoryFullName: document.repositoryFullName,
                scope: fixture.scope
            )
        )

        #expect(outcome == .written(loaded))
        #expect(loaded.document == document)
        #expect(loaded.metadata.sourceHash == document.sourceHash)
        #expect(loaded.metadata.xmlHash.count == 64)
        #expect(loaded.metadata.accountStorageKey == "user-7")
    }

    @Test("同一 source hash 不重复写盘并保留首份生成时间")
    func skipsUnchangedSourceHash() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = makeDocument(repositoryID: 101, stars: 10, generatedAt: generatedAt)
        let later = makeDocument(
            repositoryID: 101,
            stars: 10,
            generatedAt: generatedAt.addingTimeInterval(600)
        )

        _ = try await fixture.storage.store(first, scope: fixture.scope, force: false)
        let outcome = try await fixture.storage.store(later, scope: fixture.scope, force: false)
        let loaded = try #require(
            try await fixture.storage.load(
                repositoryID: 101,
                repositoryFullName: first.repositoryFullName,
                scope: fixture.scope
            )
        )

        #expect(outcome == .unchanged(loaded))
        #expect(loaded.document.generatedAt == generatedAt)
        #expect(loaded.document.xml == first.xml)
    }

    @Test("删除仅移除 Artifact 并抑制同版本自动重建")
    func deletionSuppressesSameVersionOnly() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = makeDocument(repositoryID: 102, stars: 10)
        let changed = makeDocument(repositoryID: 102, stars: 11)
        let unrelatedSentinel = fixture.root
            .deletingLastPathComponent()
            .appendingPathComponent("insights-cache-sentinel-\(UUID().uuidString)")
        try Data("database-cache".utf8).write(to: unrelatedSentinel)
        defer { try? FileManager.default.removeItem(at: unrelatedSentinel) }

        _ = try await fixture.storage.store(original, scope: fixture.scope, force: false)
        try await fixture.storage.delete(
            repositoryID: original.repositoryID,
            repositoryFullName: original.repositoryFullName,
            scope: fixture.scope
        )
        let suppressed = try await fixture.storage.store(
            original,
            scope: fixture.scope,
            force: false
        )
        let refreshed = try await fixture.storage.store(
            changed,
            scope: fixture.scope,
            force: false
        )

        #expect(
            try await fixture.storage.load(
                repositoryID: original.repositoryID,
                repositoryFullName: original.repositoryFullName,
                scope: fixture.scope
            )?.document == changed
        )
        #expect(suppressed == .suppressed)
        if case .written = refreshed {
            // expected
        } else {
            Issue.record("Changed source hash must clear deletion suppression.")
        }
        #expect(FileManager.default.fileExists(atPath: unrelatedSentinel.path))
    }

    @Test("主动重新生成可越过删除抑制")
    func forcedRegenerationOverridesDeletionSuppression() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = makeDocument(repositoryID: 103, stars: 10)

        _ = try await fixture.storage.store(document, scope: fixture.scope, force: false)
        try await fixture.storage.delete(
            repositoryID: document.repositoryID,
            repositoryFullName: document.repositoryFullName,
            scope: fixture.scope
        )
        let outcome = try await fixture.storage.store(
            document,
            scope: fixture.scope,
            force: true
        )

        if case .written(let artifact) = outcome {
            #expect(artifact.document == document)
        } else {
            Issue.record("Forced regeneration must write the artifact.")
        }
    }

    @Test("不同账号作用域不会互相读取或删除")
    func isolatesAccountScopes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstScope = RepositoryInsightsContextScope(userID: 7)
        let secondScope = RepositoryInsightsContextScope(userID: 8)
        let document = makeDocument(repositoryID: 104, stars: 10)

        _ = try await fixture.storage.store(document, scope: firstScope, force: false)

        #expect(
            try await fixture.storage.load(
                repositoryID: document.repositoryID,
                repositoryFullName: document.repositoryFullName,
                scope: secondScope
            ) == nil
        )
        try await fixture.storage.delete(
            repositoryID: document.repositoryID,
            repositoryFullName: document.repositoryFullName,
            scope: secondScope
        )
        #expect(
            try await fixture.storage.load(
                repositoryID: document.repositoryID,
                repositoryFullName: document.repositoryFullName,
                scope: firstScope
            ) != nil
        )
    }

    @Test("无效新文档写入失败时保留上一份有效 Artifact")
    func invalidReplacementPreservesExistingArtifact() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = makeDocument(repositoryID: 105, stars: 10)
        let invalid = RepositoryInsightsDocument(
            repositoryID: original.repositoryID,
            repositoryFullName: original.repositoryFullName,
            generatedAt: generatedAt.addingTimeInterval(60),
            sourceHash: String(repeating: "f", count: 64),
            xml: "<not_repository_insights />"
        )
        _ = try await fixture.storage.store(original, scope: fixture.scope, force: false)

        await #expect(throws: RepositoryInsightsContextStorageError.invalidXML) {
            try await fixture.storage.store(invalid, scope: fixture.scope, force: false)
        }
        let loaded = try #require(
            try await fixture.storage.load(
                repositoryID: original.repositoryID,
                repositoryFullName: original.repositoryFullName,
                scope: fixture.scope
            )
        )
        #expect(loaded.document == original)
    }

    private func makeFixture() throws -> (
        root: URL,
        storage: RepositoryInsightsContextStorage,
        scope: RepositoryInsightsContextScope
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-insights-context-\(UUID().uuidString)", isDirectory: true)
        return (
            root,
            RepositoryInsightsContextStorage(
                rootURL: root,
                now: { generatedAt.addingTimeInterval(120) }
            ),
            RepositoryInsightsContextScope(userID: 7)
        )
    }

    private func makeDocument(
        repositoryID: Int64,
        stars: Int,
        generatedAt: Date? = nil
    ) -> RepositoryInsightsDocument {
        var repo = Repo.makeMinimal(owner: "octo", name: "repo-\(repositoryID)")
        repo.id = repositoryID
        repo.starsCount = stars
        let snapshot = RepositoryInsightsSnapshot(
            repo: repo,
            release: nil,
            releaseCadence: nil,
            health: nil,
            openSSF: nil,
            community: nil,
            activity: nil,
            commitActivity: nil,
            contributors: nil,
            security: nil,
            recentActivity: nil,
            starHistory: nil,
            localFailureCount: 0
        )
        return RepositoryInsightsXMLRenderer.render(
            snapshot: snapshot,
            generatedAt: generatedAt ?? self.generatedAt
        )
    }
}
