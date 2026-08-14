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

        #expect(items.map(\.kind) == [.user, .assistant, .toolExecution, .approval, .artifact])
        #expect(items.first?.text == "真实用户问题")
        #expect(items.first?.title == String.l10n("agent.workspace.timeline.user"))
        #expect(items.last?.artifact?.id == artifact.id)
        #expect(items.first(where: { $0.kind == .toolExecution })?.sources.count == 1)
        #expect(items.first(where: { $0.kind == .toolExecution })?.toolCallID == call.id)
        #expect(items.first(where: { $0.kind == .toolExecution })?.toolAudit?.knowledgeRetrieval?.metrics.candidateCount == 1)
        #expect(items.first(where: { $0.kind == .toolExecution })?.narrative == "provider=exa")
        #expect(items.first(where: { $0.kind == .toolExecution })?.log?.contains("elapsed_ms=42") == true)
        #expect(items.first(where: { $0.kind == .toolExecution })?.log?.contains("attempt_count=2") == true)
        #expect(items.first(where: { $0.kind == .assistant })?.reasoning == "需要本地知识证据")
    }

    @Test("call result 合并、相邻活动聚合且完成态结果优先")
    func buildsProcessAndResultLayers() {
        let runID = UUID()
        let firstCall = AgentToolCall(
            id: "call-1",
            name: "knowledge_search",
            input: .object(["query": .string("one")]),
            sequence: 0
        )
        let secondCall = AgentToolCall(
            id: "call-2",
            name: "knowledge_search",
            input: .object(["query": .string("two")]),
            sequence: 1
        )
        let messages = [
            AgentMessage(
                runID: runID,
                role: .user,
                turn: 0,
                sequence: 0,
                parts: [.text("provider prompt")]
            ),
            AgentMessage(
                runID: runID,
                role: .assistant,
                turn: 0,
                sequence: 1,
                parts: [.reasoning("hidden reasoning"), .text("正在检索"), .toolCall(firstCall), .toolCall(secondCall)]
            ),
            AgentMessage(
                runID: runID,
                role: .tool,
                turn: 0,
                sequence: 2,
                parts: [
                    .toolResult(toolResult(call: firstCall, summary: "first")),
                    .toolResult(toolResult(call: secondCall, summary: "second"))
                ]
            ),
            AgentMessage(
                runID: runID,
                role: .assistant,
                turn: 1,
                sequence: 3,
                parts: [.text("# 最终答案\n\n完成。")]
            )
        ]
        let markdown = AgentArtifact(type: .markdown, title: "报告", content: "# 报告", sequence: 4)
        let log = AgentArtifact(type: .log, title: "日志", content: "raw", sequence: 5)

        let presentation = AgentTimelineProjection.makePresentation(
            messages: messages,
            approvals: [],
            artifacts: [markdown, log],
            userPrompt: "真实问题",
            status: .completed
        )

        #expect(presentation.userItems.map(\.text) == ["真实问题"])
        #expect(presentation.processSections.count == 2)
        #expect(presentation.processSections[0].kind == .progress)
        #expect(presentation.processSections[0].items.first?.text == "正在检索")
        #expect(presentation.processSections[1].kind == .activity)
        #expect(presentation.processSections[1].items.count == 2)
        #expect(presentation.processSections[1].items.map(\.toolCallID) == ["call-1", "call-2"])
        #expect(presentation.processSections[1].items.map(\.text) == ["first", "second"])
        #expect(presentation.finalAnswer?.text == "# 最终答案\n\n完成。")
        #expect(presentation.inlineArtifacts.map(\.artifact?.id) == [markdown.id])
        #expect(!presentation.isProcessExpandedByDefault)
        #expect(presentation.processSections.flatMap(\.items).allSatisfy { $0.text != "hidden reasoning" })
    }

    @Test("审批形成活动边界且终态使用正确默认折叠策略")
    func preservesApprovalBoundaryAndStatusDefaults() {
        let runID = UUID()
        let call = AgentToolCall(
            id: "write-call",
            name: "tag_apply_untagged",
            input: .object(["preview_hash": .string("hash")]),
            sequence: 0
        )
        let messages = [
            AgentMessage(
                runID: runID,
                role: .assistant,
                turn: 0,
                sequence: 1,
                parts: [.toolCall(call)]
            ),
            AgentMessage(
                runID: runID,
                role: .tool,
                turn: 0,
                sequence: 2,
                parts: [.toolResult(toolResult(call: call, summary: "applied"))]
            )
        ]
        let approval = AgentApprovalRequest(
            runID: runID,
            toolCallID: call.id,
            toolName: call.name,
            input: call.input,
            permission: .requiresConfirmation,
            sequence: 1,
            status: .pending
        )

        let waiting = AgentTimelineProjection.makePresentation(
            messages: messages,
            approvals: [approval],
            artifacts: [],
            userPrompt: "",
            status: .waitingForConfirmation
        )
        let failed = AgentTimelineProjection.makePresentation(
            messages: messages,
            approvals: [approval],
            artifacts: [],
            userPrompt: "",
            status: .failed
        )
        let cancelled = AgentTimelineProjection.makePresentation(
            messages: messages,
            approvals: [approval],
            artifacts: [],
            userPrompt: "",
            status: .cancelled
        )

        #expect(waiting.processSections.map(\.kind) == [.activity, .approval])
        #expect(waiting.isProcessExpandedByDefault)
        #expect(failed.isProcessExpandedByDefault)
        #expect(!cancelled.isProcessExpandedByDefault)
    }

    private func toolResult(call: AgentToolCall, summary: String) -> AgentToolResultMessage {
        AgentToolResultMessage(
            toolCallID: call.id,
            toolName: call.name,
            output: .object(["summary": .string(summary), "detail": .string("detail")]),
            isError: false,
            status: .completed,
            elapsedMilliseconds: 10,
            attempts: [],
            sources: [],
            sequence: call.sequence
        )
    }
}
