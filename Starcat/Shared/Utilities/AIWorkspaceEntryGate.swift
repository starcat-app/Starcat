//
//  AIWorkspaceEntryGate.swift
//  Starcat
//
//  Agent 与知识库 RAG 工作台的统一入口门禁。
//

import Foundation

/// 工作台入口的判定结果。
///
/// Pro 权益优先于模型配置判断：免费用户应先看到与所点功能对应的付费墙，
/// 而不是被尚未配置的本地 AI 设置分散注意力。
enum AIWorkspaceEntryAccess {
    case allowed
    case requiresPro(ProFeature)
    case requiresChatModel
}

/// Agent 与 RAG 在创建原生窗口前共用的访问门禁。
///
/// SwiftUI 主窗口负责展示付费墙，AppKit 窗口控制器只消费这个小型判定并决定是否
/// 创建窗口。这样 Smart Collections、工具栏和引导等多个入口不会各自复制门禁逻辑，
/// 也不会先创建半初始化窗口再发现配置不完整。
@MainActor
enum AIWorkspaceEntryGate {
    /// 根据 Pro 权益和设置页「对话」任务的有效模型选择计算入口权限。
    ///
    /// 这里故意不读取 API Key：Provider 已验证且用户为对话任务选定有效模型，才是
    /// Settings 所表达的“可用对话配置”；本地 Provider 是否需要 Key 由其自身配置处理。
    static func access(
        isProUser: Bool,
        hasConfiguredChatModel: Bool,
        proFeature: ProFeature
    ) -> AIWorkspaceEntryAccess {
        guard isProUser else { return .requiresPro(proFeature) }
        guard hasConfiguredChatModel else { return .requiresChatModel }
        return .allowed
    }

    /// 在所有工作台窗口入口执行同一判定，并将失败交回现有主窗口 UI。
    static func authorizeOpening(
        dependencies: AppDependencies,
        proFeature: ProFeature
    ) -> Bool {
        switch access(
            isProUser: dependencies.entitlementGate.isProUser,
            hasConfiguredChatModel: dependencies.settings.hasConfiguredChatModel,
            proFeature: proFeature
        ) {
        case .allowed:
            return true
        case .requiresPro(let feature):
            NotificationCenter.default.post(name: .starcatWorkspaceRequiresProPaywall, object: feature)
            return false
        case .requiresChatModel:
            // 门禁只报告“为什么不能打开”，由主窗口用 SwiftUI Alert 承接交互。
            // 不能在这里发送旧的 AppKit `showSettingsWindow:` action：App Store 构建会明确
            // 要求 Settings scene 使用 SettingsLink / OpenSettingsAction，并产生运行时错误日志。
            NotificationCenter.default.post(name: .starcatWorkspaceRequiresChatModel, object: nil)
            return false
        }
    }
}

extension Notification.Name {
    /// AppKit 工作台入口请求主窗口展示对应功能的 Pro 付费墙。
    static let starcatWorkspaceRequiresProPaywall = Notification.Name("starcat.workspace.requiresProPaywall")
    /// 工作台入口缺少有效对话模型，请求主窗口展示配置引导。
    static let starcatWorkspaceRequiresChatModel = Notification.Name("starcat.workspace.requiresChatModel")
}
