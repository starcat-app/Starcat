//
//  WikiAPITests.swift
//  StarcatTests
//
//  覆盖 starcat-wiki-api 单仓库查询的 wire contract、Bearer 注入、错误映射与热更新。
//  全部网络由 URLProtocolStub 固定返回，不依赖三个外部 Wiki 站或本地 Go 服务。
//

import Testing
import Foundation
@testable import Starcat

@Suite("WikiAPI 单仓库查询", .serialized)
struct WikiAPITests {
    private let baseURL = URL(string: "https://wiki.test.invalid")!

    private func makeAPI(apiKey: String? = "sk-test") -> WikiAPI {
        URLProtocolStub.reset()
        return WikiAPI(
            baseURL: baseURL,
            apiKey: apiKey,
            session: URLProtocolStub.ephemeralSession()
        )
    }

    private func response(for request: URLRequest, status: Int, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    @Test("GET query 与 Bearer header 正确，三种来源可解码")
    func fetchStatusBuildsRequestAndDecodesSources() async throws {
        let api = makeAPI()
        URLProtocolStub.requestHandler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            #expect(request.url?.path == "/api/v1/wikis")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
            #expect(query["owner"] == "facebook")
            #expect(query["repo"] == "react")

            return response(for: request, status: 200, body: """
            {
              "schema_version": 1,
              "data": [
                {"source":"zread","status":"indexed","url":"https://zread.ai/facebook/react","probeMethod":"json_api"},
                {"source":"deepwiki","status":"not_indexed","url":"https://deepwiki.com/facebook/react"},
                {"source":"codewiki","status":"error","url":"https://codewiki.google/github.com/facebook/react"}
              ],
              "meta": {"cache_status":"fresh"}
            }
            """)
        }

        let items = try await api.fetchStatus(owner: "facebook", repo: "react")
        #expect(items.count == 3)
        #expect(items[0].source == .zread)
        #expect(items[0].status == .indexed)
        #expect(items[1].source == .deepWiki)
        #expect(items[1].status == .notIndexed)
        #expect(items[2].source == .codeWiki)
        #expect(items[2].status == .error)
    }

    @Test("未知 source/status 不拖垮整包解码")
    func unknownValuesDecodeForwardCompatibly() async throws {
        let api = makeAPI()
        URLProtocolStub.requestHandler = { request in
            response(for: request, status: 200, body: """
            {"schema_version":1,"data":[
              {"source":"futurewiki","status":"probing_v3","url":"https://future.example/repo"},
              {"source":"zread","status":"indexed","url":"https://zread.ai/a/b"}
            ]}
            """)
        }

        let items = try await api.fetchStatus(owner: "a", repo: "b")
        #expect(items.count == 2)
        #expect(items[0].source == .unknown("futurewiki"))
        #expect(items[0].status == .unknown("probing_v3"))
        #expect(items[1].status == .indexed)
    }

    @Test("无 API Key 时不发送 Authorization")
    func omitsBearerWhenKeyMissing() async throws {
        let api = makeAPI(apiKey: nil)
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return response(for: request, status: 200, body: "{\"schema_version\":1,\"data\":[]}")
        }
        _ = try await api.fetchStatus(owner: "a", repo: "b")
    }

    @Test("非法 owner/repo 在本地拦截，不发请求")
    func invalidRepositoryIsRejectedLocally() async {
        let api = makeAPI()
        await #expect(throws: StarcatEnvelopeNetworkError.self) {
            try await api.fetchStatus(owner: "bad/owner", repo: "repo")
        }
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("401 ErrorEnvelope 保留 unauthorized 语义")
    func unauthorizedResponse() async {
        let api = makeAPI()
        URLProtocolStub.requestHandler = { request in
            response(for: request, status: 401, body: """
            {"schema_version":1,"error":{"code":"UNAUTHORIZED","message":"invalid key"}}
            """)
        }

        do {
            _ = try await api.fetchStatus(owner: "a", repo: "b")
            Issue.record("Expected unauthorized error")
        } catch let error as StarcatEnvelopeNetworkError {
            #expect(error.isUnauthorized)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("baseURL 与 API Key 热更新在下一次请求生效")
    func hotUpdatesApplyToNextRequest() async throws {
        let api = makeAPI(apiKey: "sk-old")
        await api.updateBaseURL(URL(string: "https://wiki-new.test.invalid/root")!)
        await api.updateAPIKey("sk-new")

        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.host == "wiki-new.test.invalid")
            #expect(request.url?.path == "/root/api/v1/wikis")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-new")
            return response(for: request, status: 200, body: "{\"schema_version\":1,\"data\":[]}")
        }
        _ = try await api.fetchStatus(owner: "a", repo: "b")
    }
}
