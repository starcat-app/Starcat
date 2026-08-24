//
//  GitHubStatusMonitorTests.swift
//  StarcatTests
//
//  GitHub Statuspage 契约解码、相关组件过滤与失败保留快照测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHubStatusMonitor", .serialized)
struct GitHubStatusMonitorTests {
    private let endpointURL = URL(string: "https://status.test.invalid/api/v2/summary.json")!

    @Test("API Requests 降级会标记相关故障并区分其他事件")
    func degradedAPIRequestsIsRelevantIssue() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Self.summaryData(apiStatus: "degraded_performance", includeRelevantIncident: true))
        }
        let client = GitHubStatusClient(
            session: URLProtocolStub.ephemeralSession(),
            endpointURL: endpointURL
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let snapshot = try await client.fetchSnapshot(fetchedAt: fetchedAt)

        #expect(snapshot.apiRequestsStatus == .degradedPerformance)
        #expect(snapshot.relevantIncidentCount == 1)
        #expect(snapshot.otherIncidentCount == 1)
        #expect(snapshot.hasRelevantIssue)
        #expect(snapshot.fetchedAt == fetchedAt)
        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.url == endpointURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("其他 GitHub 组件故障不会污染 Starcat toolbar")
    func unrelatedIncidentDoesNotBecomeRelevantIssue() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Self.summaryData(apiStatus: "operational", includeRelevantIncident: false))
        }
        let client = GitHubStatusClient(
            session: URLProtocolStub.ephemeralSession(),
            endpointURL: endpointURL
        )

        let snapshot = try await client.fetchSnapshot()

        #expect(snapshot.overallStatus == .critical)
        #expect(snapshot.apiRequestsStatus == .operational)
        #expect(snapshot.relevantIncidentCount == 0)
        #expect(snapshot.otherIncidentCount == 1)
        #expect(!snapshot.hasRelevantIssue)
    }

    @Test("未知 component 状态可解码且不误报故障")
    func unknownComponentStatusIsTolerated() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Self.summaryData(apiStatus: "future_status", includeRelevantIncident: false))
        }
        let client = GitHubStatusClient(
            session: URLProtocolStub.ephemeralSession(),
            endpointURL: endpointURL
        )

        let snapshot = try await client.fetchSnapshot()

        #expect(snapshot.apiRequestsStatus == .unknown)
        #expect(!snapshot.hasRelevantIssue)
    }

    @Test("刷新失败保留最后一次成功快照")
    @MainActor
    func refreshFailureKeepsLastSuccessfulSnapshot() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Self.summaryData(apiStatus: "operational", includeRelevantIncident: false))
        }
        let client = GitHubStatusClient(
            session: URLProtocolStub.ephemeralSession(),
            endpointURL: endpointURL
        )
        let monitor = GitHubStatusMonitor(client: client, interval: .seconds(600))

        await monitor.refreshNow()
        let successfulSnapshot = try #require(monitor.snapshot)

        URLProtocolStub.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        await monitor.refreshNow()

        #expect(monitor.snapshot == successfulSnapshot)
        #expect(monitor.lastRefreshFailed)
        #expect(!monitor.hasRelevantIssue)
        #expect(!monitor.isChecking)
    }

    /// 构造 Statuspage summary 的最小真实字段集合；Copilot 事件始终存在，用于验证无关事件过滤。
    private static func summaryData(apiStatus: String, includeRelevantIncident: Bool) -> Data {
        let relevantIncident = includeRelevantIncident
            ? #", {"id":"api-incident","components":[{"id":"api-requests"}]}"#
            : ""
        return Data(
            #"""
            {
              "status": {"indicator": "critical", "description": "Partial System Outage"},
              "components": [
                {"id": "api-requests", "name": "API Requests", "status": "\#(apiStatus)"},
                {"id": "copilot", "name": "Copilot", "status": "major_outage"}
              ],
              "incidents": [
                {"id": "copilot-incident", "components": [{"id": "copilot"}]}\#(relevantIncident)
              ]
            }
            """#.utf8
        )
    }
}
