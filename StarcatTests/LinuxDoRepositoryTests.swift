//
//  LinuxDoRepositoryTests.swift
//  StarcatTests
//
//  离线验证来源缓存与分页契约；所有文件都在临时目录，不连接 Linux.do 或真实后端。
//

import CryptoKit
import Foundation
import Testing
@testable import Starcat

struct LinuxDoRepositoryTests {
    /// 启动预恢复直接使用已落盘目录，既不发请求，也不把其他服务的缓存带入当前服务。
    @Test @MainActor func restoringCatalogUsesDiskWithoutNetworkAndIsolatesProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = LinuxDoAPIFake()
        let payload = try makeLinuxDoCatalog(languages: Array(repeating: "Swift", count: 45), revision: 7)
        let original = LinuxDoCachedSnapshot(providerID: "one", payload: payload, etag: "catalog-v7", checkedAt: Date())
        let key = SHA256.hash(data: Data("one/\(LinuxDoResource.catalog.path)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let legacyFile = directory.appendingPathComponent(key + ".json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(original).write(to: legacyFile)
        await api.setFailure(true)
        let store = LinuxDoStore(repository: LinuxDoRepository(api: api, directory: directory))
        await store.restoreCatalog()
        #expect(store.catalog?.metadata == LinuxDoCacheMetadata(revision: 7, etag: "catalog-v7", checkedAt: original.checkedAt))
        #expect(store.total == 45)
        let catalogKey = try #require(store.catalogKey)
        let page = try #require(try await store.page(key: catalogKey, query: .init(), memberships: [], limit: 20))
        #expect(page.rows.count == 20)
        #expect(!FileManager.default.fileExists(atPath: legacyFile.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cache.sqlite").path))
        #expect(!store.isRefreshingCatalog)
        #expect(!store.catalogFailed)
        #expect(await api.calls == 0)

        await api.switchProvider("two")
        await store.restoreCatalog()
        #expect(store.providerID == "two")
        #expect(store.catalog == nil)
        #expect(await api.calls == 0)
        let reopened = LinuxDoRepository(api: api, directory: directory)
        #expect(try await reopened.catalogSummary(providerID: "one")?.total == 45)
    }

    @Test func conditionalRefreshPersistsValidEmptySnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = LinuxDoAPIFake()
        let repository = LinuxDoRepository(api: api, directory: directory)
        let first = try await repository.refresh(.provenance, providerID: "one")
        #expect(first.revision == 1)
        await api.setResponse(LinuxDoResponse(payload: nil, etag: "v1"))
        let second = try await repository.refresh(.provenance, providerID: "one", force: true)
        #expect(second.revision == 1)
        #expect(await api.lastETag == "v1")
        let restored = LinuxDoRepository(api: api, directory: directory)
        #expect(try await restored.cached(.provenance, providerID: "one")?.revision == 1)
        #expect(try await restored.verifiedIDs([42], providerID: "one").isEmpty)
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
        #expect(try await repository.cached(.provenance, providerID: "one")?.etag == "v1")
        #expect(try await repository.cached(.provenance, providerID: "two") == nil)
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
        let originalKey = try #require(store.provenanceKey)
        #expect(await store.verifiedIDs([42, 43], key: originalKey) == [42])
        await api.switchProvider("two")
        await api.setFailure(true)
        await store.providerDidChange()
        #expect(store.provenanceKey == nil)
        #expect(await store.verifiedIDs([42], key: originalKey).isEmpty)
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
        if let key = fixture.store.provenanceKey {
            #expect(await fixture.store.verifiedIDs([42], key: key) == [42])
        } else {
            Issue.record("Expected verified source after discussion lookup")
        }
    }

    /// 来源存在也不能绕过远端回链白名单；坏快照不应把浏览器带到任意站点。
    @Test @MainActor func discussionURLRejectsUnsafeLink() async {
        let unsafe = LinuxDoTopic(id: 301, url: "https://evil.example/", title: "Spoof", publishedAt: "", verifiedAt: "")
        let fixture = await discussionStore(topics: [unsafe])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(await fixture.store.discussionURL(for: 42) == nil)
        #expect(await fixture.api.calls == 2)
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
        #expect(await fixture.api.calls == 2)
    }

    /// 模拟来源接口不可用。目录、真实分页闸门和徽章展示策略仍只依赖目录快照。
    @Test @MainActor func catalogLoadsTwentyBadgesWithoutProvenanceAndAppendsOnce() async throws {
        let fixture = try await makeLinuxDoFixture(languages: Array(repeating: "Swift", count: 95))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.api.failProvenance()
        let model = LinuxDoListModel()
        let key = try #require(fixture.store.catalogKey)
        let request = LinuxDoListRequest(key: key, query: LinuxDoListQuery(base: .init()))
        await model.update(request, store: fixture.store)
        #expect(model.rows.count == 20)
        #expect(model.total == 95)
        func verifyMembership() -> Bool {
            Issue.record("Catalog badge requested cross-category membership")
            return false
        }
        #expect(model.rows.filter { _ in LinuxDoListModel.badgeSource.isVisible(verified: verifyMembership()) }.count == 20)
        let gate = RepoCardPaginationGate()
        let page = RepoCardPaginationPage(identity: "linuxdo", visibleItemCount: 20, loadedItemCount: 20, hasMore: true)
        gate.update(page, isLoading: false)
        #expect(!gate.claim(page, appearingIndex: 8))
        for index in 9..<20 where gate.claim(page, appearingIndex: index) {
            await model.loadMore(requested: request, store: fixture.store)
        }
        #expect(model.rows.count == 40)
        #expect(Set(model.rows.map(\.repoID)).count == 40)
        #expect(await fixture.api.resources == [.catalog])
        #expect(fixture.store.provenanceKey == nil)
    }

