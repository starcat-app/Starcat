//
//  AwesomeAPITests.swift
//  StarcatTests
//
//  验证 Discovery API 的 Awesome 公共契约：DTO、ETag/304、路由和错误 envelope。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Awesome Discovery API", .serialized)
struct AwesomeAPITests {

    @Test("来源目录解码卡片字段并保留 ETag")
    func sourceCatalogDecodesManagedCards() async throws {
        let api = makeAPI { request in
            let body = Data(#"""
            {"schema_version":1,"data":[{"id":"awesome-swift","display_name":"Awesome Swift","repo_full_name":"matteocrippa/awesome-swift","repo_url":"https://github.com/matteocrippa/awesome-swift","image_url":"https://example.com/awesome.png","summary_zh":"Swift 资源","summary_en":"Swift resources","featured":true,"sort_order":2,"source_stars":9012,"github_repo_count":123,"external_entry_count":4,"last_synced_at":"2026-08-24T08:00:00Z","updated_at":"2026-08-24T08:00:00Z"}],"meta":{"total":1,"generated_at":"2026-08-24T08:00:00Z"}}
            """#.utf8)
            return (Self.response(200, request: request, headers: ["ETag": "\"catalog-1\""]), body)
        }

        let result = try await api.fetchAwesomeSources()

        #expect(result.sources.first?.id == "awesome-swift")
        #expect(result.sources.first?.featured == true)
        #expect(result.sources.first?.sourceStars == 9012)
        #expect(result.sources.first?.githubRepoCount == 123)
        #expect(result.etag == "\"catalog-1\"")
        #expect(result.generatedAt == "2026-08-24T08:00:00Z")
    }

    @Test("来源目录缺少 Stars 时拒绝不完整契约")
    func sourceCatalogRejectsMissingStars() async throws {
        let api = makeAPI { request in
            let body = Data(#"{"schema_version":1,"data":[{"id":"awesome-swift","display_name":"Awesome Swift","repo_full_name":"matteocrippa/awesome-swift","repo_url":"https://github.com/matteocrippa/awesome-swift","featured":true,"sort_order":2,"github_repo_count":123,"external_entry_count":4,"updated_at":"2026-08-24T08:00:00Z"}]}"#.utf8)
            return (Self.response(200, request: request), body)
        }

        await #expect(throws: StarcatEnvelopeNetworkError.self) {
            _ = try await api.fetchAwesomeSources()
        }
    }

    @Test("条目 304 发送已有 ETag 且不要求响应体")
    func entriesNotModifiedUsesConditionalRequest() async throws {
        let api = makeAPI { request in
            (Self.response(304, request: request), Data())
        }

        let result = try await api.fetchAwesomeEntries(sourceID: "awesome-swift", ifNoneMatch: "\"entries-1\"")
        let request = try #require(URLProtocolStub.receivedRequests.first)

        #expect(request.url?.path == "/api/v1/discovery/awesome/sources/awesome-swift/entries")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"entries-1\"")
        #expect(result.notModified)
        #expect(result.snapshot == nil)
        #expect(result.etag == "\"entries-1\"")
    }

    @Test("条目 DTO 解码 GitHub 更新时间和来源证据")
    func entrySnapshotDecodesRepositoryAndEvidence() async throws {
        let api = makeAPI { request in
            let body = Data(#"""
            {"schema_version":1,"data":{"source":{"id":"swift","display_name":"Awesome Swift","updated_at":"2026-08-24T08:00:00Z"},"entries":[{"gh_repo_id":42,"owner":"apple","name":"swift","full_name":"apple/swift","description":"Language","stars":70000,"is_archived":false,"updated_at":"2026-08-23T12:34:56Z","entry_title":"Swift","entry_description":"The language","section_path":["Languages"],"entry_order":3,"source_anchor_url":"https://github.com/example/awesome#languages"}]},"meta":{"total":1,"generated_at":"2026-08-24T08:00:00Z"}}
            """#.utf8)
            return (Self.response(200, request: request), body)
        }

        let result = try await api.fetchAwesomeEntries(sourceID: "swift")
        let entry = try #require(result.snapshot?.entries.first)

        #expect(entry.ghRepoID == 42)
        #expect(entry.updatedAt == "2026-08-23T12:34:56Z")
        #expect(entry.sectionPath == ["Languages"])
        #expect(entry.entryDescription == "The language")
    }

    @Test("旧响应省略 false 归档字段时仍可解码整批条目")
    func entrySnapshotDefaultsMissingArchivedState() async throws {
        let api = makeAPI { request in
            let body = Data(#"{"schema_version":1,"data":{"source":{"id":"swift","display_name":"Awesome Swift","updated_at":"2026-08-24T08:00:00Z"},"entries":[{"gh_repo_id":42,"owner":"apple","name":"swift","full_name":"apple/swift","stars":70000,"entry_title":"Swift","section_path":[],"entry_order":1}]}}"#.utf8)
            return (Self.response(200, request: request), body)
        }

        let result = try await api.fetchAwesomeEntries(sourceID: "swift")

        #expect(result.snapshot?.entries.first?.isArchived == nil)
        #expect(result.snapshot?.entries.count == 1)
    }

    @Test("服务端错误 envelope 保留 Awesome 稳定错误码")
    func errorEnvelopePreservesAwesomeCode() async throws {
        let api = makeAPI { request in
            let body = Data(#"{"schema_version":1,"error":{"code":"AWESOME_SOURCE_NOT_FOUND","message":"source not found"}}"#.utf8)
            return (Self.response(404, request: request), body)
        }

        do {
            _ = try await api.fetchAwesomeEntries(sourceID: "missing")
            Issue.record("Expected server error")
        } catch let StarcatEnvelopeNetworkError.serverError(status, code, message) {
            #expect(status == 404)
            #expect(code == "AWESOME_SOURCE_NOT_FOUND")
            #expect(message == "source not found")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeAPI(
        handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> DiscoveryAPI {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = handler
        return DiscoveryAPI(
            baseURL: URL(string: "https://discovery.test.invalid")!,
            apiKey: "test-key",
            session: URLProtocolStub.ephemeralSession()
        )
    }

    private nonisolated static func response(
        _ status: Int,
        request: URLRequest,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
