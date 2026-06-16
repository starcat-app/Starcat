//
//  OpenSSFScoreAPITests.swift
//  StarcatTests
//
//  覆盖 OpenSSF Scorecard 公开 API 客户端的 wire contract。
//  所有网络都由 URLProtocolStub 拦截，避免单测依赖 scorecard.dev 的实时状态。
//

import Testing
import Foundation
@testable import Starcat

@Suite("OpenSSF Scorecard API", .serialized)
struct OpenSSFScoreAPITests {
    private let baseURL = URL(string: "https://scorecard.test.invalid")!

    private func makeAPI() -> OpenSSFScoreAPI {
        URLProtocolStub.reset()
        return OpenSSFScoreAPI(baseURL: baseURL, session: URLProtocolStub.ephemeralSession())
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

    @Test("成功响应：路径、header 与 payload 解码正确")
    func fetchSuccessDecodesPayload() async throws {
        let api = makeAPI()
        URLProtocolStub.requestHandler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/projects/github.com/ossf/scorecard")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Starcat/1.0")

            return response(for: request, status: 200, body: """
            {
              "date": "2026-06-16",
              "score": 8.4,
              "checks": [
                {
                  "name": "Maintained",
                  "score": 10,
                  "reason": "30 commits found in the last 90 days",
                  "details": ["commit activity"],
                  "documentation": {
                    "short": "Determines if the project is maintained",
                    "url": "https://github.com/ossf/scorecard/blob/main/docs/checks.md#maintained"
                  }
                },
                {
                  "name": "Signed-Releases",
                  "score": -1,
                  "reason": "no releases found"
                }
              ]
            }
            """)
        }

        let result = try await api.fetch(owner: "ossf", repo: "scorecard")

        #expect(result.payload.date == "2026-06-16")
        #expect(result.payload.score == 8.4)
        #expect(result.payload.checks.count == 2)
        #expect(result.payload.checks[0].name == "Maintained")
        #expect(result.payload.checks[0].isEvaluated)
        #expect(result.payload.checks[1].isEvaluated == false)
        #expect(result.rawData.isEmpty == false)
    }

    @Test("404 映射为 notIndexed 业务态")
    func fetchNotIndexed() async {
        let api = makeAPI()
        URLProtocolStub.requestHandler = { request in
            response(for: request, status: 404, body: #"{"message":"not found"}"#)
        }

        do {
            _ = try await api.fetch(owner: "unknown", repo: "repo")
            Issue.record("Expected notIndexed error")
        } catch OpenSSFScoreAPIError.notIndexed {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("非法 owner/repo 本地拒绝，不发请求")
    func invalidRepoPartIsRejectedLocally() async {
        let api = makeAPI()

        do {
            _ = try await api.fetch(owner: "bad/owner", repo: "repo")
            Issue.record("Expected invalidURL error")
        } catch OpenSSFScoreAPIError.invalidURL {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("成功状态但 JSON 损坏时映射为 decoding")
    func invalidJSONMapsToDecodingError() async {
        let api = makeAPI()
        URLProtocolStub.requestHandler = { request in
            response(for: request, status: 200, body: "{not-json")
        }

        do {
            _ = try await api.fetch(owner: "ossf", repo: "scorecard")
            Issue.record("Expected decoding error")
        } catch OpenSSFScoreAPIError.decoding {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
