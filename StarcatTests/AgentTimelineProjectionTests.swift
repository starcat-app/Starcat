//
//  AgentTimelineProjectionTests.swift
//  StarcatTests
//
//  验证 Agent 工作台只按持久化事实和 sequence 构建统一时间线。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentTimelineProjection")
struct AgentTimelineProjectionTests {
    @Test("消息、审批和产出物按事实 sequence 稳定排序")
    func ordersFactsWithoutLegacyStepGuessing() throws {
        let runID = UUID()
        let call = AgentToolCall(
            id: "call-1",
            name: "knowledge_search",
            input: .object(["query": .string("Swift Agent")]),
            rawInput: "{\"query\":\"Swift Agent\"}",
            sequence: 0
        )
        let user = AgentMessage(
            runID: runID,
            role: .user,
            turn: 0,
            sequence: 0,
            parts: [.text("provider prompt with context")]
        )
        let assistant = AgentMessage(
            runID: runID,
            role: .assistant,
            turn: 0,
            sequence: 1,
            parts: [.reasoning("需要本地知识证据"), .toolCall(call)]
        )
        let result = AgentToolResultMessage(
            toolCallID: call.id,
            toolName: call.name,
            output: .object([
                "summary": .string("1 source"),
                "detail": .string("source detail"),
                "log": .string("provider=exa")
            ]),
            isError: false,
            status: .completed,
            elapsedMilliseconds: 42,
            attempts: [
                AgentToolExecutionAttempt(number: 1, status: .failed, elapsedMilliseconds: 12, errorSummary: "temporary"),
                AgentToolExecutionAttempt(number: 2, status: .completed, elapsedMilliseconds: 30, errorSummary: nil)
            ],
            sources: [AgentToolResultSource(title: "Source", url: "https://example.com", provider: "Exa")],
            toolAudit: .knowledge(AgentKnowledgeRetrievalAudit(
                scopeMode: .only,
                frozenRepoIDs: [1],
                explicitRepoIDs: [1],
                evidenceBlockCount: 1,
                citations: [],
                retrievalTrace: RAGRetrievalTrace(candidates: [
                    RAGRetrievalCandidateTrace(repoID: 1, fullName: "octo/demo")
                ]),
                diagnostics: nil,
                limitations: []
            )),
            sequence: 0
        )
        let tool = AgentMessage(
            runID: runID,
            role: .tool,
            turn: 0,
            sequence: 2,
            parts: [.toolResult(result)]
        )
        let approval = AgentApprovalRequest(
            runID: runID,
            toolCallID: call.id,
            toolName: call.name,
            input: call.input,
            permission: .highCost,
            sequence: 0,
            status: .approved
        )
        let artifact = AgentArtifact(
            type: .markdown,
            title: "Weekly",
            content: "# Weekly",
            toolCallID: call.id,
            messageID: tool.id,
            sequence: 3
        )

        let items = AgentTimelineProjection.makeItems(
            messages: [user, assistant, tool],
            approvals: [approval],
            artifacts: [artifact],
            userPrompt: "真实用户问题"
        )

        #expect(items.map(\.kind) == [.user, .assistant, .toolCall, .approval, .toolResult, .artifact])
        #expect(items.first?.text == "真实用户问题")
        #expect(items.first?.title == String.l10n("agent.workspace.timeline.user"))
        #expect(items.last?.artifact?.id == artifact.id)
        #expect(items.first(where: { $0.kind == .toolResult })?.sources.count == 1)
        #expect(items.first(where: { $0.kind == .toolResult })?.toolCallID == call.id)
        #expect(items.first(where: { $0.kind == .toolResult })?.toolAudit?.knowledgeRetrieval?.metrics.candidateCount == 1)
        #expect(items.first(where: { $0.kind == .toolResult })?.log?.contains("elapsed_ms=42") == true)
        #expect(items.first(where: { $0.kind == .toolResult })?.log?.contains("attempt_count=2") == true)
        #expect(items.first(where: { $0.kind == .assistant })?.reasoning == "需要本地知识证据")
    }
}
