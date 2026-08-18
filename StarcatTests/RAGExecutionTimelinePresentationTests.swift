//
//  RAGExecutionTimelinePresentationTests.swift
//  StarcatTests
//
//  查询规划把思考收成子步骤：父步骤不能被思考开始提前打勾，结果出来后先保持展开。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RAG execution timeline presentation")
struct RAGExecutionTimelinePresentationTests {

    @Test("思考开始时查询规划仍保持 running")
    func planningReasoningDoesNotCompleteParentPlanning() {
        var steps: [RAGExecutionStep] = []
        let planningStartedAt = Date(timeIntervalSinceReferenceDate: 100)
        let reasoningStartedAt = Date(timeIntervalSinceReferenceDate: 100.9)

        RAGExecutionTraceReducer.applyStarted(.planning, to: &steps, at: planningStartedAt)
        RAGExecutionTraceReducer.applyStarted(.planningReasoning, to: &steps, at: reasoningStartedAt)

        #expect(steps.count == 2)
        #expect(steps[0].kind == .planning)
        #expect(steps[0].state == .running)
        #expect(steps[0].completedAt == nil)
        #expect(steps[1].kind == .planningReasoning)
        #expect(steps[1].state == .running)
    }

    @Test("下一个顶层步骤开始时仍会结束当前 running 的父步骤")
    func topLevelStartStillCompletesRunningParents() {
        var steps: [RAGExecutionStep] = []
        RAGExecutionTraceReducer.applyStarted(.planning, to: &steps, at: Date(timeIntervalSinceReferenceDate: 1))
        RAGExecutionTraceReducer.applyStarted(.retrieval, to: &steps, at: Date(timeIntervalSinceReferenceDate: 2))

        #expect(steps[0].kind == .planning)
        #expect(steps[0].state == .completed)
        #expect(steps[0].completedAt != nil)
        #expect(steps[1].kind == .retrieval)
        #expect(steps[1].state == .running)
    }

    @Test("相邻的规划思考会缩进挂到查询规划下，而不是并列第二步")
    func groupingNestsPlanningReasoningUnderPlanning() {
        let planning = RAGExecutionStep(kind: .planning, state: .running)
        let reasoning = RAGExecutionStep(kind: .planningReasoning, state: .running)
        let retrieval = RAGExecutionStep(kind: .retrieval, state: .running)

        let items = RAGExecutionTimelineGrouping.items(from: [planning, reasoning, retrieval])

        #expect(items.count == 2)
        guard case .planning(let parent, let nested) = items[0] else {
            Issue.record("expected planning group")
            return
        }
        #expect(parent.kind == .planning)
        #expect(nested?.kind == .planningReasoning)
        guard case .step(let topLevel) = items[1] else {
            Issue.record("expected retrieval as top-level step")
            return
        }
        #expect(topLevel.kind == .retrieval)
    }

    @Test("没有思考时查询规划仍是顶层步骤")
    func groupingKeepsPlanningWithoutReasoning() {
        let planning = RAGExecutionStep(kind: .planning, state: .completed)
        let items = RAGExecutionTimelineGrouping.items(from: [planning])

        #expect(items.count == 1)
        guard case .planning(_, let nested) = items[0] else {
            Issue.record("expected planning group")
            return
        }
        #expect(nested == nil)
    }

    @Test("查询规划完成后若还没有下一步，默认保持展开")
    func completedPlanningStaysExpandedUntilNextTopLevel() {
        var disclosure = RAGExecutionDisclosureState()
        let planning = RAGExecutionStep(kind: .planning, state: .completed)
        let items = RAGExecutionTimelineGrouping.items(from: [
            planning,
            RAGExecutionStep(kind: .planningReasoning, state: .completed)
        ])
        let defaultExpanded = RAGExecutionTimelineGrouping.defaultExpanded(for: planning, items: items)

        #expect(defaultExpanded)
        #expect(disclosure.isExpanded(planning, defaultExpanded: defaultExpanded))

        disclosure.toggle(planning, defaultExpanded: defaultExpanded)
        #expect(!disclosure.isExpanded(planning, defaultExpanded: defaultExpanded))
    }

    @Test("检索开始后查询规划回到默认折叠")
    func planningCollapsesWhenNextTopLevelExists() {
        let planning = RAGExecutionStep(kind: .planning, state: .completed)
        let items = RAGExecutionTimelineGrouping.items(from: [
            planning,
            RAGExecutionStep(kind: .planningReasoning, state: .completed),
            RAGExecutionStep(kind: .retrieval, state: .running)
        ])

        #expect(!RAGExecutionTimelineGrouping.defaultExpanded(for: planning, items: items))
        #expect(RAGExecutionTimelineGrouping.defaultExpanded(
            for: RAGExecutionStep(kind: .retrieval, state: .running),
            items: items
        ))
    }

    @Test("完成的思考子步骤默认折叠")
    func completedPlanningReasoningDefaultsCollapsed() {
        let reasoning = RAGExecutionStep(kind: .planningReasoning, state: .completed)
        let items = RAGExecutionTimelineGrouping.items(from: [
            RAGExecutionStep(kind: .planning, state: .completed),
            reasoning
        ])

        #expect(!RAGExecutionTimelineGrouping.defaultExpanded(for: reasoning, items: items))
    }

    @Test("运行中可手动折叠且普通完成步骤仍默认折叠")
    func disclosureOneArgAPIStillDefaultsCompletedCollapsed() {
        var disclosure = RAGExecutionDisclosureState()
        let running = RAGExecutionStep(kind: .retrieval, state: .running)

        #expect(disclosure.isExpanded(running))
        disclosure.toggle(running)
        #expect(!disclosure.isExpanded(running))

        var updatedRunning = running
        updatedRunning.details = ["流式更新不应覆盖用户折叠选择"]
        #expect(!disclosure.isExpanded(updatedRunning))
        disclosure.toggle(updatedRunning)
        #expect(disclosure.isExpanded(updatedRunning))

        let completed = RAGExecutionStep(kind: .retrieval, state: .completed)
        #expect(!disclosure.isExpanded(completed))
        disclosure.toggle(completed)
        #expect(disclosure.isExpanded(completed))
        disclosure.toggle(completed)
        #expect(!disclosure.isExpanded(completed))
    }
}
