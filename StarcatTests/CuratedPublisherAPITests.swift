//
//  CuratedPublisherAPITests.swift
//  StarcatTests
//
//  固定 weekly-api 管理员来源、提交和批次查询的 wire contract。
//

import Foundation
import Testing
@testable import Starcat

@Suite("精选发布台 API", .serialized)
struct CuratedPublisherAPITests {
    private let baseURL = URL(string: "https://weekly.test.invalid/root/")!

    private func makeAPI() -> CuratedPublisherAPIClient {
        URLProtocolStub.reset()
        return CuratedPublisherAPIClient(
            baseURL: baseURL,
            session: URLProtocolStub.ephemeralSession()
        )
    }

    private func response(
        for request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    /// URLSession 交给 URLProtocol 时可能把 `httpBody` 转成 stream；两种形态都读取，
    /// 避免测试把 Foundation 的传输实现细节误判成客户端没有发送 JSON。
    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    @Test("动态来源请求使用 admin Bearer 并过滤不可人工导入项")
    func fetchManualSourcesBuildsContract() async throws {
        let api = makeAPI()
        URLProtocolStub.requestHandler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/root/internal/sources")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer admin-secret")
            #expect(request.value(forHTTPHeaderField: "X-SC-Svc") == "weekly")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query == [URLQueryItem(name: "manual_import", value: "true")])
            return response(for: request, status: 200, body: """
            {"schema_version":1,"data":[
              {"code":"disabled","display_name_zh":"禁用","display_name_en":"Disabled","icon_key":"xmark","sort_order":1,"count":0,"ingest_mode":"manual","enabled":false,"manual_import_enabled":true,"pending":0,"processing":0,"retrying":0,"discarded":0},
              {"code":"ai_intelligence","display_name_zh":"AI 情报","display_name_en":"AI Intelligence","icon_key":"sparkles","sort_order":20,"count":3,"ingest_mode":"manual","enabled":true,"manual_import_enabled":true,"pending":1,"processing":0,"retrying":0,"discarded":0}
            ]}
            """)
        }

        let sources = try await api.fetchManualSources(adminKey: "admin-secret")
        #expect(sources.map(\.code) == ["ai_intelligence"])
        #expect(sources.first?.displayNameZH == "AI 情报")
    }

    @Test("提交编码与 202 acceptance 解码保持一致")
    func submitBuildsContract() async throws {
        let api = makeAPI()
        URLProtocolStub.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/root/internal/imports")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer admin-secret")
            guard let body = bodyData(from: request) else {
                Issue.record("POST request should contain a JSON body")
                return response(for: request, status: 400, body: "{}")
            }
            let object = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            #expect(object["source_code"] as? String == "ai_intelligence")
            #expect(object["idempotency_key"] as? String == "idem-1")
            let repos = try #require(object["repositories"] as? [[String: Any]])
            #expect(repos.first?["owner"] as? String == "openai")
            #expect(repos.first?["source_url"] as? String == "https://example.com/article")
            return response(for: request, status: 202, body: """
            {"schema_version":1,"data":{"batch_id":"batch-1","source_code":"ai_intelligence","status":"pending","total":1,"duplicate_count":0,"created_at":"2026-08-13T00:00:00Z"}}
            """)
        }
        let request = CuratedPublisherImportRequest(
            sourceCode: "ai_intelligence",
            idempotencyKey: "idem-1",
            repositories: [
                .init(
                    owner: "openai",
                    repo: "codex",
                    title: "Codex",
                    sourceURL: "https://example.com/article"
                )
            ]
        )

        let result = try await api.submit(request, adminKey: "admin-secret")
        #expect(result.batchID == "batch-1")
        #expect(result.status == .pending)
        #expect(result.duplicateCount == 0)
    }

    @Test("批次查询解码 partial_success 与 item 错误")
    func fetchBatchDecodesTerminalDetails() async throws {
        let api = makeAPI()
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.path == "/root/internal/imports/batch-1")
            return response(for: request, status: 200, body: """
            {"schema_version":1,"data":{
              "batch_id":"batch-1","source_code":"ai_intelligence","kind":"manual_import","idempotency_key":"idem-1","status":"partial_success","total":2,"success":1,"discarded":1,"created_at":"2026-08-13T00:00:00Z","started_at":"2026-08-13T00:00:01Z","finished_at":"2026-08-13T00:00:02Z","updated_at":"2026-08-13T00:00:02Z",
              "items":[{"id":2,"owner":"missing","repo":"repo","normalized_full_name":"missing/repo","external_key":"","status":"discarded","attempts":3,"last_error_code":"NOT_FOUND","last_error_message":"repository not found"}]
            }}
            """)
        }

        let batch = try await api.fetchBatch(id: "batch-1", adminKey: "admin-secret")
        #expect(batch.status == .partialSuccess)
        #expect(batch.status.isTerminal)
        #expect(batch.items.first?.lastErrorCode == "NOT_FOUND")
    }

    @Test("401 映射为不携带密钥的专用错误")
    func unauthorizedMapsToSafeError() async {
        let api = makeAPI()
        URLProtocolStub.requestHandler = { request in
            response(for: request, status: 401, body: """
            {"schema_version":1,"error":{"code":"UNAUTHORIZED","message":"invalid bearer token"}}
            """)
        }

        do {
            _ = try await api.fetchManualSources(adminKey: "must-not-leak")
            Issue.record("Expected unauthorized error")
        } catch CuratedPublisherAPIError.unauthorized {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
