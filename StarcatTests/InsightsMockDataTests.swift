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

    @Test("Star 历史按时间递增并校准到当前值")
    func starHistoryIsChronologicalAndCalibrated() {
        let repo = Repo.makeMinimal(owner: "starcat-app", name: "starcat")
        let snapshot = InsightsMockData.repositoryInsights(for: repo)

        #expect(snapshot.starHistory.count == 13)
        #expect(snapshot.starHistory.map(\.date) == snapshot.starHistory.map(\.date).sorted())
        #expect(snapshot.starHistory.last?.count == snapshot.currentStars)
        #expect(zip(snapshot.starHistory, snapshot.starHistory.dropFirst()).allSatisfy { $0.count <= $1.count })
    }
}
