//
//  ServiceAvailabilityMonitorTests.swift
//  StarcatTests
//
//  覆盖状态栏服务可用性巡检：用 4 个服务样本并发请求 `/healthz`，再聚合成 toolbar 可读摘要。
//  设置页的 API Key / ping 校验由 `ServiceHealthCheckerTests` 覆盖，本文件只关心进程可用性。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ServiceAvailabilityMonitor", .serialized)
struct ServiceAvailabilityMonitorTests {
    private let fakeBaseURL = URL(string: "https://api.test.invalid")!

    @Test("checker 使用 /healthz 且不带 Authorization")
    func checkerHitsHealthzWithoutAuthorization() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data())
        }

        let checker = ServiceAvailabilityChecker(session: URLProtocolStub.ephemeralSession())
        let result = await checker.check(service: .trending, baseURL: fakeBaseURL)

        #expect(result.status == .available(statusCode: 200))
        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.url?.path == "/healthz")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("monitor 聚合 4 个服务的成功和失败结果")
    @MainActor
    func monitorAggregatesFourServices() async {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let serviceIsWiki = request.url?.host?.contains("wiki") == true
            let statusCode = serviceIsWiki ? 503 : 200
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data())
        }

        let checker = ServiceAvailabilityChecker(session: URLProtocolStub.ephemeralSession())
        let monitor = ServiceAvailabilityMonitor(
            checker: checker,
            services: [.trending, .weekly, .sharing, .wiki],
            interval: .seconds(600),
            baseURLProvider: { service in
                URL(string: "https://\(service.rawValue).test.invalid")!
            }
        )

        await monitor.refreshNow()

        #expect(URLProtocolStub.receivedRequests.count == 4)
        #expect(Set(URLProtocolStub.receivedRequests.compactMap(\.url?.path)) == ["/healthz"])
        #expect(monitor.summary.totalCount == 4)
        #expect(monitor.summary.availableCount == 3)
        #expect(monitor.summary.failedServices == [.wiki])
        #expect(monitor.summary.hasIssue)
    }
}
