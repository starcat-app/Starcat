//
//  AgentExternalSearchToolTests.swift
//  StarcatTests
//
//  Agent 外部搜索工具测试。
//
//  测试只覆盖 Agent tool 适配层: 输入输出、trace 状态和 payload。
//  真实 Provider、API Key、缓存和聚合策略由现有 External Search 测试覆盖,这里不打网络。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentExternalSearchTool")
@MainActor
struct AgentExternalSearchToolTests {

    @Test("external_search 输出来源 trace 和 markdown payload")
    func externalSearchReturnsSourcesAndPayload() async {
        let source = AIExternalContextSource(
            title: "GRDB docs",
            url: URL(string: "https://example.com/grdb")!,
            host: "example.com",
            provider: .exa,
            fetchedAt: "2026-07-07T00:00:00Z"
        )
        let collector = StubExternalSearchCollector(collection: AgentExternalSearchCollection(
            status: .completed,
            markdown: "<external_context source=\"Exa\">GRDB</external_context>",
            sourceItems: [source],
            querySummary: "query: GRDB",
            log: "provider=exa\ncache=miss"
        ))
        let tool = ExternalSearchAgentTool(collector: collector)
        let arguments: AgentJSONValue = .object([
            "query": .string("Swift GRDB release notes"),
            "maxResults": .number(6),
            "allowedDomains": .array([.string("https://github.com/"), .string("swift.org")]),
            "recency": .string("month"),
            "repoIDs": .array([.number(42), .number(42)])
        ])

        let result = await tool.execute(AgentToolInput(arguments: arguments, prompt: "生成周刊", context: .empty))

        #expect(result.status == .completed)
        #expect(result.output.toolName == "external_search")
        #expect(result.output.summary == "1 sources")
        #expect(result.trace.output.contains("https://example.com/grdb"))
        if case .externalContextMarkdown(let markdown) = result.payload {
            #expect(markdown.contains("GRDB"))
        } else {
            Issue.record("Expected external context markdown payload")
        }
        #expect(collector.requests == [AgentExternalSearchRequest(
            query: "Swift GRDB release notes",
            maxResults: 6,
            allowedDomains: ["github.com", "swift.org"],
            recency: "month",
            repoIDs: [42]
        )])
    }

    @Test("external_search 关闭时返回 skipped trace")
    func externalSearchDisabledReturnsSkipped() async {
        let tool = ExternalSearchAgentTool(collector: StubExternalSearchCollector(collection: AgentExternalSearchCollection(
            status: .skipped,
            markdown: "",
            sourceItems: [],
            querySummary: "externalContextEnabled=false",
            log: "External Search is disabled in Settings."
        )))

        let result = await tool.execute(AgentToolInput(
            arguments: .object(["query": .string("Swift agents")]),
            prompt: "生成周刊",
            context: .empty
        ))

        #expect(result.status == .skipped)
        #expect(result.trace.status == .skipped)
        #expect(result.output.summary == "skipped")
        #expect(result.output.log.contains("disabled"))
    }

    @Test("external_search 不会用用户 prompt 替代缺失的模型 query")
    func externalSearchRejectsMissingModelQuery() async {
        let collector = StubExternalSearchCollector(collection: AgentExternalSearchCollection(
            status: .completed,
            markdown: "unused",
            sourceItems: [],
            querySummary: "unused",
            log: "unused"
        ))
        let tool = ExternalSearchAgentTool(collector: collector)

        let result = await tool.execute(AgentToolInput(prompt: "不要拿我当搜索词", context: .empty))

        #expect(result.status == .failed)
        #expect(result.output.log.contains("non-empty query"))
        #expect(collector.requests.isEmpty)
    }

    @Test("私有仓库未授权时不会向 Provider 发出请求")
    func privateRepositoryIsBlockedBeforeNetwork() async {
        let suite = "AgentExternalSearchToolTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        settings.externalContextEnabled = true
        settings.externalSearchAllowPrivateRepos = false
        settings.externalContextProviderSelection = .exa
        settings.setExternalSearchAPIKey("exa-key", for: .exa)
        settings.markExternalSearchCredentialVerified(for: .exa)
        var providerSettings = settings.externalSearchSettings(for: .exa)
        providerSettings.isEnabled = true
        settings.setExternalSearchSettings(providerSettings, for: .exa)

        let recorder = AgentExternalSearchProviderRecorder()
        let contextProvider = ExternalSearchContextProvider(
            settings: settings,
            diskCache: nil,
            providerFactory: { providerID in
                AgentExternalSearchStubProvider(providerID: providerID, recorder: recorder)
            }
        )
        let collector = AppSettingsAgentExternalSearchCollector(
            settings: settings,
            contextProvider: contextProvider
        )
        let context = AgentRunContext(
            sourceDescription: "private repo",
            repos: [AgentRepoSnapshot(
                id: 99,
                owner: "acme",
                name: "secret",
                fullName: "acme/secret",
                description: "private roadmap",
                language: "Swift",
                starsCount: 0,
                topics: [],
                isPrivate: true,
                isStarred: true,
                starredAt: nil,
                htmlUrl: "https://github.com/acme/secret"
            )]
        )
        let request = AgentExternalSearchRequest(
            query: "acme/secret release roadmap",
            maxResults: 5,
            allowedDomains: [],
            recency: nil,
            repoIDs: [99]
        )

        let collection = await collector.collect(request: request, context: context)

        #expect(collection.status == .skipped)
        #expect(collection.log.contains("blocked private repositories"))
        #expect(recorder.requestCount == 0)
    }
}

@MainActor
private final class StubExternalSearchCollector: AgentExternalSearchCollecting {
    let collection: AgentExternalSearchCollection
    private(set) var requests: [AgentExternalSearchRequest] = []

    init(collection: AgentExternalSearchCollection) {
        self.collection = collection
    }

    func collect(request: AgentExternalSearchRequest, context: AgentRunContext) async -> AgentExternalSearchCollection {
        requests.append(request)
        return collection
    }
}

private final class AgentExternalSearchProviderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requestCount: Int { lock.withLock { count } }

    func record() {
        lock.withLock { count += 1 }
    }
}

private struct AgentExternalSearchStubProvider: ExternalSearchProvider {
    let providerID: ExternalSearchProviderID
    let recorder: AgentExternalSearchProviderRecorder

    var id: ExternalSearchProviderID { providerID }
    var capabilities: ExternalSearchCapabilities { .capabilities(for: providerID) }

    func search(_ request: ExternalSearchRequest) async throws -> ExternalSearchResponse {
        recorder.record()
        return ExternalSearchResponse(
            hits: [],
            metadata: ExternalSearchMetadata(provider: providerID, totalResults: 0)
        )
    }
}
