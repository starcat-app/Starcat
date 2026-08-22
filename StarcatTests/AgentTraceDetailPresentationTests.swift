//
//  AgentTraceDetailPresentationTests.swift
//  StarcatTests
//
//  验证 Runtime Trace 只做确定性结构化，并为无法识别的数据保留原文回退。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentTraceDetailPresentation")
struct AgentTraceDetailPresentationTests {
    @Test("Starcat tool envelope 拆分业务字段并去除重复输出")
    func structuresStarcatToolEnvelope() throws {
        let payload = AgentJSONValue.object([
            "detail": .string("goal: GitHub Weekly Report\nartifact: markdown\nwrite_policy: read-only\nrepo_count: 100"),
            "log": .string("已解析周报目标，未执行写入操作。"),
            "output": .string("goal: GitHub Weekly Report\nartifact: markdown\nwrite_policy: read-only\nrepo_count: 100"),
            "sources": .array([]),
            "status": .string("completed"),
            "summary": .string("Markdown 技术周报"),
        ])
        let event = traceEvent(
            summary: "Markdown 技术周报",
            details: [.init(
                label: "输出",
                value: try payload.jsonString(),
                format: .json
            )]
        )

        let presentation = AgentTraceDetailPresentationBuilder.make(event: event)

        #expect(presentation.sections.count == 2)
        guard case .structured(.object(let fields)) = presentation.sections[0].content else {
            Issue.record("业务输出应转换为键值结构")
            return
        }
        #expect(fields.map(\.key) == ["goal", "artifact", "write_policy", "repo_count"])
        #expect(presentation.sections[1].content == .code("已解析周报目标，未执行写入操作。"))
        #expect(presentation.rawPayload?.contains("repo_count: 100") == true)
    }

    @Test("同构 JSON 对象数组转换为表格")
    func structuresUniformJSONArrayAsTable() throws {
        let json = AgentJSONValue.array([
            .object(["name": .string("alpha"), "stars": .number(10)]),
            .object(["name": .string("beta"), "stars": .number(20)]),
        ])
        let event = traceEvent(details: [.init(
            label: "Repositories",
            value: try json.jsonString(),
            format: .json
        )])

        let presentation = AgentTraceDetailPresentationBuilder.make(event: event)

        guard case .structured(.table(let columns, let rows)) = presentation.sections.first?.content else {
            Issue.record("同构对象数组应转换为表格")
            return
        }
        #expect(columns == ["name", "stars"])
        #expect(rows == [["alpha", "10"], ["beta", "20"]])
    }

    @Test("严格 key value 文本结构化，普通文本保持原文")
    func structuresOnlyStrictKeyValueText() {
        let structured = AgentTraceDetailPresentationBuilder.make(event: traceEvent(details: [.init(
            label: "Output",
            value: "goal: report\nrepo_count: 100"
        )]))
        let prose = AgentTraceDetailPresentationBuilder.make(event: traceEvent(details: [.init(
            label: "Output",
            value: "分析完成：共选择 100 个仓库。"
        )]))

        guard case .structured(.object(let fields)) = structured.sections.first?.content else {
            Issue.record("严格 key value 文本应结构化")
            return
        }
        #expect(fields.map(\.key) == ["goal", "repo_count"])
        #expect(prose.sections.first?.content == .text("分析完成：共选择 100 个仓库。"))
        #expect(prose.rawPayload == nil)
    }

    @Test("损坏 JSON 回退为代码原文")
    func malformedJSONFallsBackToRawCode() {
        let presentation = AgentTraceDetailPresentationBuilder.make(event: traceEvent(details: [.init(
            label: "Output",
            value: "{broken",
            format: .json
        )]))

        #expect(presentation.sections.first?.content == .code("{broken"))
        #expect(presentation.rawPayload == nil)
    }

    private func traceEvent(
        summary: String? = nil,
        details: [AgentTraceDetail]
    ) -> AgentTraceEvent {
        AgentTraceEvent(
            id: UUID().uuidString,
            runID: UUID(),
            backend: .codexAppServer,
            sequence: 0,
            kind: .tool,
            status: .completed,
            title: "agent_parse_goal",
            summary: summary,
            details: details
        )
    }
}
