//
//  RepositoryInsightsContextCoordinatorTests.swift
//  StarcatTests
//
//  验证页面、AI 与 RAG 共用协调器时的 single-flight、cache-only 与账号切换门禁。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Repository insights context coordinator")
struct RepositoryInsightsContextCoordinatorTests {
    @Test("相同仓库并发准备只生成并写入一次")
    func coalescesConcurrentPreparation() async throws {
        let fixture = try await makeFixture(delay: 80_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repo = makeRepo(id: 201)

        async let first = fixture.coordinator.prepareArtifact(
            for: repo,
            mode: .refreshIfNeeded
        )
        async let second = fixture.coordinator.prepareArtifact(
            for: repo,
            mode: .refreshIfNeeded
        )
        let values = await [first, second]

        #expect(values[0] == values[1])
        #expect(values[0]?.document.repositoryID == repo.id)
        #expect(await fixture.provider.refreshCount() == 1)
    }

    @Test("cache-only 优先读取已有 Artifact 不重复聚合")
    func cacheOnlyUsesStoredArtifactFirst() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repo = makeRepo(id: 202)
        let stored = try #require(
            await fixture.coordinator.prepareArtifact(for: repo, mode: .refreshIfNeeded)
        )

        let cached = await fixture.coordinator.prepareArtifact(for: repo, mode: .cacheOnly)

