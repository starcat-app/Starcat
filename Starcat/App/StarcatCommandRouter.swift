//
//  StarcatCommandRouter.swift
//  Starcat
//
//  应用级快捷键命令路由。
//
//  为什么需要独立路由：
//  - Settings 是独立 Scene，成为 key window 后拿不到主窗口的 FocusedValue；
//  - 主窗口又有列表 / 详情两个刷新目标，必须保留最后一次明确交互的列作为兜底；
//  - 各业务页面已经有成熟刷新闭包，命令层只登记和转发，不能复制网络逻辑。
//

import Observation
import SwiftUI

/// 菜单命令可执行动作。标题用于菜单语义，`perform` 始终在 MainActor 执行 UI 路由。
@MainActor
struct StarcatCommandAction {
    let title: String
    let isEnabled: Bool
    let perform: @MainActor () -> Void
}

/// 主窗口内可被 `⌘R` 刷新的两类目标。
enum StarcatRefreshPane: String, Sendable {
    case list
    case detail
}

/// 主窗口与独立 Settings Scene 共用的命令状态。
///
/// 路由只保存短生命周期 UI 闭包；每个发布者带 owner ID，并在消失时按 owner 清理，
/// 避免旧页面的 `onDisappear` 把新页面刚登记的动作误删掉。
@MainActor
@Observable
final class StarcatCommandRouter {

    /// 应用进程内唯一的命令路由。
    ///
    /// AppKit 自建的 `NSHostingController` 不继承 `StarcatApp` Scene 的 environment，
    /// 但它们仍要把刷新与仓库 AI 动作登记到同一套菜单命令中。集中实例既避免漏注入
    /// 导致 `@Environment(StarcatCommandRouter.self)` 断言崩溃，也避免独立窗口创建
    /// 第二套路由后让快捷键操作到错误窗口。
    static let shared = StarcatCommandRouter()

    private struct RegisteredAction {
        let ownerID: UUID
        let action: StarcatCommandAction
    }

    private struct MainWindowActions {
        let ownerID: UUID
        let globalSearchShortcut: KeyboardShortcutConfiguration
        let openGlobalSearch: @MainActor () -> Void
        let openKnowledgeRAGWorkspace: @MainActor () -> Void
    }

    private var mainWindowActions: MainWindowActions?
    private var listRefreshAction: RegisteredAction?
    private var detailRefreshAction: RegisteredAction?
    private var repositoryAIAction: RegisteredAction?

    private(set) var activeRefreshPane: StarcatRefreshPane = .list

    var globalSearchShortcut: KeyboardShortcutConfiguration {
        mainWindowActions?.globalSearchShortcut ?? .globalSearchDefault
    }

    var canOpenGlobalSearch: Bool { mainWindowActions != nil }
    var canOpenKnowledgeRAGWorkspace: Bool { mainWindowActions != nil }
    var canOpenCurrentRepositoryAI: Bool {
        isRepositoryAIAvailable(preferred: nil)
    }

    /// 当前 `⌘R` 目标。详情不可刷新时必须回退列表，不能让按键静默失效。
    var currentRefreshAction: StarcatCommandAction? {
        if activeRefreshPane == .detail,
           let detail = detailRefreshAction?.action,
           detail.isEnabled {
            return detail
        }
        return listRefreshAction?.action
    }

    func registerMainWindowActions(
        ownerID: UUID,
        globalSearchShortcut: KeyboardShortcutConfiguration,
        openGlobalSearch: @escaping @MainActor () -> Void,
        openKnowledgeRAGWorkspace: @escaping @MainActor () -> Void
    ) {
        mainWindowActions = MainWindowActions(
            ownerID: ownerID,
            globalSearchShortcut: globalSearchShortcut,
            openGlobalSearch: openGlobalSearch,
            openKnowledgeRAGWorkspace: openKnowledgeRAGWorkspace
        )
    }

    func unregisterMainWindowActions(ownerID: UUID) {
        guard mainWindowActions?.ownerID == ownerID else { return }
        mainWindowActions = nil
    }

    func openGlobalSearch() {
        mainWindowActions?.openGlobalSearch()
    }

    func openKnowledgeRAGWorkspace() {
        mainWindowActions?.openKnowledgeRAGWorkspace()
    }

    /// 优先执行 key window 通过 FocusedValues 发布的仓库 AI 动作。
    ///
    /// 多个详情窗口会同时存在，单例路由里的 fallback 只能表示最后登记者；focused
    /// action 才能准确表示当前 key window，避免快捷键操作到后台窗口的仓库。
    func openCurrentRepositoryAI(preferred action: StarcatCommandAction? = nil) {
        guard let resolved = resolvedRepositoryAIAction(preferred: action) else { return }
        resolved.perform()
    }

    func isRepositoryAIAvailable(preferred action: StarcatCommandAction?) -> Bool {
        resolvedRepositoryAIAction(preferred: action) != nil
    }

    /// Refresh 同样优先服从 key window；router 状态只用于 first responder
    /// 暂时没有发布 focused value 时的菜单 fallback。
    func refreshCurrentContent(preferred action: StarcatCommandAction? = nil) {
        let resolved = action?.isEnabled == true ? action : currentRefreshAction
        guard let resolved, resolved.isEnabled else { return }
        resolved.perform()
    }

    func isRefreshAvailable(preferred action: StarcatCommandAction?) -> Bool {
        action?.isEnabled == true || currentRefreshAction?.isEnabled == true
    }

    func activate(_ pane: StarcatRefreshPane) {
        activeRefreshPane = pane
    }

