//
//  InsightsMockDataTests.swift
//  StarcatTests
//
//  锁定前端 Mock 的关键数据契约，避免 UI 调整时产生分母不一致或倒序曲线。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Insights mock data")
struct InsightsMockDataTests {

    @Test("状态分布数量与项目总数一致")
    func statusDistributionMatchesProjectCount() {
        for scope in InsightsScope.allCases {
            let snapshot = InsightsMockData.myInsights(scope: scope)
            let projectCount = snapshot.metrics.first(where: { $0.id == "projects" })?.value

            #expect(snapshot.statusItems.reduce(0) { $0 + $1.count } == projectCount)
        }
    }

    @Test("覆盖率始终落在有效区间")
    func coverageFractionsAreBounded() {
        for scope in InsightsScope.allCases {
            let snapshot = InsightsMockData.myInsights(scope: scope)

            #expect((0...1).contains(snapshot.healthCoverage.fraction))
            #expect((0...1).contains(snapshot.openSSFCoverage.fraction))
        }
    }

    @Test("最终导航把索引完整性归入整理情况")
    func finalNavigationKeepsIndexingUnderOrganization() {
        let organization = InsightsTopic.organization.selections(for: .knowledge)
        let technology = InsightsTopic.technology.selections(for: .knowledge)

        #expect(organization.contains(.missingReadme))
        #expect(organization.contains(.missingIndexableContent))
        #expect(organization.contains(.indexIssues))
        #expect(!technology.contains(.missingReadme))
        #expect(!technology.contains(.missingIndexableContent))
        #expect(!technology.contains(.indexIssues))
        #expect(technology == [.technologySummary, .languages, .topics, .licenses])
    }

    @Test("全部收藏隐藏知识库专属整理项")
    func starredScopeHidesKnowledgeOnlyActions() {
        let starred = InsightsTopic.organization.attentionSelections(for: .starred)
        let knowledge = InsightsTopic.organization.attentionSelections(for: .knowledge)

        #expect(starred == [.untagged, .unread])
        #expect(knowledge.contains(.missingReadme))
        #expect(knowledge.contains(.missingIndexableContent))
        #expect(knowledge.contains(.indexIssues))
    }

    @Test("Mock 动作覆盖当前范围所有最终待处理入口")
    func mockActionsCoverFinalAttentionSelections() {
        for scope in InsightsScope.allCases {
            let snapshot = InsightsMockData.myInsights(scope: scope)
            let expected = Set(
                InsightsTopic.organization.attentionSelections(for: scope)
                    + InsightsTopic.health.attentionSelections(for: scope)
            )

            #expect(Set(snapshot.actionItems.map(\.id)) == expected)
        }
    }

}
