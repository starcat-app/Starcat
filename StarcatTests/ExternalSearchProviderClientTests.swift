//
//  ExternalSearchProviderClientTests.swift
//  StarcatTests
//
//  覆盖 External Search Provider 的 HTTP 接入边界。
//
//  这些测试全部通过 `URLProtocolStub` 拦截请求，不访问真实第三方服务，也不会消耗
//  Tavily / Exa / Brave / AnySearch 的搜索额度。
//

import Foundation
import Testing
@testable import Starcat

@Suite("External Search Provider Clients", .serialized)
struct ExternalSearchProviderClientTests {
    @Test("Tavily 使用 Bearer header 并映射 results")
    func tavilyHeaderBodyAndDecode() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.absoluteString == "https://api.test.invalid/search")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tvly-key")
            let body = try #require(request.httpBodyJSON)
            #expect(body["query"] as? String == "who is dong4j")
            #expect(body["max_results"] as? Int == 1)
            #expect(body["include_raw_content"] as? Bool == true)
            #expect(body["include_domains"] as? [String] == ["example.com"])
            #expect(body["time_range"] as? String == "week")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "results": [
                    {
                      "title": "Dong4j",
                      "url": "https://example.com/dong4j",
                      "content": "snippet",
                      "raw_content": "full text",
                      "score": 0.9
                    }
                  ],
                  "response_time": 0.12,
                  "request_id": "tvly-1"
                }
                """.utf8)
            )
        }

        let provider = TavilySearchProvider(
            apiKey: "tvly-key",
            isEnabled: true,
            baseURL: URL(string: "https://api.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )
        let response = try await provider.search(ExternalSearchRequest(
            query: "who is dong4j",
            purpose: .credentialTest,
            maxResults: 1,
            freshness: "week",
            includeDomains: ["example.com"]
        ))

        #expect(response.metadata.provider == .tavily)
        #expect(response.metadata.requestID == "tvly-1")
        #expect(response.metadata.searchTimeMs == 120)
        #expect(response.hits.first?.title == "Dong4j")
        #expect(response.hits.first?.extractedText == "full text")
    }

    @Test("Exa 使用 x-api-key 并映射 text/highlights/summary")
    func exaHeaderBodyAndDecode() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.absoluteString == "https://api.test.invalid/search")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "exa-key")
            let body = try #require(request.httpBodyJSON)
            #expect(body["query"] as? String == "swift search")
            #expect(body["num_results"] as? Int == 2)
            #expect(body["include_domains"] as? [String] == ["swift.org"])
            #expect(body["start_published_date"] as? String != nil)
            let contents = try #require(body["contents"] as? [String: Any])
            #expect(contents["text"] as? Bool == true)
            #expect(contents["highlights"] as? Bool == true)
            #expect(contents["summary"] as? Bool == true)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "results": [
                    {
                      "id": "doc-1",
                      "title": "Swift Search",
                      "url": "https://example.com/swift",
                      "published_date": "2026-07-03T10:00:00.000Z",
                      "text": "clean page text",
                      "highlights": ["highlight"],
                      "summary": "summary",
                      "highlight_scores": [0.8]
                    }
                  ],
                  "request_id": "exa-1"
                }
                """.utf8)
            )
        }

        let provider = ExaSearchProvider(
            apiKey: "exa-key",
            isEnabled: true,
            baseURL: URL(string: "https://api.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )
        let response = try await provider.search(ExternalSearchRequest(
            query: "swift search",
            purpose: .globalSearch,
            maxResults: 2,
            freshness: "month",
            includeDomains: ["swift.org"]
        ))

        #expect(response.metadata.provider == .exa)
        #expect(response.metadata.requestID == "exa-1")
        #expect(response.hits.first?.id == "doc-1")
        #expect(response.hits.first?.snippet == "summary")
        #expect(response.hits.first?.extractedText == "clean page text")
    }

    @Test("Brave LLM Context 使用 X-Subscription-Token 并映射 grounding")
    func braveHeaderQueryAndDecode() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.host == "api.test.invalid")
            #expect(request.url?.path == "/res/v1/llm/context")
            #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == "brave-key")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            #expect(components?.queryItems?.first(where: { $0.name == "q" })?.value == "llm context (site:swift.org OR site:github.com)")
            #expect(components?.queryItems?.first(where: { $0.name == "count" })?.value == "3")
            #expect(components?.queryItems?.first(where: { $0.name == "freshness" })?.value == "pd")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "grounding": {
                    "generic": [
                      {
                        "title": "Context result",
                        "url": "https://example.com/context",
                        "snippets": [
                          {"text": "snippet one"},
                          {"text": "snippet two"}
                        ]
                      }
                    ]
                  },
                  "sources": {
                    "https://example.com/context": {
                      "title": "Context source",
                      "url": "https://example.com/context",
                      "site_name": "Example"
                    }
                  }
                }
                """.utf8)
            )
        }

        let provider = BraveLLMContextSearchProvider(
            apiKey: "brave-key",
            isEnabled: true,
            baseURL: URL(string: "https://api.test.invalid/res/v1/llm/context")!,
            session: URLProtocolStub.ephemeralSession()
        )
        let response = try await provider.search(ExternalSearchRequest(
            query: "llm context",
            purpose: .aiContext,
            maxResults: 3,
            freshness: "day",
            includeDomains: ["swift.org", "github.com"]
        ))

        #expect(response.metadata.provider == .braveLLMContext)
        #expect(response.hits.first?.title == "Context result")
        #expect(response.hits.first?.snippet == "snippet one")
        #expect(response.hits.first?.extractedText == "snippet one\n\nsnippet two")
    }

    @Test("HTTP 状态码映射为统一 ExternalSearchError")
    func httpStatusMapsToUnifiedError() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "30"]
                )!,
                Data(#"{"message":"too many requests"}"#.utf8)
            )
        }

        let provider = TavilySearchProvider(
            apiKey: "tvly-key",
            isEnabled: true,
            baseURL: URL(string: "https://api.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )

        await #expect(throws: ExternalSearchError.rateLimited(provider: .tavily, retryAfter: 30, message: "too many requests")) {
            _ = try await provider.search(ExternalSearchRequest(query: "rate", purpose: .globalSearch))
        }
    }

    @Test("Provider disabled 和 missing key 不发网络")
    func disabledAndMissingKeyFailBeforeNetwork() async throws {
        URLProtocolStub.reset()
        let disabled = ExaSearchProvider(apiKey: "exa-key", isEnabled: false, session: URLProtocolStub.ephemeralSession())
        await #expect(throws: ExternalSearchError.disabled(provider: .exa)) {
            _ = try await disabled.search(ExternalSearchRequest(query: "x", purpose: .globalSearch))
        }

        let missing = BraveLLMContextSearchProvider(apiKey: nil, isEnabled: true, session: URLProtocolStub.ephemeralSession())
        await #expect(throws: ExternalSearchError.missingAPIKey(provider: .braveLLMContext)) {
            _ = try await missing.search(ExternalSearchRequest(query: "x", purpose: .globalSearch))
        }
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("AnySearch wrapper 匿名模式不要求 API Key，Bearer 模式要求 Key")
    func anySearchWrapperCredentialRules() async throws {
        let resultURL = try #require(URL(string: "https://example.com/any"))
        let anonymous = AnySearchExternalSearchProvider(
            apiKey: nil,
            anonymous: true,
            isEnabled: true,
            client: { _, _ in
                StubAnySearchClient(response: AnySearchResponse(
                    results: [
                        AnySearchResult(
                            title: "Any",
                            url: resultURL,
                            normalizedURL: resultURL,
                            snippet: "snippet",
                            content: "content",
                            sourceDomain: "example.com"
                        )
                    ],
                    metadata: AnySearchMetadata(requestId: "any-1", totalResults: 1, searchTimeMs: 10),
                    rateLimit: nil
                ))
            }
        )

        let response = try await anonymous.search(ExternalSearchRequest(query: "any", purpose: .globalSearch))
        #expect(response.metadata.provider == .anySearch)
        #expect(response.hits.first?.extractedText == "content")

        let bearer = AnySearchExternalSearchProvider(apiKey: nil, anonymous: false, isEnabled: true)
        await #expect(throws: ExternalSearchError.missingAPIKey(provider: .anySearch)) {
            _ = try await bearer.search(ExternalSearchRequest(query: "any", purpose: .globalSearch))
        }
    }

    @Test("Firecrawl 使用 Bearer header + camelCase body 并映射 web results")
    func firecrawlHeaderBodyAndDecode() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.absoluteString == "https://api.test.invalid/v2/search")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fc-key")
            let body = try #require(request.httpBodyJSON)
            #expect(body["query"] as? String == "who is dong4j")
            #expect(body["limit"] as? Int == 2)
            // Firecrawl body 用 camelCase，与 Tavily 的 snake_case 不同。
            #expect(body["includeDomains"] as? [String] == ["example.com"])
            #expect(body["excludeDomains"] as? [String] == ["bad.com"])
            let scrapeOptions = try #require(body["scrapeOptions"] as? [String: Any])
            #expect(scrapeOptions["formats"] as? [String] == ["markdown"])
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "success": true,
                  "data": {
                    "web": [
                      {
                        "url": "https://example.com/dong4j",
                        "title": "Dong4j",
                        "description": "snippet",
                        "markdown": "# full markdown"
                      }
                    ]
                  }
                }
                """.utf8)
            )
        }

        let provider = FirecrawlSearchProvider(
            apiKey: "fc-key",
            isEnabled: true,
            fetchFullText: true,
            baseURL: URL(string: "https://api.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )
        let response = try await provider.search(ExternalSearchRequest(
            query: "who is dong4j",
            purpose: .credentialTest,
            maxResults: 2,
            includeDomains: ["example.com"],
            excludeDomains: ["bad.com"]
        ))

        #expect(response.metadata.provider == .firecrawl)
        #expect(response.metadata.totalResults == 1)
        #expect(response.hits.first?.title == "Dong4j")
        #expect(response.hits.first?.snippet == "snippet")
        #expect(response.hits.first?.extractedText == "# full markdown")
    }

    @Test("Firecrawl missing key 不发网络")
    func firecrawlMissingKeyFailsBeforeNetwork() async throws {
        URLProtocolStub.reset()
        let missing = FirecrawlSearchProvider(apiKey: nil, isEnabled: true, session: URLProtocolStub.ephemeralSession())
        await #expect(throws: ExternalSearchError.missingAPIKey(provider: .firecrawl)) {
            _ = try await missing.search(ExternalSearchRequest(query: "x", purpose: .globalSearch))
        }
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("Firecrawl 默认不请求全文 markdown")
    func firecrawlOmitsScrapeOptionsByDefault() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let body = try #require(request.httpBodyJSON)
            #expect(body["scrapeOptions"] == nil)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"success":true,"data":{"web":[]}}"#.utf8)
            )
        }

        let provider = FirecrawlSearchProvider(
            apiKey: "fc-key",
            isEnabled: true,
            baseURL: URL(string: "https://api.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )
        _ = try await provider.search(ExternalSearchRequest(query: "x", purpose: .globalSearch))
    }

    @Test("Registry 为 .firecrawl 返回 FirecrawlSearchProvider 及能力")
    func registryWiresFirecrawl() {
        let registry = ExternalSearchRegistry(
            settingsSnapshot: ExternalSearchRegistry.SettingsSnapshot(
                providerSettings: [.firecrawl: ExternalSearchProviderSettings(isEnabled: true)],
                apiKeys: [.firecrawl: "fc-key"]
            )
        )
        let provider = registry.provider(for: .firecrawl)
        #expect(provider.id == .firecrawl)
        #expect(provider.capabilities.supportsAnonymous == true)
        #expect(provider.capabilities.supportsDomainFilters == true)
        #expect(provider.capabilities.supportsExtractedText == true)
    }

    @Test("Firecrawl 匿名模式不要求 API Key、不传 Authorization")
    func firecrawlAnonymousRequiresNoKey() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"success":true,"data":{"web":[]}}"#.utf8)
            )
        }

        let anonymous = FirecrawlSearchProvider(
            apiKey: nil,
            isEnabled: true,
            anonymous: true,
            baseURL: URL(string: "https://api.test.invalid")!,
            session: URLProtocolStub.ephemeralSession()
        )
        let response = try await anonymous.search(ExternalSearchRequest(query: "x", purpose: .globalSearch))
        #expect(response.metadata.provider == .firecrawl)
        #expect(response.hits.isEmpty)
    }
}

private struct StubAnySearchClient: AnySearchClientProtocol {
    let response: AnySearchResponse

    func search(_ request: AnySearchRequest) async throws -> AnySearchResponse {
        response
    }
}

private extension URLRequest {
    var httpBodyJSON: [String: Any]? {
        guard let data = httpBodyData,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private var httpBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
