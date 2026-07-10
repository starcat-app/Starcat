//
//  AgentToolRegistryTests.swift
//  StarcatTests
//
//  Agent Tool Registry 的基础契约测试。
//
//  Registry 是 Runtime 从“Weekly 专用脚本”走向通用 Agent 框架的边界。
//  这里锁住模型可见 name、Schema 校验和缺失工具错误,避免模型参数绕过宿主边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentToolRegistry")
struct AgentToolRegistryTests {

    @Test("registry 可以按模型可见 name 查找工具")
    func resolvesToolByName() throws {
        let tool = StubAgentTool(name: "agent.stub")
        let registry = try AgentToolRegistry(tools: [tool])

        let resolved = try registry.tool(named: "agent.stub")

        #expect(resolved.id == "agent.stub")
        #expect(resolved.definition.description == "Stub Tool")
        #expect(registry.definitions.map(\.name) == ["agent.stub"])
    }

    @Test("registry 拒绝重复 tool name")
    func rejectsDuplicateToolNames() {
        #expect(throws: AgentToolRegistryError.duplicateToolName("agent.stub")) {
            _ = try AgentToolRegistry(tools: [
                StubAgentTool(name: "agent.stub"),
                StubAgentTool(name: "agent.stub")
            ])
        }
    }

    @Test("registry 缺失工具时显式报错")
    func reportsMissingTool() throws {
        let registry = try AgentToolRegistry(tools: [])

        #expect(throws: AgentToolRegistryError.missingTool("agent.missing")) {
            _ = try registry.tool(named: "agent.missing")
        }
    }

    @Test("registry 在执行前校验 tool-call schema")
    func validatesToolCallInput() throws {
        let registry = try AgentToolRegistry(tools: [StubAgentTool(name: "agent.stub")])
        let valid = AgentToolCall(
            id: "call-1",
            name: "agent.stub",
            input: .object(["value": .string("ok")]),
            sequence: 1
        )

        _ = try registry.validatedTool(for: valid)

        let invalid = AgentToolCall(
            id: "call-2",
            name: "agent.stub",
            input: .object(["value": .number(1)]),
            sequence: 2
        )
        #expect(throws: AgentToolRegistryError.self) {
            _ = try registry.validatedTool(for: invalid)
        }
    }
}

private struct StubAgentTool: AgentTool {
    let definition: AgentToolDefinition

    init(name: String) {
        definition = AgentToolDefinition(
            name: name,
            description: "Stub Tool",
            inputSchema: AgentJSONSchema(
                type: .object,
                properties: ["value": AgentJSONSchema(type: .string)],
                required: ["value"]
            ),
            permission: .readOnly,
            completesRun: false,
            timeoutMilliseconds: 1_000
        )
    }

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
