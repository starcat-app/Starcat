//
//  AgentMessagesTests.swift
//  StarcatTests
//
//  Agent 可回放消息契约测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Agent Messages")
struct AgentMessagesTests {

    @Test("包含 reasoning 和 tool-call 的消息可稳定往返编码")
    func messageRoundTrip() throws {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let message = AgentMessage(
            runID: runID,
            role: .assistant,
            turn: 1,
            sequence: 2,
            parts: [
                .reasoning("需要先解析仓库范围"),
                .toolCall(AgentToolCall(
                    id: "call-1",
                    name: "context_resolve_repos",
                    input: .object(["limit": .number(20)]),
                    sequence: 3
                ))
            ],
            usage: AgentUsage(inputTokens: 120, outputTokens: 30, cachedTokens: 10)
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)

        #expect(decoded == message)
        #expect(decoded.usage?.totalTokens == 150)
    }

    @Test("tool-result 必须关联已有且同名的 tool-call")
    func validatesToolResultCorrelation() throws {
        let messages = validToolConversation()
        try AgentMessageContract.validate(messages)

        var unknown = messages
        unknown[2].parts = [.toolResult(AgentToolResultMessage(
            toolCallID: "call-missing",
            toolName: "external_search",
            output: .object([:]),
            isError: true,
            status: .failed,
            sequence: 5
        ))]
        #expect(throws: AgentMessageContractError.unknownToolCallID("call-missing")) {
            try AgentMessageContract.validate(unknown)
        }