    func registerRefreshAction(
        _ action: StarcatCommandAction,
        pane: StarcatRefreshPane,
        ownerID: UUID
    ) {
        let registered = RegisteredAction(ownerID: ownerID, action: action)
        switch pane {
        case .list:
            listRefreshAction = registered
        case .detail:
            detailRefreshAction = registered
        }
    }

    func unregisterRefreshAction(pane: StarcatRefreshPane, ownerID: UUID) {
        switch pane {
        case .list:
            guard listRefreshAction?.ownerID == ownerID else { return }
            listRefreshAction = nil
        case .detail:
            guard detailRefreshAction?.ownerID == ownerID else { return }
            detailRefreshAction = nil
        }
    }

    func registerRepositoryAIAction(_ action: StarcatCommandAction, ownerID: UUID) {
        repositoryAIAction = RegisteredAction(ownerID: ownerID, action: action)
    }

    func unregisterRepositoryAIAction(ownerID: UUID) {
        guard repositoryAIAction?.ownerID == ownerID else { return }
        repositoryAIAction = nil
    }

    private func resolvedRepositoryAIAction(
        preferred action: StarcatCommandAction?
    ) -> StarcatCommandAction? {
        if let action, action.isEnabled {
            return action
        }
        guard repositoryAIAction?.action.isEnabled == true else { return nil }
        return repositoryAIAction?.action
    }
}

private struct StarcatRefreshActionFocusedValueKey: FocusedValueKey {
    typealias Value = StarcatCommandAction
}

private struct StarcatRepositoryAIActionFocusedValueKey: FocusedValueKey {
    typealias Value = StarcatCommandAction
}

extension FocusedValues {
    /// key window 在主窗口时，优先遵守真实 first responder 所在列。
    var starcatRefreshAction: StarcatCommandAction? {
        get { self[StarcatRefreshActionFocusedValueKey.self] }
        set { self[StarcatRefreshActionFocusedValueKey.self] = newValue }
    }

    /// 当前 key window 的仓库 AI 动作；避免多详情窗口共用 fallback 时串仓库。
    var starcatRepositoryAIAction: StarcatCommandAction? {
        get { self[StarcatRepositoryAIActionFocusedValueKey.self] }
        set { self[StarcatRepositoryAIActionFocusedValueKey.self] = newValue }
    }
}

/// 把页面已有刷新闭包登记到菜单路由，并记录用户最后明确点击的列。
private struct StarcatRefreshCommandModifier: ViewModifier {
    @Environment(StarcatCommandRouter.self) private var router
    @State private var ownerID = UUID()

    let pane: StarcatRefreshPane
    let identity: String
    let title: String
    let isEnabled: Bool
    let action: @MainActor () -> Void

    func body(content: Content) -> some View {
        let command = StarcatCommandAction(title: title, isEnabled: isEnabled, perform: action)

        content
            .focusedValue(\.starcatRefreshAction, command)
            .simultaneousGesture(TapGesture().onEnded {
                router.activate(pane)
            })
            .onAppear {
                router.registerRefreshAction(command, pane: pane, ownerID: ownerID)
            }
            .onChange(of: identity) { _, _ in
                router.registerRefreshAction(command, pane: pane, ownerID: ownerID)
            }
            .onChange(of: isEnabled) { _, _ in
                router.registerRefreshAction(command, pane: pane, ownerID: ownerID)
            }
            .onDisappear {
                router.unregisterRefreshAction(pane: pane, ownerID: ownerID)
            }
    }
}

/// 所有仓库详情共用的 AI 命令发布器。是否可用由详情现有 `.ai` action 决定，
/// 因而快捷键不会绕过登录或 Star 状态门禁。
private struct StarcatRepositoryAICommandModifier: ViewModifier {
    @Environment(StarcatCommandRouter.self) private var router
    @State private var ownerID = UUID()

    let identity: String
    let isEnabled: Bool
    let action: @MainActor () -> Void

    func body(content: Content) -> some View {
        let command = StarcatCommandAction(
            title: String.l10n("commands.actions.openSelectedRepoAI"),
            isEnabled: isEnabled,
            perform: action
        )

        content
            .focusedValue(\.starcatRepositoryAIAction, command)
            .simultaneousGesture(TapGesture().onEnded {
                router.activate(.detail)
            })
            .onAppear {
                router.registerRepositoryAIAction(command, ownerID: ownerID)
            }
            .onChange(of: identity) { _, _ in
                router.registerRepositoryAIAction(command, ownerID: ownerID)
            }
            .onChange(of: isEnabled) { _, _ in
                router.registerRepositoryAIAction(command, ownerID: ownerID)
            }
            .onDisappear {
                router.unregisterRepositoryAIAction(ownerID: ownerID)
            }
    }
}

extension View {
    /// 注入应用级命令路由；SwiftUI Scene 与 AppKit hosting root 必须统一走这里。
    ///
    /// 参数主要用于隔离测试；生产根视图省略参数时始终使用进程内共享实例。
    @MainActor
    func starcatCommandRouterEnvironment(
        _ commandRouter: StarcatCommandRouter = .shared
    ) -> some View {
        environment(commandRouter)
    }

    /// 发布一个列表或详情刷新动作；`identity` 必须覆盖会改变刷新目标的筛选条件。
    func starcatRefreshCommand(
        pane: StarcatRefreshPane,
        identity: String,
        title: String,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(StarcatRefreshCommandModifier(
            pane: pane,
            identity: identity,
            title: title,
            isEnabled: isEnabled,
            action: action
        ))
    }

    /// 发布当前详情仓库 AI 动作。
    func starcatRepositoryAICommand(
        identity: String,
        isEnabled: Bool,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(StarcatRepositoryAICommandModifier(
            identity: identity,
            isEnabled: isEnabled,
            action: action
        ))
    }
}
