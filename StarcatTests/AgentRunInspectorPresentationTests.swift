//
//  AgentRunInspectorPresentationTests.swift
//  StarcatTests
//
//  验证任务检查器只从已记录事实派生指标，并锁住时间线与 Inspector 的选择联动。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentRunInspectorPresentation")
struct AgentRunInspectorPresentationTests {
    @Test("执行统计按真实 Trace 类型与状态聚合")
    func aggregatesRecordedTraceFacts() {
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let events = [
            trace(runID: runID, id: "reasoning", sequence: 0, kind: .reasoningSummary, status: .completed, startedAt: startedAt),
            trace(runID: runID, id: "tool", sequence: 1, kind: .tool, status: .completed, startedAt: startedAt.addingTimeInterval(1)),
            trace(runID: runID, id: "retry", sequence: 2, kind: .retry, status: .failed, startedAt: startedAt.addingTimeInterval(2)),
            trace(runID: runID, id: "compact", sequence: 3, kind: .compaction, status: .running, startedAt: startedAt.addingTimeInterval(3)),
        ]

        let presentation = AgentRunInspectorPresentation(
            traceEvents: events,
            messages: [],
            artifacts: [AgentArtifact(type: .markdown, title: "Report", content: "# Report")],
            runRecord: nil
        )

        #expect(presentation.stepCount == 4)
        #expect(presentation.completedStepCount == 2)
        #expect(presentation.activeStepCount == 1)
        #expect(presentation.failedStepCount == 1)
        #expect(presentation.toolCallCount == 1)
        #expect(presentation.retryCount == 1)
        #expect(presentation.compactionCount == 1)
        #expect(presentation.artifactCount == 1)
        #expect(presentation.startedAt == startedAt)
        #expect(presentation.lastActivityAt == startedAt.addingTimeInterval(3))
    }

    @MainActor
    @Test("选择步骤和页签会清理互斥的 Inspector 上下文")
    func selectionKeepsOneInspectorContext() {
        let viewModel = AgentWorkspaceViewModel(agents: [BuiltInAgents.githubWeeklyReport])
        let event = trace(
            runID: UUID(),
            id: "tool",
            sequence: 0,
            kind: .tool,
            status: .completed,
            startedAt: Date()
        )
        viewModel.traceEvents = [event]

        viewModel.selectTraceEvent(event.id)
        #expect(viewModel.selectedTraceEvent?.id == event.id)

        viewModel.selectInspectorTab(.context)
        #expect(viewModel.inspectorTab == .context)
        #expect(viewModel.selectedTraceEvent == nil)
        #expect(viewModel.selectedKnowledgeAudit == nil)
    }

    private func trace(
        runID: UUID,
        id: String,
        sequence: Int,
        kind: AgentTraceKind,
        status: AgentTraceStatus,
        startedAt: Date
    ) -> AgentTraceEvent {
        AgentTraceEvent(
            id: id,
            runID: runID,
            backend: .builtinLoop,
            sequence: sequence,
            kind: kind,
            status: status,
            title: id,
            startedAt: startedAt
        )
    }
}
