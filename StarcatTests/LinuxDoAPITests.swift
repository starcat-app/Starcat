//
//  LinuxDoAPITests.swift
//  StarcatTests
//
//  离线验证 Discovery 路由、条件请求、协议版本和本地来源分页，不连接真实服务。
//

import Foundation
import Testing
@testable import Starcat

@Suite(.serialized)
struct LinuxDoAPITests {
    @Test func conditionalRequestAndProviderIsolation() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.path == "/api/v1/discovery/linuxdo/provenance")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "version-one")
            return (HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: [:])!, Data())
        }
        let api = DiscoveryAPI(baseURL: URL(string: "https://linuxdo-api.test.invalid")!, apiKey: "test-key", session: URLProtocolStub.ephemeralSession())
        let provider = await api.linuxDoProviderIdentity()
        #expect(!provider.contains("test-key"))
        let response = try await api.fetchLinuxDo(.provenance, providerID: provider, ifNoneMatch: "version-one")
        #expect(response.payload == nil)
        #expect(response.etag == "version-one")
        await api.updateAPIKey("other-key")
        #expect(await api.linuxDoProviderIdentity() != provider)
        await #expect(throws: CancellationError.self) { _ = try await api.fetchLinuxDo(.provenance, providerID: provider, ifNoneMatch: nil) }
    }

    @Test func rejectsPartialAndUnsupportedResponses() async throws {
        for body in [
            #"{"schema_version":1,"data":{"revision":1,"generated_at":"","complete":true}}"#,
            #"{"schema_version":2,"data":{"revision":1,"generated_at":"","complete":true,"origins":[]}}"#,
            "<html>challenge</html>"
        ] {
            URLProtocolStub.reset()
            URLProtocolStub.requestHandler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, Data(body.utf8))
            }
            let api = DiscoveryAPI(baseURL: URL(string: "https://linuxdo-api.test.invalid")!, session: URLProtocolStub.ephemeralSession())
            let provider = await api.linuxDoProviderIdentity()
            await #expect(throws: (any Error).self) { _ = try await api.fetchLinuxDo(.provenance, providerID: provider, ifNoneMatch: nil) }
        }
    }

    /// 生产 Go 响应不带小数秒，不能让日期格式差异把非空快照误判为无效。
    @Test(arguments: ["2026-10-18T05:10:33Z", "2026-10-18T05:10:33.123Z"])
    func parsesTimestampsWithAndWithoutFractionalSeconds(timestamp: String) {
        #expect(LinuxDoPayload.date(timestamp) != nil)
    }

    @Test(arguments: ["", "not-a-date", "2026-10-18"])
    func rejectsInvalidTimestamps(timestamp: String) {
        #expect(LinuxDoPayload.date(timestamp) == nil)
    }

    /// 按线上非空响应结构走完整 API 解码与验证，避免空数组绕过日期校验。
    @Test(arguments: [LinuxDoResource.catalog, .provenance], ["2026-10-18T05:10:33Z", "2026-10-18T05:10:33.123Z"])
    func acceptsNonEmptySnapshots(resource: LinuxDoResource, timestamp: String) async throws {
        let body = resource == .catalog ? #"""
        {"schema_version":1,"data":{"revision":3,"generated_at":"2026-10-18T10:32:38Z","complete":true,
        "repositories":[{"repo_id":1308389737,"owner":"Git4Agent","name":"mallard-app","full_name":"Git4Agent/mallard-app",
        "stars":23,"forks":2,"watchers":23,"subscribers":0,"open_issues":0,"is_archived":false,"is_fork":false,"release_download_count":0}],
        "promotion_dates":{"1308389737":"\#(timestamp)"}}}
        """# : #"""
        {"schema_version":1,"data":{"revision":3,"generated_at":"2026-10-18T10:32:38Z","complete":true,
        "origins":[{"repo_id":1308389737,"topic_count":1,"verified_at":"\#(timestamp)"}]}}
        """#
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.path == "/" + resource.path)
            #expect(request.value(forHTTPHeaderField: "X-SC-Svc") == "discovery")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "revision-3"])!, Data(body.utf8))
        }
        let api = DiscoveryAPI(baseURL: URL(string: "https://linuxdo-api.test.invalid")!, session: URLProtocolStub.ephemeralSession())
        let provider = await api.linuxDoProviderIdentity()
        let response = try await api.fetchLinuxDo(resource, providerID: provider, ifNoneMatch: nil)
        let payload = try #require(response.payload)
        #expect(payload.revision == 3)
        #expect(response.etag == "revision-3")
        if resource == .catalog {
            #expect(payload.repositories?.map(\.repoID) == [1308389737])
            #expect(payload.promotionDates?["1308389737"] == timestamp)
        } else {
            #expect(payload.origins?.map(\.repoID) == [1308389737])
            #expect(payload.origins?.first?.verifiedAt == timestamp)
        }
    }

    @Test @MainActor func paginationAndPromotionOrderResetWithQueryIdentity() throws {
        let repos = try (1...95).map { id in
            let data = try JSONSerialization.data(withJSONObject: ["repo_id": id, "owner": "test", "name": "repo-\(id)", "full_name": "test/repo-\(id)", "stars": id, "forks": 0, "watchers": 0, "subscribers": 0, "open_issues": 0, "is_archived": false, "is_fork": false, "release_download_count": 0])
            return try JSONDecoder().decode(DiscoveryRepoDTO.self, from: data)
        }
        let model = LinuxDoListModel()
        model.reset(repositories: repos, promotionDates: ["1": "2026-10-15T00:00:00Z"], search: "", recentPromotionFirst: true, identity: "one")
        #expect(model.rows.count == 20)
        #expect(model.rows.first?.repoID == 1)
        let gate = RepoCardPaginationGate()
        let page = RepoCardPaginationPage(identity: model.identity, visibleItemCount: 20, loadedItemCount: 20, hasMore: true)
        gate.update(page, isLoading: false)
        for index in 9..<20 where gate.claim(page, appearingIndex: index) {
            model.loadMore()
        }
        #expect(model.rows.count == 40, "同一批 11 个尾行只推进一页")
        for _ in 0..<3 { model.loadMore() }
        #expect(model.rows.count == 95)
        #expect(!model.hasMore)
        #expect(Set(model.rows.map(\.repoID)).count == 95)
        model.reset(repositories: repos, promotionDates: [:], search: "repo-9", recentPromotionFirst: false, identity: "two")
        #expect(model.rows.count == 7)
        #expect(model.rows.first?.repoID == 95)
        #expect(model.identity == "two")
    }
}
