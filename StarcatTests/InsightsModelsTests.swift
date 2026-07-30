//
//  InsightsModelsTests.swift
//  StarcatTests
//
//  锁定洞察主题与范围的最终导航契约，避免知识库专属入口被错误放到全部收藏。
//

import Testing
@testable import Starcat

@Suite("Insights models")
struct InsightsModelsTests {

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
}
