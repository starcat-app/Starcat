//
//  StarHistoryAPITests.swift
//  StarcatTests
//
//  验证独立 History 服务的请求契约、状态码映射和隐私边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Star History API", .serialized)
struct StarHistoryAPITests {

    @Test("200 响应应携带鉴权与 ETag 并解码类型化序列")
    func readyResponseUsesExpectedContract() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"history-v1\""]
            )!
            let body = Data(
                """
                {
                  "schema_version": 1,
                  "data": {
                    "repo_id": 42,
                    "full_name": "octo/history",
                    "current_stars": 120,
                    "range": "1y",
                    "coverage_start": "2025-07-27",
                    "generated_at": "2026-07-27T08:30:00Z",
                    "points": [
                      {
                        "date": "2025-07-27",
                        "count": 80,
                        "source": "gh_archive",
                        "precision": "estimated"
                      },
                      {
                        "date": "2026-07-27",
                        "count": 120,
                        "source": "discovery_snapshot",
                        "precision": "snapshot"
                      }
                    ]
                  }
                }
                """.utf8
            )
            return (response, body)
        }
        let api = makeAPI()

        let result = try await api.fetch(
            request: request(),
            range: .oneYear,
            ifNoneMatch: "\"history-v0\""
        )
        let received = try #require(URLProtocolStub.receivedRequests.first)

        guard case .ready(let series, let etag) = result else {
            Issue.record("Expected ready response")
            return
        }
        #expect(received.url?.path == "/api/v1/repos/octo/history/star-history")
        #expect(received.url?.query?.contains("repo_id=42") == true)
        #expect(received.url?.query?.contains("range=1y") == true)
        #expect(received.value(forHTTPHeaderField: "Authorization") == "Bearer discovery-key")
        #expect(received.value(forHTTPHeaderField: "X-SC-Svc") == "history")
        #expect(received.value(forHTTPHeaderField: "If-None-Match") == "\"history-v0\"")
        #expect(etag == "\"history-v1\"")
        #expect(series.repoID == 42)
        #expect(series.fullName == "octo/history")
        #expect(series.currentStars == 120)
        #expect(series.points.map(\.source) == [.ghArchive, .discoverySnapshot])
        #expect(series.points.map(\.precision) == [.estimated, .snapshot])
    }

    @Test("202 与 304 应作为协议内状态返回")
    func buildingAndNotModifiedAreProtocolStates() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 202,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "7"]
            )!
            return (response, Data())
        }
        let api = makeAPI()
        let building = try await api.fetch(
            request: request(),
            range: .threeMonths,
            ifNoneMatch: nil
        )
        #expect(building == .building(retryAfter: 7))

        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"history-v2\""]
            )!
            return (response, Data())
        }
        let notModified = try await api.fetch(
            request: request(),
            range: .all,
            ifNoneMatch: "\"history-v1\""
        )
        #expect(notModified == .notModified(etag: "\"history-v2\""))
    }

    @Test("固定错误状态码应映射为稳定领域错误")
    func fixedStatusCodesMapToStableErrors() async throws {
        let cases: [(Int, [String: String], StarHistoryAPIError)] = [
            (400, [:], .invalidRepository),
            (401, [:], .unauthorized),
            (404, [:], .repositoryNotFound),
            (409, [:], .repositoryIDMismatch),
            (422, [:], .privateRepository),
            (429, ["Retry-After": "9"], .rateLimited(retryAfter: 9)),
            (503, [:], .providerUnavailable)
        ]

        for (statusCode, headers, expected) in cases {
            URLProtocolStub.reset()
            URLProtocolStub.requestHandler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                let body = Data(
                    #"{"schema_version":1,"error":{"code":"TEST","message":"stub error"}}"#.utf8
                )
                return (response, body)
            }
            do {
                _ = try await makeAPI().fetch(
                    request: request(),
                    range: .oneYear,
                    ifNoneMatch: nil
                )
                Issue.record("Expected \(expected) for HTTP \(statusCode)")
            } catch let error as StarHistoryAPIError {
                #expect(error == expected)
            }
        }
    }

    @Test("私有仓库应在构造网络请求前拒绝")
    func privateRepositoryNeverLeavesDevice() async throws {
        URLProtocolStub.reset()
        var privateRequest = request()
        privateRequest = StarHistoryRequest(
            repoID: privateRequest.repoID,
            owner: privateRequest.owner,
            name: privateRequest.name,
            isPrivate: true
        )

        do {
            _ = try await makeAPI().fetch(
                request: privateRequest,
                range: .oneYear,
                ifNoneMatch: nil
            )
            Issue.record("Expected private repository rejection")
        } catch let error as StarHistoryAPIError {
            #expect(error == .privateRepository)
        }
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    private func makeAPI() -> StarHistoryAPI {
        StarHistoryAPI(
            baseURL: URL(string: "https://discovery.example.test")!,
            apiKey: "discovery-key",
            session: URLProtocolStub.ephemeralSession()
        )
    }

    private func request() -> StarHistoryRequest {
        StarHistoryRequest(repoID: 42, owner: "octo", name: "history", isPrivate: false)
    }
}
