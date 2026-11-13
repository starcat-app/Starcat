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
    @Test("Planner 直接解析模型返回的 snake_case JSON")
    func plannerDecodesSnakeCaseResponse() throws {
        let response = """
        {"intent_summary":"寻找用于管理 GitHub Star 收藏的开源项目。","github_queries":["github stars manager","github starred repositories organizer"],"web_queries":[],"prefers_fresh_evidence":false,"strict_constraints":["开源项目","用于管理 GitHub Star"]}
        """

        let plan = try SearchLLMQueryPlanner.decode(response, allowWebEvidence: true)

        #expect(plan.intentSummary == "寻找用于管理 GitHub Star 收藏的开源项目。")
        #expect(plan.githubQueries == ["github stars manager", "github starred repositories organizer"])
        #expect(plan.webQueries.isEmpty)
        #expect(!plan.prefersFreshEvidence)
        #expect(plan.strictConstraints == ["开源项目", "用于管理 GitHub Star"])
        #expect(plan.githubFilters == .empty)
        #expect(plan.isValid)
    }

    @Test("Planner 解析 fence 响应并遵守网页权限", arguments: [true, false])
    func plannerNormalizesResponse(allowWebEvidence: Bool) throws {
        let response = """
        ```json
        {
          "intent_summary": " 查找热门 Linux 发行版 ",
          "github_queries": [" linux distribution ", "linux distribution", "", "linux distro", "extra"],
          "web_queries": [" trending Linux distribution GitHub "],
          "prefers_fresh_evidence": true,
          "strict_constraints": [" Linux 发行版 ", ""]
        }
        ```
        """

        let plan = try SearchLLMQueryPlanner.decode(response, allowWebEvidence: allowWebEvidence)

        #expect(plan.intentSummary == "查找热门 Linux 发行版")
        #expect(plan.githubQueries == ["linux distribution", "linux distro"])
        #expect(plan.webQueries == (allowWebEvidence ? ["trending Linux distribution GitHub"] : []))
        #expect(plan.prefersFreshEvidence)
        #expect(plan.strictConstraints == ["Linux 发行版"])
        #expect(plan.isValid)
    }

    @Test("Planner 拒绝缺字段和不可执行的计划", arguments: [
        "{}",
        """
        {"intent_summary":"查找项目","github_queries":[],"web_queries":[],"prefers_fresh_evidence":false,"strict_constraints":[]}
        """,
        """
        {"intent_summary":"查找项目","github_queries":[],"web_queries":["project search"],"prefers_fresh_evidence":false,"strict_constraints":[]}
        """
    ])
    func plannerRejectsInvalidResponse(response: String) {
        #expect(throws: SearchIntentRouterError.invalidPlan) {
            try SearchLLMQueryPlanner.decode(response, allowWebEvidence: false)
        }
    }

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
        #expect(outcome.steps.map(\.stage) == [.routing, .planning])
        #expect(outcome.steps.allSatisfy { $0.state == .completed })
        #expect(outcome.steps.last?.detail == outcome.plan?.intentSummary)
        #expect(outcome.steps.allSatisfy { ($0.durationSeconds ?? -1) >= 0 })
        let request = fixture.engine.lastRequest
        #expect(request?.questions.count == 2)
        #expect(request?.operation == .searchIntent)
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
        #expect(keywordOutcome.decisionStatus == .skipped)
        #expect(keywordOutcome.steps.first?.detail?.isEmpty == false)
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
        #expect(outcome.steps.first?.detail?.isEmpty == false)
        #expect(outcome.steps.first?.technicalDetail?.contains("needs_intent_planning") == true)
        #expect(outcome.steps.first?.model == "Jev")
        #expect(outcome.diagnostic == nil)
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
        #expect(outcome.diagnostic?.stage == .planning)
        #expect(outcome.diagnostic?.isFailure == true)
        #expect(outcome.diagnostic?.technicalDetail?.isEmpty == false)
        #expect(outcome.steps.map(\.stage) == [.routing, .planning])
        #expect(outcome.steps.last?.state == .failed)
        #expect(outcome.steps.last?.detail?.isEmpty == false)
    }

    @Test("Planner 鉴权失败保留 HTTP 原因与恢复建议")
    func plannerAuthenticationFailureHasDiagnostic() async {
        let fixture = makeFixture()
        fixture.planner.error = AIClientError.authenticationRejected(detail: "HTTP 401")

        let outcome = await fixture.router.route(query: "帮我管理 GitHub star 项目")

        #expect(outcome.route == .fastPath)
        #expect(outcome.diagnostic?.stage == .planning)
        #expect(outcome.diagnostic?.statusCode == 401)
        #expect(outcome.diagnostic?.recovery?.isEmpty == false)
    }

    @Test("决策和 Planner 共享同一截止时间")
    func routingAndPlanningShareDeadline() async {
        let fixture = makeFixture()
        fixture.settings.decisionEngineEnabled = true
        fixture.settings.decisionSearchRoutingEnabled = true
        fixture.engine.delay = 0.02
        fixture.planner.delay = 0.3
        let start = Date()
        let result = await fixture.router.route(
            query: "找一个管理 GitHub stars 的开源项目",
            deadline: start.addingTimeInterval(0.06)
        )
        #expect(fixture.planner.callCount == 1)
        #expect(fixture.planner.remainingSeconds.last.map { $0 < 0.06 } == true)
        #expect(Date().timeIntervalSince(start) < 0.25)
        #expect(result.diagnostic?.isFailure == true)
    }

    @Test("首轮规划只受 AI 联网权限影响", arguments: [false, true], [false, true])
    func initialPlanningUsesAIWebPermission(aiEnabled: Bool, includeWeb: Bool) async {
        let fixture = makeFixture()
        fixture.settings.externalContextEnabled = aiEnabled
        fixture.settings.externalSearchIncludeInAll = includeWeb
        let outcome = await fixture.router.route(query: "找个 Linux 发行版", explicitSmartDiscovery: true)
        #expect(outcome.plan?.webQueries.isEmpty == !aiEnabled)
    }

    @Test("所选服务商不可用时规划不请求网页证据")
    func unavailableWebProviderDisablesPlanningEvidence() async {
        let fixture = makeFixture()
        fixture.settings.externalContextEnabled = true
        let router = SearchIntentRouter(
            settings: fixture.settings,
            engineRegistry: DecisionEngineRegistry(engines: [fixture.engine]),
            planner: fixture.planner,
            webEvidenceAllowed: { _ in false }
        )
        let outcome = await router.route(query: "Linux", explicitSmartDiscovery: true)
        #expect(outcome.plan?.webQueries.isEmpty == true)
    }

    @Test("决策不可用保留引擎原因，Planner 接管结果可见", arguments: [DecisionEngineID.jev, .laya], [false, true])
    func unavailableEnginePreservesReason(engineID: DecisionEngineID, plannerFails: Bool) async {
        let fixture = makeFixture(engineID: engineID)
        fixture.settings.decisionEngineEnabled = true
        fixture.settings.decisionSearchRoutingEnabled = true
        let reason = engineID == .jev ? "Key not configured" : "Model not installed"
        fixture.engine.availability = .unavailable(reason: reason)
        if plannerFails { fixture.planner.error = AIChatSelectionError.missingModel }
        let outcome = await fixture.router.route(query: "帮我找一个管理 GitHub star 的项目")
        #expect(outcome.steps.first?.state == .skipped)
        #expect(outcome.steps.first?.model == engineID.displayName)
        #expect(outcome.steps.first?.technicalDetail == reason)
        #expect(outcome.steps.first?.detail?.isEmpty == false)
        #expect(outcome.steps.last?.state == (plannerFails ? .failed : .completed))
        #expect(fixture.engine.requestCount == 0)
        #expect(fixture.planner.callCount == 1)
        #expect((outcome.diagnostic != nil) == plannerFails)
    }

    @Test("决策鉴权失败保留详情，成功接管不误报整轮失败")
    func decisionAuthenticationFailureIsExplained() async {
        let fixture = makeFixture()
        fixture.settings.decisionEngineEnabled = true
        fixture.settings.decisionSearchRoutingEnabled = true
        fixture.engine.error = TypeSafeClientError.unauthorized
        let outcome = await fixture.router.route(query: "找一个 Linux 发行版")
        #expect(outcome.steps.first?.state == .failed)
        #expect(outcome.steps.first?.detail?.isEmpty == false)
        #expect(outcome.steps.first?.technicalDetail?.contains("401") == true)
        #expect(outcome.steps.last?.state == .completed)
        #expect(outcome.diagnostic == nil)
        #expect(fixture.engine.requestCount == 1)
        #expect(fixture.planner.callCount == 1)
    }

    private func makeFixture(
        decisionTimeoutSeconds: TimeInterval = 3,
        engineID: DecisionEngineID = .jev
    ) -> (router: SearchIntentRouter, settings: AppSettings, engine: FakeDecisionEngine, planner: FakeSearchPlanner) {
        let suiteName = "SearchIntentRouterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        settings.decisionEngineID = engineID
        let engine = FakeDecisionEngine(id: engineID)
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
    let id: DecisionEngineID
    var error: Error?
    var availability: DecisionEngineAvailability = .available
    var answers: [String: DecisionNoulAnswer] = [:]
    var delay: TimeInterval = 0
    private(set) var requestCount = 0
    private(set) var lastRequest: DecisionEvaluationRequest?

    init(id: DecisionEngineID = .jev) { self.id = id }

    func evaluate(_ request: DecisionEvaluationRequest) async throws -> DecisionEvaluationResponse {
        requestCount += 1
        lastRequest = request
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        if let error { throw error }
        return DecisionEvaluationResponse(answers: answers)
    }
}

@MainActor
private final class FakeSearchPlanner: SearchQueryPlannerProviding {
    var error: Error?
    var delay: TimeInterval = 0
    private(set) var remainingSeconds: [TimeInterval] = []
    private(set) var callCount = 0

    func plan(
        query: String,
        allowWebEvidence: Bool,
        maxSeconds: TimeInterval
    ) async throws -> SearchDiscoveryPlan {
        callCount += 1
        remainingSeconds.append(maxSeconds)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
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