        #expect(cached == stored)
        #expect(await fixture.provider.refreshCount() == 1)
        #expect(await fixture.provider.cacheOnlyCount() == 0)
    }

    @Test("cache-only 缺 Artifact 时只读取缓存文档")
    func cacheOnlyBuildsFromCacheWithoutRefresh() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repo = makeRepo(id: 203)

        let artifact = await fixture.coordinator.prepareArtifact(for: repo, mode: .cacheOnly)

        #expect(artifact?.document.repositoryID == repo.id)
        #expect(await fixture.provider.refreshCount() == 0)
        #expect(await fixture.provider.cacheOnlyCount() == 1)
    }

    @Test("数据库 scope 变化会丢弃迟到 Artifact 写回")
    func rejectsLateWriteAfterScopeChange() async throws {
        let fixture = try await makeFixture(delay: 120_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repo = makeRepo(id: 204)

        let task = Task {
            await fixture.coordinator.prepareArtifact(for: repo, mode: .refreshIfNeeded)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await MainActor.run {
            fixture.scopeBox.scope = RepositoryInsightsContextScope(
                userID: 8,
                databaseRevision: 2
            )
        }
        let result = await task.value
        let oldScopeArtifact = try await fixture.storage.load(
            repositoryID: repo.id,
            repositoryFullName: repo.fullName,
            scope: RepositoryInsightsContextScope(userID: 7, databaseRevision: 1)
        )

        #expect(result == nil)
        #expect(oldScopeArtifact == nil)
    }

    @Test("主动取消后迟到 Provider 结果不得写入 Artifact")
    func cancellationRejectsLateWrite() async throws {
        let fixture = try await makeFixture(delay: 120_000_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repo = makeRepo(id: 207)

        let task = Task {
            await fixture.coordinator.prepareArtifact(for: repo, mode: .forceRegenerate)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        await fixture.coordinator.cancelPreparation(for: repo, mode: .forceRegenerate)

        let result = await task.value
        let stored = try await fixture.storage.load(
            repositoryID: repo.id,
            repositoryFullName: repo.fullName,
            scope: RepositoryInsightsContextScope(userID: 7, databaseRevision: 1)
        )

        #expect(result == nil)
        #expect(stored == nil)
    }

    @Test("AI context 与持久化 Artifact 使用完全相同 XML")
    func aiContextSharesPersistedDocument() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repo = makeRepo(id: 205)

        let context = await fixture.coordinator.context(for: repo)
        let artifact = try #require(await fixture.coordinator.loadArtifact(for: repo))

        #expect(context.content == artifact.document.xml)
        #expect(await fixture.provider.refreshCount() == 1)
    }

    @Test("Artifact 删除失败必须传播给知识库 UI")
    func deletionFailureIsPropagated() async {
        let provider = CoordinatorDocumentProvider(delay: 0)
        let storage = FailingDeletionContextStorage()
        let scopeBox = await MainActor.run {
            CoordinatorScopeBox(
                scope: RepositoryInsightsContextScope(userID: 7, databaseRevision: 1)
            )
        }
        let coordinator = RepositoryInsightsContextCoordinator(
            documentProvider: provider,
            storage: storage,
            scopeProvider: { scopeBox.scope }
        )

        do {
            try await coordinator.deleteArtifact(for: makeRepo(id: 206))
            Issue.record("删除失败不应被 Coordinator 吞掉")
        } catch CoordinatorDeletionTestError.expected {
            // 预期：ViewModel 收到错误后保留旧 Artifact，并展示失败反馈。
        } catch {
            Issue.record("收到非预期错误：\(error)")
        }
    }

    private func makeFixture(
        delay: UInt64 = 0
    ) async throws -> (
        root: URL,
        storage: RepositoryInsightsContextStorage,
        provider: CoordinatorDocumentProvider,
        scopeBox: CoordinatorScopeBox,
        coordinator: RepositoryInsightsContextCoordinator
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "starcat-insights-coordinator-\(UUID().uuidString)",
            isDirectory: true
        )
        let storage = RepositoryInsightsContextStorage(rootURL: root)
        let provider = CoordinatorDocumentProvider(delay: delay)
        let scopeBox = await MainActor.run {
            CoordinatorScopeBox(
                scope: RepositoryInsightsContextScope(userID: 7, databaseRevision: 1)
            )
        }
        let coordinator = RepositoryInsightsContextCoordinator(
            documentProvider: provider,
            storage: storage,
            scopeProvider: { scopeBox.scope }
        )
        return (root, storage, provider, scopeBox, coordinator)
    }

    private func makeRepo(id: Int64) -> Repo {
        var repo = Repo.makeMinimal(owner: "octo", name: "repo-\(id)")
        repo.id = id
        repo.starsCount = Int(id)
        return repo
    }
}

private actor CoordinatorDocumentProvider: RepositoryInsightsDocumentProviding {
    private let delay: UInt64
    private var refreshCalls = 0
    private var cacheOnlyCalls = 0

    init(delay: UInt64) {
        self.delay = delay
    }

    func document(for repo: Repo) async -> RepositoryInsightsDocument {
        refreshCalls += 1
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        return Self.makeDocument(repo: repo, generatedAt: Date(timeIntervalSince1970: 1_775_200_000))
    }

    func cachedDocument(for repo: Repo) async -> RepositoryInsightsDocument {
        cacheOnlyCalls += 1
        return Self.makeDocument(repo: repo, generatedAt: Date(timeIntervalSince1970: 1_775_200_000))
    }

    func refreshCount() -> Int {
        refreshCalls
    }

    func cacheOnlyCount() -> Int {
        cacheOnlyCalls
    }

    private static func makeDocument(repo: Repo, generatedAt: Date) -> RepositoryInsightsDocument {
        RepositoryInsightsXMLRenderer.render(
            snapshot: RepositoryInsightsSnapshot(
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
            ),
            generatedAt: generatedAt
        )
    }
}

private enum CoordinatorDeletionTestError: Error {
    case expected
}

/// 只用于锁定删除错误传播契约，其余方法不会在本测试触发。
private actor FailingDeletionContextStorage: RepositoryInsightsContextStoring {
    func load(
        repositoryID: Int64,
        repositoryFullName: String,
        scope: RepositoryInsightsContextScope
    ) async throws -> RepositoryInsightsContextArtifact? {
        nil
    }

    func store(
        _ document: RepositoryInsightsDocument,
        scope: RepositoryInsightsContextScope,
        force: Bool
    ) async throws -> RepositoryInsightsContextWriteOutcome {
        .suppressed
    }

    func delete(
        repositoryID: Int64,
        repositoryFullName: String,
        scope: RepositoryInsightsContextScope
    ) async throws {
        throw CoordinatorDeletionTestError.expected
    }
}

@MainActor
private final class CoordinatorScopeBox {
    var scope: RepositoryInsightsContextScope

    init(scope: RepositoryInsightsContextScope) {
        self.scope = scope
    }
}
