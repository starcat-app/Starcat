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

        let client = ExternalSearchHTTPClient(
            session: URLProtocolStub.ephemeralSession(), retryGate: ExternalSearchRetryGate()
        )
        await #expect(throws: ExternalSearchError.rateLimited(provider: .tavily, retryAfter: 30, message: "too many requests")) {
            let _: [String: String] = try await client.perform(
                URLRequest(url: URL(string: "https://api.test.invalid/search")!), provider: .tavily
            )
        }
    }

    @Test("HTTP 网络错误保留 Provider 与 URL 错误码",
          arguments: [URLError.timedOut, .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed])
    func networkErrorsKeepCode(code: URLError.Code) async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { _ in throw URLError(code) }
        let client = ExternalSearchHTTPClient(
            session: URLProtocolStub.ephemeralSession(), retryGate: ExternalSearchRetryGate()
        )
        do {
            let _: [String: String] = try await client.perform(
                URLRequest(url: URL(string: "https://api.test.invalid/search")!), provider: .exa
            )
            Issue.record("Expected a network failure")
        } catch {
            let failure = try #require(error as? ExternalSearchError)
            #expect(failure.urlErrorCode == code.rawValue)
            #expect(failure.providerID == .exa)
            let diagnostic = SearchDiscoveryDiagnostic.failure(stage: .webSearch, error: failure)
            #expect(diagnostic.provider == .exa)
            #expect(diagnostic.urlErrorCode == code.rawValue)
            #expect(diagnostic.statusCode == nil)
        }
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("HTTP 取消原样终止，不包装成网络故障")
    func httpCancellationIsPreserved() async {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { _ in throw URLError(.cancelled) }
        let client = ExternalSearchHTTPClient(
            session: URLProtocolStub.ephemeralSession(), retryGate: ExternalSearchRetryGate()
        )
        await #expect(throws: CancellationError.self) {
            let _: [String: String] = try await client.perform(
                URLRequest(url: URL(string: "https://api.test.invalid/search")!), provider: .exa
            )
        }
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("HTTP 状态跨层进入发现诊断，鉴权与配置错误不自动重试",
          arguments: [400, 401, 402, 403, 429, 503])
    func httpStatusSurvivesDiagnostics(status: Int) async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                headerFields: ["Retry-After": "20"])!,
                Data(#"{"message":"service error"}"#.utf8)
            )
        }
        let client = ExternalSearchHTTPClient(
            session: URLProtocolStub.ephemeralSession(), retryGate: ExternalSearchRetryGate()
        )
        do {
            let _: [String: String] = try await client.perform(
                URLRequest(url: URL(string: "https://api.test.invalid/search")!), provider: .tavily
            )
            Issue.record("Expected an HTTP failure")
        } catch {
            let failure = try #require(error as? ExternalSearchError)
            let diagnostic = SearchDiscoveryDiagnostic.failure(stage: .webSearch, error: failure)
            #expect(diagnostic.statusCode == status)
            #expect(diagnostic.provider == .tavily)
            #expect(diagnostic.retryAfter == (status == 429 ? 20 : nil))
            #expect(diagnostic.settingsTarget == "ai.externalSearch")
        }
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("无效 JSON 保留成功 HTTP 状态，不成为成功搜索")
    func malformedJSONIsInvalidResponse() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("invalid json".utf8))
        }
        let client = ExternalSearchHTTPClient(
            session: URLProtocolStub.ephemeralSession(), retryGate: ExternalSearchRetryGate()
        )
        do {
            let _: [String: String] = try await client.perform(
                URLRequest(url: URL(string: "https://api.test.invalid/search")!), provider: .exa
            )
            Issue.record("Expected an invalid response")
        } catch {
            let failure = try #require(error as? ExternalSearchError)
            #expect(UserFacingError.map(failure, operation: "Search").statusCode == 200)
            if case .invalidResponse = failure {
                #expect(failure.providerID == .exa)
            } else {
                Issue.record("Expected an invalid response classification")
            }
        }
    }

    @Test("Retry-After 支持秒数与 HTTP 日期，拒绝无效值")
    func retryAfterParsesSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(HTTPRetryAfter.seconds(from: "30", now: now) == 30)
        #expect(HTTPRetryAfter.seconds(from: "Thu, 01 Jan 1970 00:01:00 GMT", now: now) == 60)
        #expect(HTTPRetryAfter.seconds(from: "Wed, 31 Dec 1969 23:59:59 GMT", now: now) == 0)
        for value in ["NaN", "inf", "-1", "invalid", ""] {
            #expect(HTTPRetryAfter.seconds(from: value, now: now) == nil)
        }
        #expect(HTTPRetryAfter.seconds(from: nil, now: now) == nil)
    }

    @Test("冷却期跨客户端阻止同 Provider 请求，其他 Provider 与到期请求可用")
    func retryGateBlocksUntilDeadline() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let firstRequest = URLProtocolStub.receivedRequests.count == 1
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: firstRequest ? 429 : 200, httpVersion: nil,
                    headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:00:30 GMT"]
                )!,
                Data((firstRequest ? #"{"message":"rate limited"}"# : #"{"status":"ok"}"#).utf8)
            )
        }
        let clock = ExternalSearchTestClock()
        let gate = ExternalSearchRetryGate(now: { clock.read() })
        let session = URLProtocolStub.ephemeralSession()
        let request = URLRequest(url: URL(string: "https://api.test.invalid/search")!)
        let first = ExternalSearchHTTPClient(session: session, retryGate: gate)
        await #expect(throws: ExternalSearchError.rateLimited(provider: .tavily, retryAfter: 30, message: "rate limited")) {
            let _: [String: String] = try await first.perform(request, provider: .tavily)
        }
        let next = ExternalSearchHTTPClient(session: session, retryGate: gate)
        await #expect(throws: ExternalSearchError.rateLimited(provider: .tavily, retryAfter: 30, message: nil)) {
            let _: [String: String] = try await next.perform(request, provider: .tavily)
        }
        #expect(URLProtocolStub.receivedRequests.count == 1)
        let _: [String: String] = try await next.perform(request, provider: .exa)
        #expect(URLProtocolStub.receivedRequests.count == 2)
        clock.advance(by: 31)
        let _: [String: String] = try await next.perform(request, provider: .tavily)
        #expect(URLProtocolStub.receivedRequests.count == 3)
    }

    @Test("AnySearch 取消、超时与网络错误保留真实分类",
          arguments: [URLError.cancelled, .timedOut, .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed])
    func anySearchTransportPreservesCode(code: URLError.Code) async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { _ in throw URLError(code) }
        let session = URLProtocolStub.ephemeralSession()
        let provider = AnySearchExternalSearchProvider(
            apiKey: nil, anonymous: true, isEnabled: true, retryGate: ExternalSearchRetryGate(),
            client: { _, _ in AnySearchClient(apiKey: nil, anonymous: true, session: session) }
        )
        do {
            _ = try await provider.search(ExternalSearchRequest(query: "query", purpose: .globalSearch))
            Issue.record("Expected a transport failure")
        } catch {
            if code == .cancelled {
                #expect(error is CancellationError)
            } else {
                let failure = try #require(error as? ExternalSearchError)
                #expect(failure.providerID == .anySearch)
                #expect(failure.urlErrorCode == code.rawValue)
            }
        }
        #expect(URLProtocolStub.receivedRequests.count == (code == .timedOut ? 2 : 1))
    }

    @Test("AnySearch HTTP 原因进入发现诊断，非暂时错误不重试",
          arguments: [400, 401, 402, 403, 404, 429, 503])
    func anySearchHTTPStatusIsPreserved(status: Int) async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                             headerFields: ["Retry-After": "20"])!,
             Data(#"{"code":40001,"message":"service error","data":null}"#.utf8))
        }
        let session = URLProtocolStub.ephemeralSession()
        let provider = AnySearchExternalSearchProvider(
            apiKey: nil, anonymous: true, isEnabled: true, retryGate: ExternalSearchRetryGate(),
            client: { _, _ in AnySearchClient(apiKey: nil, anonymous: true, session: session) }
        )
        do {
            _ = try await provider.search(ExternalSearchRequest(query: "query", purpose: .globalSearch))
            Issue.record("Expected an HTTP failure")
        } catch {
            let failure = try #require(error as? ExternalSearchError)
            let diagnostic = SearchDiscoveryDiagnostic.failure(stage: .webSearch, error: failure)
            #expect(diagnostic.statusCode == status)
            #expect(diagnostic.provider == .anySearch)
            #expect(diagnostic.retryAfter == (status == 429 ? 20 : nil))
        }
        #expect(URLProtocolStub.receivedRequests.count == (status == 503 ? 2 : 1))
    }

    @Test("AnySearch 2xx 的解析和业务失败保留 HTTP 状态", arguments: [false, true])
    func anySearchInvalidSuccessRetainsStatus(businessFailure: Bool) async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                Data((businessFailure
                    ? #"{"code":123,"message":"rejected","data":null}"#
                    : "invalid json").utf8)
            )
        }
        let session = URLProtocolStub.ephemeralSession()
        let provider = AnySearchExternalSearchProvider(
            apiKey: nil, anonymous: true, isEnabled: true, retryGate: ExternalSearchRetryGate(),
            client: { _, _ in AnySearchClient(apiKey: nil, anonymous: true, session: session) }
        )
        do {
            _ = try await provider.search(ExternalSearchRequest(query: "query", purpose: .globalSearch))
            Issue.record("Expected an invalid response")
        } catch {
            let failure = try #require(error as? ExternalSearchError)
            let diagnostic = SearchDiscoveryDiagnostic.failure(stage: .webSearch, error: failure)
            #expect(diagnostic.statusCode == 201)
            #expect(diagnostic.provider == .anySearch)
        }
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("AnySearch 限流后新建包装器仍受冷却期约束，到期恢复")
    func anySearchRetryGateSurvivesNewWrapper() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let firstRequest = URLProtocolStub.receivedRequests.count == 1
            return (
                HTTPURLResponse(url: request.url!, statusCode: firstRequest ? 429 : 200,
                                httpVersion: nil, headerFields: ["Retry-After": "30"])!,
                Data((firstRequest
                    ? #"{"code":42901,"message":"rate limited","data":null}"#
                    : #"{"code":0,"message":"ok","data":{"results":[]}}"#).utf8)
            )
        }
        let clock = ExternalSearchTestClock()
        let gate = ExternalSearchRetryGate(now: { clock.read() })
        let session = URLProtocolStub.ephemeralSession()
        let request = ExternalSearchRequest(query: "query", purpose: .globalSearch)
        func provider() -> AnySearchExternalSearchProvider {
            AnySearchExternalSearchProvider(
                apiKey: nil, anonymous: true, isEnabled: true, retryGate: gate,
                client: { _, _ in AnySearchClient(apiKey: nil, anonymous: true, session: session) }
            )
        }
        await #expect(throws: ExternalSearchError.self) { try await provider().search(request) }
        await #expect(throws: ExternalSearchError.self) { try await provider().search(request) }
        #expect(URLProtocolStub.receivedRequests.count == 1)
        clock.advance(by: 31)
        _ = try await provider().search(request)
        #expect(URLProtocolStub.receivedRequests.count == 2)
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

/// HTTP 回调和测试任务共享可控时间；锁保证 Swift 6 并发测试不会读写竞态。
private final class ExternalSearchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 0)

    func read() -> Date { lock.withLock { value } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
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
