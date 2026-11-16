//
//  LinuxDoRepositoryTests.swift
//  StarcatTests
//
//  离线验证来源缓存与分页契约；所有文件都在临时目录，不连接 Linux.do 或真实后端。
//

import Foundation
import Testing
@testable import Starcat

struct LinuxDoRepositoryTests {
    /// 启动预恢复直接使用已落盘目录，既不发请求，也不把其他服务的缓存带入当前服务。
    @Test @MainActor func restoringCatalogUsesDiskWithoutNetworkAndIsolatesProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = LinuxDoAPIFake()
        await api.setResponse(LinuxDoResponse(
            payload: LinuxDoPayload(revision: 7, generatedAt: "", complete: true, repositories: [], promotionDates: [:]),
            etag: "catalog-v7"
        ))
        let original = LinuxDoRepository(api: api, directory: directory)
        _ = try await original.refresh(.catalog, providerID: "one")
        await api.setFailure(true)
        let store = LinuxDoStore(repository: LinuxDoRepository(api: api, directory: directory))
        await store.restoreCatalog()
        #expect(store.catalog?.payload.revision == 7)
        #expect(!store.isRefreshingCatalog)
        #expect(store.failed.isEmpty)
        #expect(await api.calls == 1)

        await api.switchProvider("two")
        await store.restoreCatalog()
        #expect(store.providerID == "two")
        #expect(store.catalog == nil)
        #expect(await api.calls == 1)
    }

    @Test func conditionalRefreshPersistsValidEmptySnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = LinuxDoAPIFake()
        let repository = LinuxDoRepository(api: api, directory: directory)
        let first = try await repository.refresh(.provenance, providerID: "one")
        #expect(first.payload.origins == [])
        await api.setResponse(LinuxDoResponse(payload: nil, etag: "v1"))
        let second = try await repository.refresh(.provenance, providerID: "one", force: true)
        #expect(second.payload.revision == 1)
        #expect(await api.lastETag == "v1")
        let restored = LinuxDoRepository(api: api, directory: directory)
        #expect(await restored.cached(.provenance, providerID: "one")?.payload.origins == [])
    }

    @Test func concurrentRefreshCoalescesAndTTLDoesNotRequestAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = LinuxDoAPIFake()
        let repository = LinuxDoRepository(api: api, directory: directory)
        async let a = repository.refresh(.provenance, providerID: "one")
        async let b = repository.refresh(.provenance, providerID: "one")
        _ = try await (a, b)
        _ = try await repository.refresh(.provenance, providerID: "one")
        #expect(await api.calls == 1)
    }

    @Test func failureAndOlderRevisionKeepLastGoodBodyAndETag() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = LinuxDoAPIFake()
        let repository = LinuxDoRepository(api: api, directory: directory)
        _ = try await repository.refresh(.provenance, providerID: "one")
        await api.setFailure(true)
        do { _ = try await repository.refresh(.provenance, providerID: "one", force: true); Issue.record("Expected failure") } catch {}
        await api.setFailure(false)
        await api.setResponse(LinuxDoResponse(payload: LinuxDoPayload(revision: 0, generatedAt: "", complete: true, origins: []), etag: "old"))
        do { _ = try await repository.refresh(.provenance, providerID: "one", force: true); Issue.record("Accepted older revision") } catch {}
        #expect(await repository.cached(.provenance, providerID: "one")?.etag == "v1")
        #expect(await repository.cached(.provenance, providerID: "two") == nil)
    }

    @Test func missingAndPartialBodiesCannotEraseSnapshot() throws {
        let partial = LinuxDoPayload(revision: 2, generatedAt: "", complete: false, origins: [])
        #expect(throws: (any Error).self) { try partial.validate(for: .provenance) }
        let absent = LinuxDoPayload(revision: 2, generatedAt: "", complete: true)
        #expect(throws: (any Error).self) { try absent.validate(for: .provenance) }
        let badURL = LinuxDoTopic(id: 1, url: "https://evil.example/", title: "Spoof", publishedAt: "", verifiedAt: "")
        #expect(badURL.safeURL == nil)
    }

    @Test @MainActor func switchingProviderClearsOldOriginsWithoutNetworkFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = LinuxDoAPIFake()
        let verified = ISO8601DateFormatter.shared.string(from: Date())
        await api.setResponse(LinuxDoResponse(payload: LinuxDoPayload(revision: 1, generatedAt: "", complete: true, origins: [LinuxDoOrigin(repoID: 42, topicCount: 2, verifiedAt: verified)]), etag: "v1"))
        let store = LinuxDoStore(repository: LinuxDoRepository(api: api, directory: directory))
        await store.refreshProvenance()
        #expect(store.origin(for: 42)?.topicCount == 2)
        await api.switchProvider("two")
        await api.setFailure(true)
        await store.providerDidChange()
        #expect(store.origin(for: 42) == nil)
        #expect(store.providerID == "two")
    }

    /// 接口顺序与帖子 ID 都不代表发布时间；重复点击应复用缓存，离线也可直接回链。
    @Test(arguments: [false, true]) @MainActor
    func discussionURLSelectsNewestAndReusesCache(reversed: Bool) async {
        let older = discussionTopic(301, publishedAt: "2026-10-18T10:00:00+02:00")
        let newer = discussionTopic(300, publishedAt: "2026-10-18T09:00:00Z")
        let fixture = await discussionStore(topics: reversed ? [newer, older] : [older, newer])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(await fixture.store.discussionURL(for: 42) == newer.safeURL)
        #expect(await fixture.api.calls == 2)
        await fixture.api.setFailure(true)
        #expect(await fixture.store.discussionURL(for: 42) == newer.safeURL)
        #expect(await fixture.api.calls == 2)
    }

    /// 同一时刻可以有不同 RFC3339 表达，仍按帖子 ID 稳定选择而非依赖数组位置。
    @Test @MainActor func discussionURLBreaksTimestampTiesByTopicID() async {
        let newerID = discussionTopic(302, publishedAt: "2026-10-18T10:00:00.000Z")
        let olderID = discussionTopic(301, publishedAt: "2026-10-18T10:00:00Z")
        let fixture = await discussionStore(topics: [newerID, olderID])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(await fixture.store.discussionURL(for: 42) == newerID.safeURL)
    }

    /// 空快照和断网都不构造猜测链接，也不清除已核验的来源；后续点击仍可重试。
    @Test(arguments: [false, true]) @MainActor
    func discussionURLReturnsNilWhenUnavailable(networkFailure: Bool) async {
        let fixture = await discussionStore(topics: [])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.api.setFailure(networkFailure)
        #expect(await fixture.store.discussionURL(for: 42) == nil)
        #expect(fixture.store.origin(for: 42) != nil)
        #expect(fixture.store.failed.contains(.topics(42)) == networkFailure)
    }

    /// 来源存在也不能绕过远端回链白名单；坏快照不应把浏览器带到任意站点。
    @Test @MainActor func discussionURLRejectsUnsafeLink() async {
        let unsafe = LinuxDoTopic(id: 301, url: "https://evil.example/", title: "Spoof", publishedAt: "", verifiedAt: "")
        let fixture = await discussionStore(topics: [unsafe])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(await fixture.store.discussionURL(for: 42) == nil)
        #expect(fixture.store.failed.contains(.topics(42)))
    }

    /// 服务切换后不能用旧服务的帖子缓存打开链接，也不能为未核验来源偷偷联网。
    @Test @MainActor func discussionURLDoesNotCrossProviderOrMissingOrigin() async {
        let fixture = await discussionStore(topics: [discussionTopic(301, publishedAt: "2026-10-18T10:00:00Z")])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(await fixture.store.discussionURL(for: 99) == nil)
        #expect(await fixture.api.calls == 1)
        #expect(await fixture.store.discussionURL(for: 42) != nil)
        await fixture.api.switchProvider("two")
        #expect(await fixture.store.discussionURL(for: 42) == nil)
        #expect(fixture.store.origin(for: 42) == nil)
        #expect(await fixture.api.calls == 2)
    }

    /// View 生命周期取消点击后，不能再请求帖子或返回可用于迟到跳转的链接。
    @Test @MainActor func cancelledDiscussionDoesNotRequestTopics() async {
        let fixture = await discussionStore(topics: [discussionTopic(301, publishedAt: "2026-10-18T10:00:00Z")])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let request = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.store.discussionURL(for: 42)
        }
        #expect(await request.value == nil)
        #expect(await fixture.api.calls == 1)
    }

    /// 每例使用独立目录与模拟 API，验证真实仓储缓存链路而不访问生产服务。
    @MainActor private func discussionStore(topics: [LinuxDoTopic]) async -> (store: LinuxDoStore, api: LinuxDoAPIFake, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let api = LinuxDoAPIFake()
        let verified = ISO8601DateFormatter.shared.string(from: Date())
        await api.setResponse(LinuxDoResponse(payload: LinuxDoPayload(revision: 1, generatedAt: "", complete: true, origins: [LinuxDoOrigin(repoID: 42, topicCount: max(1, topics.count), verifiedAt: verified)]), etag: "v1"))
        let store = LinuxDoStore(repository: LinuxDoRepository(api: api, directory: directory))
        await store.refreshProvenance()
        await api.setResponse(LinuxDoResponse(payload: LinuxDoPayload(revision: 1, generatedAt: "", complete: true, topics: topics, repoID: 42), etag: "topics-v1"))
        return (store, api, directory)
    }

    private func discussionTopic(_ id: Int64, publishedAt: String) -> LinuxDoTopic {
        LinuxDoTopic(id: id, url: "https://linux.do/t/topic/\(id)", title: "Project", publishedAt: publishedAt, verifiedAt: publishedAt)
    }
}

/// 可控异步替身，用短暂挂起制造真实 actor 重入窗口，不依赖外部网络时序。
private actor LinuxDoAPIFake: LinuxDoAPIProtocol {
    var calls = 0
    var lastETag: String?
    private var provider = "one"
    private var fails = false
    private var response = LinuxDoResponse(payload: LinuxDoPayload(revision: 1, generatedAt: "", complete: true, origins: []), etag: "v1")
    func linuxDoProviderIdentity() -> String { provider }
    func setResponse(_ response: LinuxDoResponse) { self.response = response }
    func setFailure(_ value: Bool) { fails = value }
    func switchProvider(_ value: String) { provider = value }
    func fetchLinuxDo(_ resource: LinuxDoResource, providerID: String, ifNoneMatch: String?) async throws -> LinuxDoResponse {
        calls += 1
        lastETag = ifNoneMatch
        try await Task.sleep(nanoseconds: 30_000_000)
        if fails { throw URLError(.notConnectedToInternet) }
        return response
    }
}
