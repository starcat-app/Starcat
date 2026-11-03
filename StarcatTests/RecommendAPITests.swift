//
//  RecommendAPITests.swift
//  StarcatTests
//
//  覆盖双渠道共用的 v2 路由、缓存身份与自研 ServingBundle 响应解码。
//  网络由 URLProtocolStub 截获，不依赖本地或线上推荐服务。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RecommendAPI 自研契约", .serialized)
struct RecommendAPITests {
    private let baseURL = URL(string: "https://recommend.test.invalid")!

    @Test("默认客户端只访问 v2，内容推荐没有校准分数时保持原分数")
    func defaultClientUsesV2ForContentFallback() async throws {
        let api = makeAPI()
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.path == "/api/v2/repos/42/recommendations")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "X-SC-Svc") == "recommend")
            return Self.response(for: request, body: Self.contentBody)
        }

        let page = try await api.fetchRecommendations(repoID: 42, limit: 10, offset: 0)

        #expect(page.source == "starcat_trained")
        #expect(page.fallback)
        #expect(page.modelVersion == "coverage-v20-c0123456789abcdef")
        #expect(page.items.first?.repoID == 84)
        #expect(page.items.first?.displayScore == nil)
        #expect(page.items.first?.asSemanticSearchHit().displayScore == 0.9)
    }

    @Test("自研契约使用 v2 路由并解码 ServingBundle 版本")
    func trainedBundleUsesV2Route() async throws {
        let api = makeAPI()
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
        let api = makeAPI()
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
        let api = makeAPI()
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

    private func makeAPI() -> RecommendAPI {
        URLProtocolStub.reset()
        return RecommendAPI(
            baseURL: baseURL,
            apiKey: "test-key",
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

    private static let contentBody = """
    {"schema_version":1,"data":{"source":"starcat_trained","fallback":true,"repo_id":42,"model_version":"coverage-v20-c0123456789abcdef","items":[{"repo_id":84,"full_name":"owner/content","stars":10,"forks":1,"archived":false,"score":0.9,"source":"starcat_trained","reasons":["metadata_similarity"]}],"has_more":false}}
    """

    private static let v2Body = """
    {"schema_version":1,"data":{"source":"starcat_trained","fallback":false,"repo_id":42,"model_version":"costar-real-v1","items":[{"repo_id":84,"full_name":"owner/trained","stars":10,"forks":1,"archived":false,"score":0.05,"display_score":0.956,"source":"starcat_trained","reasons":["costar","source_repo_id:42"],"signals":{"costar_score":0.05}}],"has_more":false}}
    """
}
