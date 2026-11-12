//
//  SearchIntentRouterTests.swift
//  StarcatTests
//
//  查询分流的纯逻辑与边界测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Search Intent Router")
@MainActor
struct SearchIntentRouterTests {
    @Test("确定性解析识别 URL、owner/name 与 GitHub 语法")
    func deterministicRoutes() {
        #expect(SearchIntentRouter.deterministicRoute(for: "https://github.com/basecamp/omarchy") == .fastPath)
        #expect(SearchIntentRouter.deterministicRoute(for: "basecamp/omarchy") == .fastPath)
        #expect(SearchIntentRouter.deterministicRoute(for: "linux stars:>1000") == .fastPath)
        #expect(SearchIntentRouter.deterministicRoute(for: "language:swift debugger") == .fastPath)
        #expect(SearchIntentRouter.deterministicRoute(for: "linux distro") == .smartDiscovery)
        #expect(
            SearchIntentRouter.deterministicRoute(
                for: "帮我查 https://github.com/basecamp/omarchy 这个项目叫什么"
            ) == .smartDiscovery
        )
    }

    @Test("快路径不触发决策或 Planner")
    func fastPathSkipsRemoteWork() async {
        let fixture = makeFixture()
        let outcome = await fixture.router.route(query: "basecamp/omarchy")

        #expect(outcome.route == .fastPath)
        #expect(outcome.decisionStatus == .skipped)
        #expect(outcome.plannerStatus == .notNeeded)
        #expect(fixture.engine.requestCount == 0)
        #expect(fixture.planner.callCount == 0)
    }

    @Test("决策开启时一次回答两个问题")
    func decisionEvaluatesTwoQuestionsOnce() async {
        let fixture = makeFixture()
        fixture.settings.decisionSearchRoutingEnabled = true
        fixture.settings.decisionEngineEnabled = true
        fixture.settings.externalContextEnabled = true
        fixture.engine.answers = [
            SearchIntentRouter.needsPlanningQuestionID: DecisionNoulAnswer(probability: 0.92),
            SearchIntentRouter.needsFreshEvidenceQuestionID: DecisionNoulAnswer(probability: 0.88)
        ]

        let outcome = await fixture.router.route(query: "帮我查最近比较火的 Linux 发行版")

        #expect(outcome.route == .smartDiscovery)
        #expect(outcome.decisionStatus == .completed)
        #expect(outcome.plannerStatus == .completed)
        #expect(outcome.plan?.webQueries == ["popular linux distro"])
        #expect(fixture.engine.requestCount == 1)
        #expect(fixture.planner.callCount == 1)
        let request = fixture.engine.lastRequest
        #expect(request?.questions.count == 2)
        #expect(request?.questions.keys.sorted() == [
            SearchIntentRouter.needsFreshEvidenceQuestionID,
            SearchIntentRouter.needsPlanningQuestionID
        ])
    }

    @Test("决策明确普通关键词时不进入 Planner")
    func definiteKeywordDecisionSkipsPlanner() async {
        let fixture = makeFixture()
        fixture.settings.decisionSearchRoutingEnabled = true
        fixture.settings.decisionEngineEnabled = true
        fixture.engine.answers = [
            SearchIntentRouter.needsPlanningQuestionID: DecisionNoulAnswer(probability: 0.01),
            SearchIntentRouter.needsFreshEvidenceQuestionID: DecisionNoulAnswer(probability: 0.02)
        ]

        let outcome = await fixture.router.route(query: "linux distro")

        #expect(outcome.route == .fastPath)
        #expect(outcome.plannerStatus == .notNeeded)
        #expect(fixture.planner.callCount == 0)
    }

    @Test("混合概率不明确时交给 Planner")
    func mixedProbabilityUsesSmartDiscovery() async {
        let fixture = makeFixture()
        fixture.settings.decisionSearchRoutingEnabled = true
        fixture.settings.decisionEngineEnabled = true
        fixture.engine.answers = [
            SearchIntentRouter.needsPlanningQuestionID: DecisionNoulAnswer(probability: 0.60),
            SearchIntentRouter.needsFreshEvidenceQuestionID: DecisionNoulAnswer(probability: 0.10)
        ]

        let outcome = await fixture.router.route(query: "linux distro")

        #expect(outcome.route == .smartDiscovery)
        #expect(outcome.plannerStatus == .completed)
        #expect(fixture.planner.callCount == 1)
    }

    @Test("开关关闭时自然语言走 Planner，普通关键词保持快路径")
    func disabledDecisionUsesConservativeFallback() async {
        let fixture = makeFixture()
        let naturalOutcome = await fixture.router.route(query: "帮我查最近比较火的 Linux 发行版")
        let keywordOutcome = await fixture.router.route(query: "linux distro")

        #expect(naturalOutcome.route == .smartDiscovery)
        #expect(naturalOutcome.decisionStatus == .skipped)
        #expect(naturalOutcome.plannerStatus == .completed)
        #expect(keywordOutcome.route == .fastPath)
        #expect(keywordOutcome.plannerStatus == .notNeeded)
        #expect(fixture.planner.callCount == 1)
        #expect(fixture.engine.requestCount == 0)
    }

    @Test("无效决策答案只触发一次 Planner 降级")
    func invalidDecisionFallsBackToPlanner() async {
        let fixture = makeFixture()
        fixture.settings.decisionSearchRoutingEnabled = true
        fixture.settings.decisionEngineEnabled = true
        fixture.engine.answers = [
            SearchIntentRouter.needsPlanningQuestionID: DecisionNoulAnswer(probability: .infinity),
            SearchIntentRouter.needsFreshEvidenceQuestionID: DecisionNoulAnswer(probability: 0.2)
        ]

        let outcome = await fixture.router.route(query: "最近比较火的 Linux 发行版")

        #expect(outcome.route == .smartDiscovery)
        #expect(outcome.decisionStatus == .failed("Search intent decision returned an invalid answer for needs_intent_planning"))
        #expect(outcome.plannerStatus == .completed)
        #expect(fixture.engine.requestCount == 1)
        #expect(fixture.planner.callCount == 1)
    }

    @Test("决策超时不重试，直接交给 Planner")
    func decisionTimeoutFallsBackToPlanner() async {
        let fixture = makeFixture(decisionTimeoutSeconds: 0.01)
        fixture.settings.decisionSearchRoutingEnabled = true
        fixture.settings.decisionEngineEnabled = true
        fixture.engine.delay = 0.2
        fixture.engine.answers = [
            SearchIntentRouter.needsPlanningQuestionID: DecisionNoulAnswer(probability: 0.01),
            SearchIntentRouter.needsFreshEvidenceQuestionID: DecisionNoulAnswer(probability: 0.01)
        ]

        let outcome = await fixture.router.route(query: "最近比较火的 Linux 发行版")

        #expect(outcome.route == .smartDiscovery)
        #expect(outcome.decisionStatus == .timeout)
        #expect(outcome.plannerStatus == .completed)
        #expect(fixture.engine.requestCount == 1)
        #expect(fixture.planner.callCount == 1)
    }

    @Test("Planner 失败时保留基础搜索路径")
    func plannerFailureKeepsFastPath() async {
        let fixture = makeFixture()
        fixture.planner.error = SearchIntentRouterError.invalidPlan

        let outcome = await fixture.router.route(query: "帮我查最近比较火的 Linux 发行版")

        #expect(outcome.route == .fastPath)
        #expect(outcome.plannerStatus == .failed("Search planner returned an invalid plan"))
        #expect(outcome.plan == nil)
    }

    private func makeFixture(
        decisionTimeoutSeconds: TimeInterval = 3
    ) -> (router: SearchIntentRouter, settings: AppSettings, engine: FakeDecisionEngine, planner: FakeSearchPlanner) {
        let suiteName = "SearchIntentRouterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        let engine = FakeDecisionEngine()
        let planner = FakeSearchPlanner()
        let router = SearchIntentRouter(
            settings: settings,
            engineRegistry: DecisionEngineRegistry(engines: [engine]),
            planner: planner,
            decisionTimeoutSeconds: decisionTimeoutSeconds
        )
        return (router, settings, engine, planner)
    }
}

@MainActor
private final class FakeDecisionEngine: DecisionEngineProviding {
    let id: DecisionEngineID = .jev
    var availability: DecisionEngineAvailability = .available
    var answers: [String: DecisionNoulAnswer] = [:]
    var delay: TimeInterval = 0
    private(set) var requestCount = 0
    private(set) var lastRequest: DecisionEvaluationRequest?

    func evaluate(_ request: DecisionEvaluationRequest) async throws -> DecisionEvaluationResponse {
        requestCount += 1
        lastRequest = request
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        return DecisionEvaluationResponse(answers: answers)
    }
}

@MainActor
private final class FakeSearchPlanner: SearchQueryPlannerProviding {
    var error: Error?
    private(set) var callCount = 0

    func plan(
        query: String,
        allowWebEvidence: Bool,
        maxSeconds: TimeInterval
    ) async throws -> SearchDiscoveryPlan {
        callCount += 1
        if let error { throw error }
        return SearchDiscoveryPlan(
            intentSummary: "查找热门 Linux 发行版",
            githubQueries: ["linux distribution"],
            webQueries: allowWebEvidence ? ["popular linux distro"] : [],
            prefersFreshEvidence: true,
            strictConstraints: [],
            githubFilters: .empty
        )
    }
}
