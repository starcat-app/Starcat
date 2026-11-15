//
//  SkillWorkspaceTests.swift
//  StarcatTests
//
//  验证工作台的应用级所有权与渠道惰性边界，不创建或操作任何用户窗口。
//

import Foundation
import Testing
@testable import Starcat

/// 窗口由 SwiftUI 管理单例，测试只观察进入该 Scene 的请求与会话工厂调用。
@Suite("Skill 工作台入口")
@MainActor
struct SkillWorkspaceTests {
    @Test("App Store 拒绝入口，且不创建会话或调用窗口动作")
    func appStoreDoesNotCreateWorkspace() {
        var factoryCalls = 0
        var windowCalls = 0
        let coordinator = SkillWorkspaceSceneCoordinator(
            distributionGate: .init(channel: .appStore),
            makeViewModel: {
                factoryCalls += 1
                return SkillWorkspaceViewModel()
            }
        )

        #expect(!coordinator.isAvailable)
        #expect(throws: DistributionGateError.directOnly(feature: .skillManagement, current: .appStore)) {
            try coordinator.openWindow { _ in windowCalls += 1 }
        }
        #expect(factoryCalls == 0)
        #expect(windowCalls == 0)
        #expect(coordinator.viewModel == nil)
    }

    @Test("Direct 重复打开复用会话和 Scene 身份")
    func directReusesWorkspaceSession() throws {
        var factoryCalls = 0
        var sceneIDs: [String] = []
        let coordinator = SkillWorkspaceSceneCoordinator(
            distributionGate: .init(channel: .direct),
            makeViewModel: {
                factoryCalls += 1
                return SkillWorkspaceViewModel()
            }
        )

        #expect(coordinator.viewModel == nil)
        try coordinator.openWindow { sceneIDs.append($0) }
        let firstModel = try #require(coordinator.viewModel)
        firstModel.searchText = "swift"
        try coordinator.openWindow { sceneIDs.append($0) }

        #expect(factoryCalls == 1)
        #expect(coordinator.viewModel === firstModel)
        #expect(coordinator.viewModel?.searchText == "swift")
        #expect(sceneIDs == [SkillWorkspaceSceneCoordinator.sceneID, SkillWorkspaceSceneCoordinator.sceneID])
    }

    @Test("初始化与渠道查询不会提前创建会话")
    func availabilityIsLazy() {
        var factoryCalls = 0
        let coordinator = SkillWorkspaceSceneCoordinator(
            distributionGate: .init(channel: .direct),
            makeViewModel: {
                factoryCalls += 1
                return SkillWorkspaceViewModel()
            }
        )

        #expect(coordinator.isAvailable)
        #expect(factoryCalls == 0)
        #expect(coordinator.viewModel == nil)
    }

    @Test("Skill 栏宽不读取其他工作台偏好，并钳制超出范围的旧值")
    func widthsHaveIndependentPreferences() throws {
        let suite = "SkillWorkspace.Widths.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = SkillWorkspaceWindowMetrics.columnLayout
        defaults.set(9999, forKey: AgentWorkspaceLayoutMetrics.leftWidthDefaultsKey)

        let initial = WorkspaceColumnWidthPersistence(layout: layout, defaults: defaults)
        #expect(initial.initialLeftColumnWidth == 220)
        #expect(initial.initialRightColumnWidth == 820)

        defaults.set(1, forKey: layout.left.defaultsKey)
        defaults.set(9999, forKey: layout.right.defaultsKey)
        let clamped = WorkspaceColumnWidthPersistence(layout: layout, defaults: defaults)
        #expect(clamped.initialLeftColumnWidth == 180)
        #expect(clamped.initialRightColumnWidth == 1100)
    }
}
