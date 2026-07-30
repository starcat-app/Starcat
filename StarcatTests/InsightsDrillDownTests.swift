//
//  InsightsDrillDownTests.swift
//  StarcatTests
//
//  验证“我的洞察”只生成结构化临时筛选，并且不会继承 Manage 的隐藏条件。
//

import Testing
@testable import Starcat

@Suite("Insights drill-down routing")
struct InsightsDrillDownTests {

    @Test("所有待处理动作都能从 neutral 下钻")
    func actionRoutesAreCompleteAndNeutral() throws {
        let actions: [InsightsSelection] = [
            .untagged,
            .unread,
            .missingReadme,
            .missingIndexableContent,
            .indexIssues,
            .healthPending,
            .openSSFPending,
            .maintenanceRisk,
            .securityRisk
        ]

        for action in actions {
            let route = try #require(
                InsightsDrillDownRouter.route(
                    scope: .knowledge,
                    target: .action(action),
                    embeddingModel: "embed-v1"
                )
            )
            #expect(route.selection == .library)
            #expect(!route.filters.hideArchived)
            #expect(!route.filters.hideForks)
            #expect(route.filters.globalFilterLanguages.isEmpty)
        }
    }

    @Test("状态和语言按范围生成唯一结构化条件")
    func statusAndLanguageRoutesMatchScope() throws {
        let statusRoute = try #require(
            InsightsDrillDownRouter.route(
                scope: .starred,
                target: .status(.using),
                embeddingModel: "embed-v1"
            )
        )
        #expect(statusRoute.selection == .allStars)
        #expect(statusRoute.filters.statusFilter == .using)

        let languageRoute = try #require(
            InsightsDrillDownRouter.route(
                scope: .knowledge,
                target: .language("Swift"),
                embeddingModel: "embed-v1"
            )
        )
        #expect(languageRoute.selection == .library)
        #expect(languageRoute.filters.globalFilterLanguages == ["Swift"])

        let unknownRoute = try #require(
            InsightsDrillDownRouter.route(
                scope: .starred,
                target: .language(nil),
                embeddingModel: "embed-v1"
            )
        )
        #expect(unknownRoute.filters.repoLanguageFilter == .uncategorized)
        #expect(unknownRoute.filters.globalFilterLanguages.isEmpty)
    }
}
