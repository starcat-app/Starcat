//
//  RecommendAPITests.swift
//  StarcatTests
//
//  覆盖 Recommend API v1/v2 路由选择与自研 ServingBundle 响应解码。
//  网络由 URLProtocolStub 截获，不依赖本地或线上推荐服务。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RecommendAPI v1/v2 契约", .serialized)
struct RecommendAPITests {
    private let baseURL = URL(string: "https://recommend.test.invalid")!

    @Test("SimRepo 契约保持 v1 路由和无模型版本响应")
    func simRepoUsesV1Route() async throws {
        let api = makeAPI(contract: .simRepoV1)
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.path == "/api/v1/repos/42/recommendations")
            return Self.response(for: request, body: Self.v1Body)
        }

        let page = try await api.fetchRecommendations(repoID: 42, limit: 10, offset: 0)

        #expect(page.source == "simrepo")
        #expect(page.modelVersion == nil)
        #expect(page.items.first?.repoID == 84)
        #expect(page.items.first?.displayScore == nil)
        #expect(page.items.first?.asSemanticSearchHit().displayScore == 0.9)
    }

    @Test("自研契约使用 v2 路由并解码 ServingBundle 版本")
    func trainedBundleUsesV2Route() async throws {
        let api = makeAPI(contract: .trainedV2)
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.path == "/api/v2/repos/42/recommendations")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "limit", value: "7")))
            #expect(query.contains(URLQueryItem(name: "offset", value: "3")))
            return Self.response(for: request, body: Self.v2Body)
        }

        let page = try await api.fetchRecommendations(repoID: 42, limit: 7, offset: 3)

        #expect(page.source == "starcat_trained")
        #expect(page.modelVersion == "costar-real-v1")
        #expect(page.items.first?.source == "starcat_trained")
        #expect(page.items.first?.reasons == ["costar", "source_repo_id:42"])
        #expect(page.items.first?.displayScore == 0.956)
        #expect(page.items.first?.asSemanticSearchHit().displayScore == 0.956)
        let cacheScope = await api.recommendationCacheScope()
        #expect(cacheScope == "trained-v2-display-score-v1|https://recommend.test.invalid")
    }

    @Test("自研缓存按模型版本发送 ETag 并接受 304")
    func trainedBundleRevalidatesWithModelVersionETag() async throws {
        let api = makeAPI(contract: .trainedV2)
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"recommendation:costar-real-v1:42:10:0\"")
            return Self.response(for: request, body: "", statusCode: 304)
        }

        let result = try await api.revalidateRecommendations(
            repoID: 42,
            limit: 10,
            offset: 0,
            cachedModelVersion: "costar-real-v1"
        )

        guard case .notModified = result else {
            Issue.record("同一模型版本应返回 notModified")
            return
        }
    }

    @Test("服务端模型升级后条件请求返回新页面")
    func trainedBundleRevalidationReturnsNewModel() async throws {
        let api = makeAPI(contract: .trainedV2)
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"recommendation:costar-old-v1:42:10:0\"")
            return Self.response(for: request, body: Self.v2Body)
        }

        let result = try await api.revalidateRecommendations(
            repoID: 42,
            limit: 10,
            offset: 0,
            cachedModelVersion: "costar-old-v1"
        )

        guard case .modified(let page) = result else {
            Issue.record("模型升级后应返回 modified 页面")
            return
        }
        #expect(page.modelVersion == "costar-real-v1")
    }

    private func makeAPI(contract: RecommendationAPIContract) -> RecommendAPI {
        URLProtocolStub.reset()
        return RecommendAPI(
            baseURL: baseURL,
            apiKey: "test-key",
            contract: contract,
            session: URLProtocolStub.ephemeralSession()
        )
    }

    private static func response(
        for request: URLRequest,
        body: String,
        statusCode: Int = 200
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private static let v1Body = """
    {"schema_version":1,"data":{"source":"simrepo","fallback":false,"repo_id":42,"items":[{"repo_id":84,"full_name":"owner/simrepo","stars":10,"forks":1,"archived":false,"score":0.9,"source":"simrepo","reasons":[]}],"has_more":false}}
    """

    private static let v2Body = """
    {"schema_version":1,"data":{"source":"starcat_trained","fallback":false,"repo_id":42,"model_version":"costar-real-v1","items":[{"repo_id":84,"full_name":"owner/trained","stars":10,"forks":1,"archived":false,"score":0.05,"display_score":0.956,"source":"starcat_trained","reasons":["costar","source_repo_id:42"],"signals":{"costar_score":0.05}}],"has_more":false}}
    """
}
