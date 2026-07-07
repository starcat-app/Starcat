//
//  AgentToolRegistryTests.swift
//  StarcatTests
//
//  Agent Tool Registry 的基础契约测试。
//
//  Registry 是 Runtime 从“Weekly 专用脚本”走向通用 Agent 框架的边界。
//  这里先锁住 tool id 查找、重复注册和缺失工具错误,避免后续工具越来越多时静默覆盖。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentToolRegistry")
struct AgentToolRegistryTests {

    @Test("registry 可以按 tool id 查找工具")
    func resolvesToolByID() throws {
        let tool = StubAgentTool(id: "agent.stub")
        let registry = try AgentToolRegistry(tools: [tool])

        let resolved = try registry.tool(for: "agent.stub")

        #expect(resolved.id == "agent.stub")
        #expect(resolved.displayName == "Stub Tool")
    }

    @Test("registry 拒绝重复 tool id")
    func rejectsDuplicateToolIDs() {
        #expect(throws: AgentToolRegistryError.duplicateToolID("agent.stub")) {
            _ = try AgentToolRegistry(tools: [
                StubAgentTool(id: "agent.stub"),
                StubAgentTool(id: "agent.stub")
            ])
        }
    }

    @Test("registry 缺失工具时显式报错")
    func reportsMissingTool() throws {
        let registry = try AgentToolRegistry(tools: [])

        #expect(throws: AgentToolRegistryError.missingTool("agent.missing")) {
            _ = try registry.tool(for: "agent.missing")
        }
    }
}

private struct StubAgentTool: AgentTool {
    let id: String
    let displayName = "Stub Tool"
    let permission: AgentToolPermission = .readOnly

    func execute(_ input: AgentToolInput) async -> AgentToolResult {
        let output = AgentToolOutput(
            toolName: id,
            summary: "ok",
            detail: "stub",
            input: input.prompt,
            output: "stub",
            log: "stub"
        )
        return AgentToolResult(
            output: output,
            trace: AgentTraceSpan(
                kind: "Tool",
                title: id,
                summary: "ok",
                input: input.prompt,
                output: "stub",
                log: "stub",
                relatedToolOutputID: output.id
            )
        )
    }
}
