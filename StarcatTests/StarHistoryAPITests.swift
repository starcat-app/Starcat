//
//  StarHistoryAPITests.swift
//  StarcatTests
//
//  验证 History 原始事件契约、本地校准与隐私边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Star History API", .serialized)
struct StarHistoryAPITests {

    @Test("events 200 应本地校准并携带鉴权与 ETag")
    func readyEventsResponseNormalizesLocally() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"history-events-v1\""]
            )!
            let body = Data(
                """
                {
                  "schema_version": 1,
                  "data": {
                    "repo_id": 42,
                    "full_name": "octo/history",
                    "coverage_start": "2026-01-01",
                    "coverage_end": "2026-08-25",
                    "event_total": 4,
                    "generated_at": "2026-08-29T12:00:00Z",
                    "events": [
                      { "date": "2026-01-01", "count": 1 },
                      { "date": "2026-08-25", "count": 3 }
                    ]
                  }
                }
                """.utf8
            )
            return (response, body)
        }
        let api = makeAPI()

        let result = try await api.fetch(
            request: request(currentStars: 100),
            range: .all,
            ifNoneMatch: "\"history-events-v0\""
        )
        let received = try #require(URLProtocolStub.receivedRequests.first)

        guard case .ready(let series, let etag) = result else {
            Issue.record("Expected ready response")
            return
        }
        #expect(received.url?.path == "/api/v1/repos/octo/history/star-history/events")
        #expect(received.url?.query?.contains("repo_id=42") == true)
        #expect(received.url?.query?.contains("current_stars") != true)
        #expect(received.value(forHTTPHeaderField: "Authorization") == "Bearer history-key")
        #expect(received.value(forHTTPHeaderField: "X-SC-Svc") == "history")
        #expect(received.value(forHTTPHeaderField: "If-None-Match") == "\"history-events-v0\"")
        #expect(etag == "\"history-events-v1\"")
        #expect(series.repoID == 42)
        #expect(series.fullName == "octo/history")
        #expect(series.currentStars == 100)
        #expect(series.points.count == 2)
        #expect(series.points.last?.count == 100)
        #expect(series.points.map(\.source) == [.ghArchive, .ghArchive])
        #expect(series.points.map(\.precision) == [.estimated, .estimated])
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
        let privateRequest = StarHistoryRequest(
            repoID: 42,
            owner: "octo",
            name: "history",
            isPrivate: true,
            currentStars: 10
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

    @Test("本地 Normalize 应把终点锚到 currentStars")
    func normalizeAnchorsLastPointToCurrentStars() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let points = try StarHistoryCurveBuilder.normalize(
            events: [
                .init(date: StarHistoryDateCodec.date(from: "2026-01-01")!, count: 1),
                .init(date: StarHistoryDateCodec.date(from: "2026-08-25")!, count: 3)
            ],
            currentStars: 100,
            fetchedAt: fetchedAt
        )
        #expect(points.count == 2)
        #expect(points[0].count == 25)
        #expect(points[1].count == 100)
        #expect(points[0].source == .ghArchive)
        #expect(points[0].precision == .estimated)
    }

    private func makeAPI() -> StarHistoryAPI {
        StarHistoryAPI(
            baseURL: URL(string: "https://history.example.test")!,
            apiKey: "history-key",
            session: URLProtocolStub.ephemeralSession()
        )
    }

    private func request(currentStars: Int = 120) -> StarHistoryRequest {
        StarHistoryRequest(
            repoID: 42,
            owner: "octo",
            name: "history",
            isPrivate: false,
            currentStars: currentStars
        )
    }
}