        var mismatch = messages
        mismatch[2].parts = [.toolResult(AgentToolResultMessage(
            toolCallID: "call-search",
            toolName: "context_resolve_repos",
            output: .object([:]),
            isError: false,
            status: .completed,
            sequence: 5
        ))]
        #expect(throws: AgentMessageContractError.toolNameMismatch(callID: "call-search")) {
            try AgentMessageContract.validate(mismatch)
        }
    }

    @Test("同轮多工具调用可分别关联成功与错误结果")
    func validatesMultipleToolCallsAndErrorResults() throws {
        let runID = UUID()
        let firstCall = AgentToolCall(
            id: "call-local",
            name: "context_resolve_repos",
            input: .object(["limit": .number(5)]),
            sequence: 2
        )
        let secondCall = AgentToolCall(
            id: "call-search",
            name: "external_search",
            input: .object(["query": .string("Swift Agent")]),
            sequence: 2
        )
        let messages = [
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("整理")]),
            AgentMessage(
                runID: runID,
                role: .assistant,
                turn: 0,
                sequence: 1,
                parts: [.reasoning("并列读取证据"), .toolCall(firstCall), .toolCall(secondCall)]
            ),
            AgentMessage(
                runID: runID,
                role: .tool,
                turn: 0,
                sequence: 2,
                parts: [.toolResult(AgentToolResultMessage(
                    toolCallID: firstCall.id,
                    toolName: firstCall.name,
                    output: .object(["count": .number(2)]),
                    isError: false,
                    status: .completed,
                    sequence: 2
                ))]
            ),
            AgentMessage(
                runID: runID,
                role: .tool,
                turn: 0,
                sequence: 3,
                parts: [.toolResult(AgentToolResultMessage(
                    toolCallID: secondCall.id,
                    toolName: secondCall.name,
                    output: .object(["error": .string("disabled")]),
                    isError: true,
                    status: .skipped,
                    sequence: 3
                ))]
            )
        ]

        try AgentMessageContract.validate(messages)
        let data = try JSONEncoder().encode(messages)
        let decoded = try JSONDecoder().decode([AgentMessage].self, from: data)

        #expect(decoded == messages)
        #expect(decoded[1].parts.count == 3)
        #expect(decoded.map(\.sequence) == [0, 1, 2, 3])
    }

    @Test("消息 sequence 必须严格递增且 role 不能承载错误 part")
    func validatesOrderingAndRole() {
        let runID = UUID()
        let outOfOrder = [
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 1, parts: [.text("start")]),
            AgentMessage(runID: runID, role: .assistant, turn: 1, sequence: 1, parts: [.text("reply")])
        ]
        #expect(throws: AgentMessageContractError.nonIncreasingSequence(1)) {
            try AgentMessageContract.validate(outOfOrder)
        }

        let invalidRole = [
            AgentMessage(
                runID: runID,
                role: .user,
                turn: 0,
                sequence: 1,
                parts: [.reasoning("not allowed")]
            )
        ]
        #expect(throws: AgentMessageContractError.invalidPartForRole(.user)) {
            try AgentMessageContract.validate(invalidRole)
        }
    }

    @Test("usage merge 会累计 token 和成本")
    func mergesUsage() {
        var usage = AgentUsage(inputTokens: 100, outputTokens: 20, estimatedCost: 0.01)
        usage.merge(AgentUsage(inputTokens: 50, outputTokens: 10, cachedTokens: 30, estimatedCost: 0.02))

        #expect(usage.inputTokens == 150)
        #expect(usage.outputTokens == 30)
        #expect(usage.cachedTokens == 30)
        #expect(usage.totalTokens == 180)
        #expect(usage.estimatedCost == 0.03)
    }

    @Test("knowledge tool audit 可随消息稳定往返编码")
    func knowledgeToolAuditRoundTrip() throws {
        let audit = sampleKnowledgeAudit()
        let result = AgentToolResultMessage(
            toolCallID: "call-knowledge",
            toolName: "knowledge_search",
            output: .object(["summary": .string("1 evidence")]),
            isError: false,
            status: .completed,
            toolAudit: .knowledge(audit),
            sequence: 2
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AgentToolResultMessage.self, from: data)

        #expect(decoded == result)
        #expect(decoded.toolAudit?.knowledgeRetrieval?.retrievalTrace?.candidates.count == 1)
        #expect(decoded.toolAudit?.knowledgeRetrieval?.citations.first?.chunkID == 9)
    }

    @Test("旧 tool-result 缺少 toolAudit 字段时仍可解码")
    func legacyToolResultWithoutAuditRemainsDecodable() throws {
        let legacy = AgentToolResultMessage(
            toolCallID: "call-legacy",
            toolName: "external_search",
            output: .object(["summary": .string("legacy")]),
            isError: false,
            status: .completed,
            sequence: 2
        )
        let data = try JSONEncoder().encode(legacy)
        #expect(String(decoding: data, as: UTF8.self).contains("toolAudit") == false)

        let decoded = try JSONDecoder().decode(AgentToolResultMessage.self, from: data)

        #expect(decoded.toolAudit == nil)
        #expect(decoded.toolCallID == "call-legacy")
    }

    private func sampleKnowledgeAudit() -> AgentKnowledgeRetrievalAudit {
        AgentKnowledgeRetrievalAudit(
            scopeMode: .only,
            frozenRepoIDs: [1],
            explicitRepoIDs: [1],
            evidenceBlockCount: 1,
            citations: [AgentKnowledgeCitationAudit(
                marker: "S1",
                chunkID: 9,
                repoID: 1,
                repoFullName: "octo/demo",
                source: "readme",
                sectionTitle: "Usage",
                score: 0.9,
                hitKind: "hybrid",
                vectorSimilarity: 0.8,
                sourceURL: "https://github.com/octo/demo"
            )],
            retrievalTrace: RAGRetrievalTrace(candidates: [
                RAGRetrievalCandidateTrace(repoID: 1, fullName: "octo/demo", language: "Swift", stars: 10)
            ]),
            diagnostics: RAGRetrievalDiagnostics(
                settings: .balanced,
                candidateRepoCount: 1,
                finalChildHitCount: 1,
                bundleCount: 1,
                outcome: .completed
            ),
            limitations: []
        )
    }

    private func validToolConversation() -> [AgentMessage] {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        return [
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 1, parts: [.text("搜索 Swift Agent")]),
            AgentMessage(
                runID: runID,
                role: .assistant,
                turn: 1,
                sequence: 2,
                parts: [.toolCall(AgentToolCall(
                    id: "call-search",
                    name: "external_search",
                    input: .object(["query": .string("Swift Agent")]),
                    sequence: 3
                ))]
            ),
            AgentMessage(
                runID: runID,
                role: .tool,
                turn: 1,
                sequence: 4,
                parts: [.toolResult(AgentToolResultMessage(
                    toolCallID: "call-search",
                    toolName: "external_search",
                    output: .object(["count": .number(2)]),
                    isError: false,
                    status: .completed,
                    elapsedMilliseconds: 42,
                    sequence: 5
                ))]
            )
        ]
    }
}
