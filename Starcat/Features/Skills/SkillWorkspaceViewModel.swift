//
//  SkillWorkspaceViewModel.swift
//  Starcat
//
//  独立 Skill 窗口的导航状态。首个界面提交只建立真实空态，
//  不把演示条目混入生产模型；后续由本机库快照提供内容。
//

import Observation

/// 库级筛选不使用仓库详情安装器的“待安装”等状态，避免混淆本机库与下载会话。
enum SkillWorkspaceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case managed
    case external
    case updates
    case attention

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .all: "repo.skills.list.all"
        case .managed: "skills.workspace.filter.managed"
        case .external: "skills.workspace.filter.external"
        case .updates: "skills.workspace.filter.updates"
        case .attention: "skills.workspace.filter.attention"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .managed: "shippingbox"
        case .external: "folder"
        case .updates: "arrow.down.circle"
        case .attention: "exclamationmark.circle"
        }
    }
}

/// 应用级协调器持有此会话，关闭主窗口或切换 GitHub 账号不会丢失本机导航。
@MainActor
@Observable
final class SkillWorkspaceViewModel {
    /// List 的单选绑定允许系统短暂清空选择；读取时回退到全部条目。
    var filter: SkillWorkspaceFilter? = .all
    var searchText = ""

    var selectedFilter: SkillWorkspaceFilter {
        filter ?? .all
    }
}
