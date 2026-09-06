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

    static func clampedLeftWidth(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), leftMinimumWidth), leftMaximumWidth)
    }

    static func clampedRightWidth(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), rightMinimumWidth), rightMaximumWidth)
    }
}

struct KnowledgeRAGWorkspaceView: View {
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.ragSettingsNavigation) private var settingsNavigation
    @Environment(AppDependencies.self) private var dependencies

    @Bindable var chromeState: WorkspaceChromeState
    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel

    @AppStorage(RAGWorkspaceLayoutMetrics.leftWidthDefaultsKey)
    private var persistedLeftColumnWidth = Double(RAGWorkspaceLayoutMetrics.leftIdealWidth)
    @AppStorage(RAGWorkspaceLayoutMetrics.rightWidthDefaultsKey)
    private var persistedRightColumnWidth = Double(RAGWorkspaceLayoutMetrics.rightDefaultWidth)

    /// 拖动期间只更新布局测量值，停止变化后再落盘，避免每个 mouse-drag 事件都写 UserDefaults。
    @State private var lastMeasuredLeftColumnWidth: CGFloat?
    @State private var lastMeasuredRightColumnWidth: CGFloat?
    @State private var leftWidthPersistenceTask: Task<Void, Never>?
    @State private var rightWidthPersistenceTask: Task<Void, Never>?

    private var restoredLeftColumnWidth: CGFloat {
        RAGWorkspaceLayoutMetrics.clampedLeftWidth(persistedLeftColumnWidth)
    }

    private var restoredRightColumnWidth: CGFloat {
        RAGWorkspaceLayoutMetrics.clampedRightWidth(persistedRightColumnWidth)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $chromeState.leftColumnVisibility) {
            RAGWorkspaceConversationRail(viewModel: viewModel)
                .navigationSplitViewColumnWidth(
                    min: RAGWorkspaceLayoutMetrics.leftMinimumWidth,
                    ideal: restoredLeftColumnWidth,
                    max: RAGWorkspaceLayoutMetrics.leftMaximumWidth
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.width, initial: true) { _, width in
                                scheduleLeftWidthPersistence(width)
                            }
                    }
                }
                // NavigationSplitView 的 Sidebar 是独立 preference 边界，尺寸不能再向
                // 根视图上传；在列内直接监听 GeometryReader，才能可靠写回 @AppStorage。
        } detail: {
            GeometryReader { proxy in
                RAGWorkspaceAnswerSurface(viewModel: viewModel)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            // 中栏只填充 NavigationSplitView 已分配的尺寸，不把内容固有宽度带回三栏协商；
            // 否则在最小窗口拖动 Inspector 时，SwiftUI 会反复重算布局并导致主线程卡死。
        }
        // Citation 是语义明确的 trailing inspector。使用系统 Inspector 后，宽度约束
        // 会直接进入分栏控制器，不再依赖 HSplitView 对普通 idealWidth 的布局猜测。
        .inspector(isPresented: $chromeState.isRightColumnPresented) {
            RAGWorkspaceInspector(viewModel: viewModel)
                .inspectorColumnWidth(
                    min: RAGWorkspaceLayoutMetrics.rightMinimumWidth,
                    ideal: restoredRightColumnWidth,
                    max: RAGWorkspaceLayoutMetrics.rightMaximumWidth
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.width, initial: true) { _, width in
                                scheduleRightWidthPersistence(width)
                            }
                    }
                }
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
        .onDisappear {
            // 用户可能拖完立即关闭窗口；同步提交最后测量值，不能依赖 debounce 任务来得及执行。
            persistLastMeasuredWidths()
            leftWidthPersistenceTask?.cancel()
            rightWidthPersistenceTask?.cancel()
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
                if presentedError.action == .openAISettings,
                   presentedError.kind == .embeddingConfiguration
                       || presentedError.kind == .embeddingRequest {
                    settingsNavigation("ai.embedding")
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: chromeState.isRightColumnCollapsed)
    }

    /// 原生 Sidebar 与 Inspector 都会连续报告尺寸；静止 250ms 后才保存最终值。
    private func scheduleLeftWidthPersistence(_ measuredWidth: CGFloat) {
        guard !chromeState.isLeftColumnCollapsed,
              measuredWidth >= RAGWorkspaceLayoutMetrics.leftMinimumWidth else { return }

        let width = RAGWorkspaceLayoutMetrics.clampedLeftWidth(Double(measuredWidth))
        lastMeasuredLeftColumnWidth = width
        guard abs(CGFloat(persistedLeftColumnWidth) - width) > 0.5 else { return }

        leftWidthPersistenceTask?.cancel()
        leftWidthPersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            persistedLeftColumnWidth = Double(width)
        }
    }

    private func scheduleRightWidthPersistence(_ measuredWidth: CGFloat) {
        guard !chromeState.isRightColumnCollapsed,
              measuredWidth >= RAGWorkspaceLayoutMetrics.rightMinimumWidth else { return }

        let width = RAGWorkspaceLayoutMetrics.clampedRightWidth(Double(measuredWidth))
        lastMeasuredRightColumnWidth = width
        guard abs(CGFloat(persistedRightColumnWidth) - width) > 0.5 else { return }

        rightWidthPersistenceTask?.cancel()
        rightWidthPersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            persistedRightColumnWidth = Double(width)
        }
    }

    private func persistLastMeasuredWidths() {
        if let width = lastMeasuredLeftColumnWidth {
            persistedLeftColumnWidth = Double(width)
        }
        if let width = lastMeasuredRightColumnWidth {
            persistedRightColumnWidth = Double(width)
        }
    }
}
