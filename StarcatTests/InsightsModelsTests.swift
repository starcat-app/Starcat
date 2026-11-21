//
//  InsightsModelsTests.swift
//  StarcatTests
//
//  锁定洞察侧栏顺序、旧中栏内容的合并结果及范围。
//

import Testing
@testable import Starcat

@Suite("Insights models")
struct InsightsModelsTests {

    @Test("五个入口由左栏直接切换，画像是独立页面")
    func sidebarPageOrder() {
        #expect(InsightsTopic.allCases == [.overview, .organization, .technology, .health, .knowledgeProfile])
    }

    @Test("概览保留完整数据总览，并合入全部待处理", arguments: InsightsScope.allCases)
    func overviewPageSections(scope: InsightsScope) {
        #expect(InsightsTopic.overview.dashboardSections(for: scope) == [
            .metrics, .rhythm, .organizationProgress, .knowledgeCoverage,
            .priorityRepositories, .assetCleanup, .languages, .allActions, .healthCoverage
        ])
    }

    @Test("整理概览和范围内的每个待办详情合并到同一页")
    func organizationPageSections() {
        let summary: [InsightsDashboardSection] = [
            .organizationProgress, .rhythm, .knowledgeCoverage, .priorityRepositories, .assetCleanup
        ]
        let starred: [InsightsDashboardSection] = summary + [.action(.untagged), .action(.unread)]
        let knowledge: [InsightsDashboardSection] = starred + [
            .action(.missingReadme), .action(.missingIndexableContent), .action(.indexIssues)
        ]

        #expect(InsightsTopic.organization.dashboardSections(for: .starred) == starred)
        #expect(InsightsTopic.organization.dashboardSections(for: .knowledge) == knowledge)
    }

    @Test("项目健康覆盖和四个待办详情在两个范围内都独立展示", arguments: InsightsScope.allCases)
    func healthPageSections(scope: InsightsScope) {
        #expect(InsightsTopic.health.dashboardSections(for: scope) == [
            .healthCoverage, .action(.healthPending), .action(.openSSFPending),
            .action(.maintenanceRisk), .action(.securityRisk)
        ])
    }

    @Test("技术分布合并语言、主题和许可证，画像保留独立内容", arguments: InsightsScope.allCases)
    func technologyAndProfilePageSections(scope: InsightsScope) {
        #expect(InsightsTopic.technology.dashboardSections(for: scope) == [.languages, .topics, .licenses])
        #expect(InsightsTopic.knowledgeProfile.dashboardSections(for: scope).isEmpty)
    }

    @Test("全部收藏隐藏知识库专属整理项")
    func starredScopeHidesKnowledgeOnlyActions() {
        let organization = InsightsActionID.allCases.filter { $0.topic == .organization }
        let starred = organization.filter { $0.isAvailable(in: .starred) }

        #expect(starred == [.untagged, .unread])
        #expect(organization == [.untagged, .unread, .missingReadme, .missingIndexableContent, .indexIssues])
        #expect(InsightsActionID.allCases.filter { $0.topic == .health } ==
                [.healthPending, .openSSFPending, .maintenanceRisk, .securityRisk])
    }
}
