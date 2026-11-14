//
//  SkillWorkspaceSceneCoordinator.swift
//  Starcat
//
//  本机 Skill 工作台的应用级组合点。窗口状态不依赖 GitHub 账号，
//  且必须先检查渠道，再创建模型；App Store 启动和 Scene 求值不能产生本机库副作用。
//

import Observation

/// 保留本机工作台会话，重复打开只激活同一个 SwiftUI Window Scene。
@MainActor
@Observable
final class SkillWorkspaceSceneCoordinator {
    static let sceneID = "skill-workspace-v1"
    static let shared = SkillWorkspaceSceneCoordinator()

    private(set) var viewModel: SkillWorkspaceViewModel?
    @ObservationIgnored private let distributionGate: DistributionGate
    @ObservationIgnored private let makeViewModel: () -> SkillWorkspaceViewModel

    /// 注入工厂用于验证拒绝渠道时不会初始化后续的数据库、扫描器或 watcher。
    init(
        distributionGate: DistributionGate = DistributionGate(),
        makeViewModel: @escaping () -> SkillWorkspaceViewModel = { SkillWorkspaceViewModel() }
    ) {
        self.distributionGate = distributionGate
        self.makeViewModel = makeViewModel
    }

    var isAvailable: Bool {
        distributionGate.isAvailable(.skillManagement)
    }

    /// 菜单与后续定位入口共用执行层门控；不能只靠菜单隐藏保证渠道边界。
    func openWindow(using action: (String) -> Void) throws {
        try distributionGate.requireDirect(.skillManagement)
        if viewModel == nil {
            viewModel = makeViewModel()
        }
        action(Self.sceneID)
    }
}
