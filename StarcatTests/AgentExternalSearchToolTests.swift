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

    @Test("external.search 输出来源 trace 和 markdown payload")
    func externalSearchReturnsSourcesAndPayload() async {
        let source = AIExternalContextSource(
            title: "GRDB docs",
            url: URL(string: "https://example.com/grdb")!,
            host: "example.com",
            provider: .exa,
            fetchedAt: "2026-07-07T00:00:00Z"
        )
        let tool = ExternalSearchAgentTool(collector: StubExternalSearchCollector(collection: AgentExternalSearchCollection(
            status: .completed,
            markdown: "<external_context source=\"Exa\">GRDB</external_context>",
            sourceItems: [source],
            querySummary: "query: GRDB",
            log: "provider=exa\ncache=miss"
        )))

        let result = await tool.execute(AgentToolInput(prompt: "生成周刊", context: .empty))

        #expect(result.status == .completed)
        #expect(result.output.toolName == "external.search")
        #expect(result.output.summary == "1 sources")
        #expect(result.trace.output.contains("https://example.com/grdb"))
        if case .externalContextMarkdown(let markdown) = result.payload {
            #expect(markdown.contains("GRDB"))
        } else {
            Issue.record("Expected external context markdown payload")
        }
    }

    @Test("external.search 关闭时返回 skipped trace")
    func externalSearchDisabledReturnsSkipped() async {
        let tool = ExternalSearchAgentTool(collector: StubExternalSearchCollector(collection: AgentExternalSearchCollection(
            status: .skipped,
            markdown: "",
            sourceItems: [],
            querySummary: "externalContextEnabled=false",
            log: "External Search is disabled in Settings."
        )))

        let result = await tool.execute(AgentToolInput(prompt: "生成周刊", context: .empty))

        #expect(result.status == .skipped)
        #expect(result.trace.status == .skipped)
        #expect(result.output.summary == "skipped")
        #expect(result.output.log.contains("disabled"))
    }
}

@MainActor
private final class StubExternalSearchCollector: AgentExternalSearchCollecting {
    let collection: AgentExternalSearchCollection

    init(collection: AgentExternalSearchCollection) {
        self.collection = collection
    }

    func collect(prompt: String, context: AgentRunContext) async -> AgentExternalSearchCollection {
        collection
    }
}
