//
//  KnowledgeRAGWorkspaceView.swift
//  Starcat
//
//  知识库 RAG 三栏工作台的窗口级容器。
//

import SwiftUI

/// RAG 工作台三栏尺寸约束与持久化键。
///
/// 左右栏允许用户拖拽，但必须给中栏保留稳定的问答阅读空间；持久化值也要在读取时钳制，
/// 避免旧版本、手工修改 defaults 或未来范围调整后恢复出不可用布局。
enum RAGWorkspaceLayoutMetrics {
    static let leftMinimumWidth: CGFloat = 250
    static let leftIdealWidth: CGFloat = 318
    static let leftMaximumWidth: CGFloat = 380

    // 这是窗口级宽度预算，不直接作为 Answer Surface 的 frame 下限。NavigationSplitView
    // 与 Inspector 会分别协商列宽；把 480pt 再挂到中栏会在最小窗口拖拽时形成冲突，
    // 让系统通过裁切边缘列满足所有局部约束。
    static let answerMinimumWidth: CGFloat = 480

    static let rightMinimumWidth: CGFloat = 320
    // 首次打开保持紧凑；用户拖拽后的真实宽度由 Inspector 栏内测量写回并优先恢复。
    static let rightDefaultWidth = rightMinimumWidth
    static let rightMaximumWidth: CGFloat = 520

    // Window Scene 与旧 AppKit 窗口的布局时序不同，左栏不能复用迁移前的宽度记录。
    static let leftWidthDefaultsKey = "RAGWorkspace.SceneV2.LeftColumnWidth"
    // v2 的 HSplitView 测量没有稳定落盘；v3 由原生 Inspector 在栏内直接写回真实宽度。
    static let rightWidthDefaultsKey = "RAGWorkspace.SceneV3.RightColumnWidth"

    /// 共享布局只接收本工作台的尺寸与偏好键，避免两个窗口互相覆盖栏宽。
    static let columnLayout = WorkspaceColumnLayout(
        left: .init(minimum: leftMinimumWidth, ideal: leftIdealWidth,
                    maximum: leftMaximumWidth, defaultsKey: leftWidthDefaultsKey),
        right: .init(minimum: rightMinimumWidth, ideal: rightDefaultWidth,
                     maximum: rightMaximumWidth, defaultsKey: rightWidthDefaultsKey)
    )

    static func clampedLeftWidth(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), leftMinimumWidth), leftMaximumWidth)
    }

    static func clampedRightWidth(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), rightMinimumWidth), rightMaximumWidth)
    }
}

struct KnowledgeRAGWorkspaceView: View {
    @Environment(\.ragSettingsNavigation) private var settingsNavigation
    @Environment(AppDependencies.self) private var dependencies

    @Bindable var chromeState: WorkspaceChromeState
    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel

    /// 保存栏宽不发布布局更新；Inspector 重建时仍恢复本窗口最后一次拖动结果。
    @State private var columnWidthPersistence = WorkspaceColumnWidthPersistence(
        layout: RAGWorkspaceLayoutMetrics.columnLayout
    )

    var body: some View {
        WorkspaceColumns(chromeState: chromeState, columnWidths: columnWidthPersistence) {
            RAGWorkspaceConversationRail(viewModel: viewModel)
        } runSurface: {
            RAGWorkspaceAnswerSurface(viewModel: viewModel)
        } inspector: {
            RAGWorkspaceInspector(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // RAG 是独立窗口，无底层 WKWebView cursor 穿透问题。
        // `defaultCursorShield` 会在 mouseMoved 里强制 NSCursor.arrow，盖掉
        // Markdown 链接与芯片的 pointing-hand，故此处不加。
        .task {
            // 先提交轻量占位，完整 Context Usage 由 ViewModel 在后台生成；不能让首帧
            // 因历史消息映射和 token 估算阻塞。
            viewModel.refreshComposerContextUsage()
            await viewModel.bootstrap()
        }
        .task { await viewModel.observeKnowledgeBoundaryChanges() }
        .task { await viewModel.observeIndexChanges() }
        .onChange(of: dependencies.settings.aiProviderProfiles) { _, _ in
            viewModel.refreshAvailableModels()
        }
        .onChange(of: dependencies.settings.ragPromptSettings) { _, _ in
            viewModel.refreshComposerContextUsage()
        }
        .onChange(of: dependencies.settings.ragRetrievalSettings) { _, _ in
            viewModel.refreshComposerContextUsage()
        }
        .onChange(of: dependencies.settings.ragInferenceBackend) { _, _ in
            viewModel.refreshComposerContextUsage()
        }
        .environment(\.openURL, OpenURLAction { url in
            if viewModel.openCitationLink(url) { return .handled }
            viewModel.handleLink(url)
            return .handled
        })
        .ragWorkspaceErrorAlert(
            error: Binding(
                get: {
                    viewModel.workspaceError
                        ?? viewModel.errorMessage.map(RAGWorkspaceError.init(technicalDetail:))
                },
                set: { if $0 == nil { viewModel.dismissError() } }
            ),
            onAction: { presentedError in
                // 向量化错误应直达向量模型配置，而不是只打开设置首页让用户自行定位。
                if presentedError.action == .openAISettings {
                    settingsNavigation(presentedError.settingsNavigationTarget)
                    viewModel.dismissError()
                } else {
                    viewModel.resolveWorkspaceErrorAction(presentedError.action)
                }
            }
        )
        .sheet(isPresented: $viewModel.isAddToLibraryPresented) {
            RAGAddToLibrarySheet()
                .environment(dependencies)
                .environment(\.starcatInterfaceScale, dependencies.settings.interfaceScale)
                .dynamicTypeSize(dependencies.settings.interfaceScale.dynamicTypeSize)
                .appLocaleEnvironment()
        }
        // 标题编辑挂在整窗容器上：左栏宽度只有 ~250–380，挂在侧栏会被系统压成窄 alert。
        .sheet(item: $viewModel.titleEditRequest) { request in
            RAGWorkspaceTitleEditSheet(
                titleKey: request.titleKey,
                placeholderKey: request.placeholderKey,
                draft: $viewModel.titleEditDraft,
                onCancel: { viewModel.dismissTitleEdit() },
                onConfirm: {
                    Task { await viewModel.confirmTitleEdit() }
                }
            )
            .environment(\.starcatInterfaceScale, dependencies.settings.interfaceScale)
            .dynamicTypeSize(dependencies.settings.interfaceScale.dynamicTypeSize)
            .presentationSizing(.fitted)
        }
    }

}
