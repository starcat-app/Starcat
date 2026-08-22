//
//  GettingStartedProgressStoreTests.swift
//  StarcatTests
//
//  验证正式版 Getting Started 清单的公开步骤统计与持久化边界。
//  每个测试使用独立 UserDefaults suite，避免污染真实用户的引导进度。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Getting Started Progress")
struct GettingStartedProgressStoreTests {

    /// 创建并清空隔离 suite，确保测试可重复运行且不会相互继承完成状态。
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "test.starcat.getting-started.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("正式清单不包含尚未开放的 Agent 工作台")
    func publicGuideExcludesAgentWorkspace() {
        let defaults = makeIsolatedDefaults()
        let store = GettingStartedProgressStore(defaults: defaults)

        #expect(!GettingStartedProgressStore.StepID.guideCases.map(\.rawValue).contains("useAgentWorkspace"))
        #expect(store.totalCount == 11)
    }

    @Test("完成全部公开步骤后清单结束")
    func completingPublicStepsCompletesGuide() {
        let defaults = makeIsolatedDefaults()
        let store = GettingStartedProgressStore(defaults: defaults)

        for step in GettingStartedProgressStore.StepID.guideCases {
            store.markCompleted(step)
        }

        #expect(store.completedCount == store.totalCount)
        #expect(store.isComplete)
    }
}
