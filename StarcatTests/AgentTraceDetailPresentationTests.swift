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

    @Test("Markdown 明细保留语义并由视图层渲染")
    func keepsMarkdownDetailForRenderer() {
        let presentation = AgentTraceDetailPresentationBuilder.make(event: traceEvent(
            kind: .reasoningSummary,
            title: "Reasoning Summary",
            summary: "**核对证据**",
            details: [.init(
                label: "思考过程",
                value: "**核对证据**",
                format: .markdown
            )]
        ))

        #expect(presentation.sections.first?.content == .markdown("**核对证据**"))
    }

    @Test("已知工具显示本地化标题并保留稳定 Tool ID")
    func localizesKnownToolTitleAndPreservesIdentifier() {
        let event = traceEvent(kind: .tool, details: [])
        let presentation = AgentTraceDetailPresentationBuilder.make(event: event)

        #expect(AgentTraceTitlePresentation.title(for: event)
            == String.l10n("agent.workspace.trace.tool.agentParseGoal"))
        #expect(presentation.sections.first?.label == String.l10n("agent.workspace.trace.toolID"))
        #expect(presentation.sections.first?.content == .code("agent_parse_goal"))
    }

    @Test("历史固定类别标题按当前语言重新解析")
    func localizesPersistedFixedKindTitle() {
        let event = traceEvent(
            kind: .reasoningSummary,
            title: "Thinking",
            details: []
        )

        #expect(AgentTraceTitlePresentation.title(for: event)
            == String.l10n("agent.workspace.trace.kind.thinking"))
    }

    @Test("DeepSeek MCP 工具名去除传输后缀并保留原始 ID")
    func normalizesDeepSeekMCPToolTitle() {
        let rawName = "mcp__starcat__starcat_search_repos_12478560673a"
        let event = traceEvent(
            backend: .deepSeekHarness,
            kind: .tool,
            title: rawName,
            details: []
        )

        #expect(AgentTraceTitlePresentation.title(for: event)
            == String.l10n("agent.workspace.trace.tool.searchRepositories"))
        let presentation = AgentTraceDetailPresentationBuilder.make(event: event)
        #expect(presentation.sections.first?.content == .code(rawName))
    }

    @Test("工具行从 DeepSeek MCP 结果提取仓库数量")
    func summarizesDeepSeekRepositorySearch() throws {
        let result = try deepSeekToolResultJSON(text: #"{"repos":[{"name":"one"},{"name":"two"}]}"#)
        let event = traceEvent(
            backend: .deepSeekHarness,
            kind: .tool,
            title: "mcp__starcat__starcat_search_repos_12478560673a",
            summary: String.l10n("agent.workspace.trace.tool.completed"),
            details: [
                .init(label: "Input", value: #"{"query":"swift"}"#, format: .json),
                .init(label: "Output", value: try result.jsonString(), format: .json),
            ]
        )

        #expect(AgentTraceRowPresentation.summary(for: event)
            == String(format: String.l10n("agent.workspace.trace.repoCountFormat"), 2))
    }

    @Test("DeepSeek MCP 嵌套结果解包为业务结构")
    func unwrapsDeepSeekToolResultEnvelope() throws {
        let result = try deepSeekToolResultJSON(text: #"{"repos":[{"name":"one","stars":10},{"name":"two","stars":20}]}"#)
        let event = traceEvent(
            backend: .deepSeekHarness,
            kind: .tool,
            title: "mcp__starcat__starcat_search_repos_12478560673a",
            details: [.init(label: "Output", value: try result.jsonString(), format: .json)]
        )

        let presentation = AgentTraceDetailPresentationBuilder.make(event: event)
        guard case .structured(.object(let fields)) = presentation.sections.last?.content else {
            Issue.record("DeepSeek message envelope 应解包到 MCP 业务结果")
            return
        }
        #expect(fields.map(\.key) == ["repos"])
        #expect(presentation.rawPayload?.contains("tool-result") == true)
    }

    @Test("DeepSeek 时间线保留全部事件并遵循原始顺序")
    func preservesEveryDeepSeekEvent() {
        let runID = UUID()
        let events = [
            traceEvent(runID: runID, backend: .deepSeekHarness, sequence: 0, kind: .lifecycle, title: "agent/inbox/spliced", details: []),
            traceEvent(runID: runID, backend: .deepSeekHarness, sequence: 1, kind: .warning, title: "Turn 1", details: []),
            traceEvent(runID: runID, backend: .deepSeekHarness, sequence: 2, kind: .message, title: "Runtime message", details: []),
            traceEvent(runID: runID, backend: .deepSeekHarness, sequence: 3, kind: .request, title: "Model request", details: []),
            traceEvent(runID: runID, backend: .deepSeekHarness, sequence: 4, kind: .tool, title: "starcat.search_repos", details: []),
        ]

        let snapshot = AgentTraceTimelinePresentation.makeSnapshot(events)

        #expect(snapshot.orderedEvents.map(\.kind) == [.lifecycle, .warning, .message, .request, .tool])
        #expect(snapshot.eventCount == events.count)
    }

    @Test("DeepSeek 过程视图按 turn step 归组并推断工具父级")
    func groupsDeepSeekEventsWithoutDroppingAuditFacts() {
        let runID = UUID()
        let turnID = "\(runID.uuidString):turn:0"
        let stepID = "\(runID.uuidString):turn:0:step:0"
        let events = [
            traceEvent(
                id: "\(runID.uuidString):session",
                runID: runID,
                backend: .deepSeekHarness,
                providerEventID: "session/title",
                sequence: 0,
                kind: .lifecycle,
                title: "Session",
                details: []
            ),
            traceEvent(
                id: turnID,
                runID: runID,
                backend: .deepSeekHarness,
                providerEventID: "turn:0",
                sequence: 1,
                kind: .warning,
                title: "Warning",
                details: []
            ),
            traceEvent(
                id: stepID,
                runID: runID,
                backend: .deepSeekHarness,
                providerEventID: "turn:0:step:0",
                parentID: turnID,
                sequence: 2,
                kind: .lifecycle,
                title: "Step 1",
                details: []
            ),
            traceEvent(
                id: "\(runID.uuidString):request",
                runID: runID,
                backend: .deepSeekHarness,
                providerEventID: "request:0:0",
                parentID: stepID,
                sequence: 3,
                kind: .request,
                title: "Model request",
                details: []
            ),
            traceEvent(
                id: "\(runID.uuidString):tool",
                runID: runID,
                backend: .deepSeekHarness,
                providerEventID: "tool:call-1",
                sequence: 4,
                kind: .tool,
                title: "starcat.search_repos",
                details: []
            ),
        ]

        let snapshot = AgentTraceTimelinePresentation.makeSnapshot(events)
        let rows = AgentTraceTimelinePresentation.processRows(
            snapshot: snapshot,
            collapsedNodeIDs: []
        )

        #expect(snapshot.roots.map(\.id) == [events[0].id, turnID])
        #expect(rows.map(\.depth) == [0, 0, 1, 2, 2])
        #expect(rows.map(\.id) == events.map(\.id))
        #expect(AgentTraceTitlePresentation.title(for: events[1])
            == "\(String.l10n("agent.workspace.trace.kind.turn")) 1")
        #expect(rows[1].childCount == 3)
        #expect(rows[2].childCount == 2)

        let collapsedRows = AgentTraceTimelinePresentation.processRows(
            snapshot: snapshot,
            collapsedNodeIDs: [stepID]
        )
        #expect(collapsedRows.map(\.id) == [events[0].id, turnID, stepID])
    }

    @Test("超长 Markdown 与原始载荷按展示预算裁剪")
    func boundsLargeTextAndRawPayload() throws {
        let oversized = String(repeating: "abcdefghij", count: 4_000)
        let markdown = AgentTraceDetailPresentationBuilder.make(event: traceEvent(details: [.init(
            label: "Markdown",
            value: oversized,
            format: .markdown
        )]))
        guard case .markdown(let rendered) = markdown.sections.first?.content else {
            Issue.record("Markdown 应保持富文本语义")
            return
        }
        #expect(rendered.count < oversized.count)
        #expect(rendered.contains(String.l10n("agent.workspace.trace.contentTruncated")))

        let json = AgentJSONValue.object(["payload": .string(oversized)])
        let structured = AgentTraceDetailPresentationBuilder.make(event: traceEvent(details: [.init(
            label: "JSON",
            value: try json.jsonString(),
            format: .json
        )]))
        #expect(structured.rawPayload?.count ?? 0
            <= AgentTracePresentationBudget.rawPayloadCharacters
                + AgentTracePresentationBudget.truncationMarker.count)
    }

    @Test("大型集合只创建有界数量的结构化视图节点")
    func boundsLargeStructuredCollections() throws {
        // 保持在 AgentTraceDetail 的持久化裁剪阈值内，单独验证 UI 节点预算。
        let json = AgentJSONValue.array((0..<100).map { index in
            .object(["index": .number(Double(index)), "name": .string("repo-\(index)")])
        })
        let presentation = AgentTraceDetailPresentationBuilder.make(event: traceEvent(details: [.init(
            label: "Repositories",
            value: try json.jsonString(),
            format: .json
        )]))

        guard case .structured(.table(_, let rows)) = presentation.sections.first?.content else {
            Issue.record("同构对象数组应保持表格展示")
            return
        }
        #expect(rows.count == AgentTracePresentationBudget.collectionItems + 1)
        #expect(rows.last?.first == String.l10n("agent.workspace.trace.contentTruncated"))
    }

    private func traceEvent(
        id: String = UUID().uuidString,
        runID: UUID = UUID(),
        backend: AgentRuntimeBackend = .codexAppServer,
        providerEventID: String? = nil,
        parentID: String? = nil,
        sequence: Int = 0,
        kind: AgentTraceKind = .unknown,
        title: String = "agent_parse_goal",
        summary: String? = nil,
        details: [AgentTraceDetail]
    ) -> AgentTraceEvent {
        AgentTraceEvent(
            id: id,
            runID: runID,
            backend: backend,
            providerEventID: providerEventID,
            parentID: parentID,
            sequence: sequence,
            kind: kind,
            status: .completed,
            title: title,
            summary: summary,
            details: details
        )
    }

    private func deepSeekToolResultJSON(text: String) throws -> AgentJSONValue {
        .object([
            "message": .object([
                "content": .array([
                    .object([
                        "content": .array([
                            .object(["text": .string(text), "type": .string("text")]),
                        ]),
                        "isError": .bool(false),
                        "type": .string("tool-result"),
                    ]),
                ]),
                "role": .string("user"),
            ]),
            "step": .number(2),
            "turn": .number(1),
        ])
    }
}