    /// 相同发布版本不改正文。升级版本对同一 ID 更新，并仅从本服务删除权威撤回的仓库。
    @Test func revalidationKeepsExistingBodyAndNewRevisionReplacesMembership() async throws {
        let fixture = try await makeLinuxDoFixture(languages: ["Go", "Rust", "Swift"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = fixture.repository
        let oldKey = LinuxDoCatalogKey(providerID: "one", revision: 1)
        let initial = try #require(try await repository.page(key: oldKey, query: .init()))
        await fixture.api.setResponse(LinuxDoResponse(payload: nil, etag: nil))
        let validation = try await repository.refresh(.catalog, providerID: "one", force: true)
        #expect(validation.etag == "catalog-v1")
        #expect(await fixture.api.lastETag == "catalog-v1")
        let same = try makeLinuxDoCatalog(languages: ["Python"], revision: 1)
        await fixture.api.setResponse(LinuxDoResponse(payload: same, etag: "same-version"))
        _ = try await repository.refresh(.catalog, providerID: "one", force: true)
        #expect(try await repository.page(key: oldKey, query: .init())?.rows == initial.rows)

        let replacement = try makeLinuxDoCatalog(languages: ["Python", "Go"], revision: 2)
        await fixture.api.setResponse(LinuxDoResponse(payload: replacement, etag: "catalog-v2"))
        _ = try await repository.refresh(.catalog, providerID: "one", force: true)
        #expect(try await repository.page(key: oldKey, query: .init()) == nil)
        let newKey = LinuxDoCatalogKey(providerID: "one", revision: 2)
        #expect(try await repository.page(key: newKey, query: .init())?.rows.map(\.language) == ["Go", "Python"])
        #expect(try await repository.catalogSummary(providerID: "two") == nil)
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
actor LinuxDoAPIFake: LinuxDoAPIProtocol {
    var calls = 0
    var resources: [LinuxDoResource] = []
    var lastETag: String?
    private var provider = "one"
    private var fails = false
    private var provenanceFails = false
    private var response = LinuxDoResponse(payload: LinuxDoPayload(revision: 1, generatedAt: "", complete: true, origins: []), etag: "v1")
    func linuxDoProviderIdentity() -> String { provider }
    func setResponse(_ response: LinuxDoResponse) { self.response = response }
    func setFailure(_ value: Bool) { fails = value }
    func failProvenance() { provenanceFails = true }
    func switchProvider(_ value: String) { provider = value }
    func fetchLinuxDo(_ resource: LinuxDoResource, providerID: String, ifNoneMatch: String?) async throws -> LinuxDoResponse {
        calls += 1
        resources.append(resource)
        lastETag = ifNoneMatch
        try await Task.sleep(nanoseconds: 30_000_000)
        if fails || (provenanceFails && resource == .provenance) { throw URLError(.notConnectedToInternet) }
        return response
    }
}

/// 测试目录从 DTO 解码，使用和生产一致的字段与发行版本。
func makeLinuxDoCatalog(languages: [String?], revision: Int64 = 1, promotions: [String: String] = [:]) throws -> LinuxDoPayload {
    let repos = try languages.enumerated().map { index, language in
        var fields: [String: Any] = [
            "repo_id": index + 1, "owner": "test", "name": "repo-\(index)", "full_name": "test/repo-\(index)",
            "stars": index, "forks": 0, "watchers": 0, "subscribers": 0, "open_issues": 0,
            "is_archived": false, "is_fork": false, "release_download_count": 0,
        ]
        if let language { fields["language"] = language }
        return try JSONDecoder().decode(DiscoveryRepoDTO.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    let dates = Dictionary(uniqueKeysWithValues: repos.map {
        let id = String($0.repoID)
        return (id, promotions[id] ?? "2026-11-15T00:00:00Z")
    })
    return LinuxDoPayload(revision: revision, generatedAt: "", complete: true, repositories: repos, promotionDates: dates)
}

/// 测试之间隔离服务、磁盘目录和观察状态。
@MainActor
func makeLinuxDoFixture(languages: [String?], promotions: [String: String] = [:]) async throws
    -> (store: LinuxDoStore, repository: LinuxDoRepository, api: LinuxDoAPIFake, directory: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let api = LinuxDoAPIFake()
    let payload = try makeLinuxDoCatalog(languages: languages, promotions: promotions)
    await api.setResponse(LinuxDoResponse(payload: payload, etag: "catalog-v1"))
    let repository = LinuxDoRepository(api: api, directory: directory)
    let store = LinuxDoStore(repository: repository)
    await store.refreshCatalog()
    return (store, repository, api, directory)
}
