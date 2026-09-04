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

    static let answerMinimumWidth: CGFloat = 480

    static let rightMinimumWidth: CGFloat = 320
    static let rightIdealWidth: CGFloat = 420
    static let rightMaximumWidth: CGFloat = 520

    // Window Scene 与旧 AppKit 窗口的布局时序不同，不能复用迁移时被压到最小值的宽度记录。
    static let leftWidthDefaultsKey = "RAGWorkspace.SceneV2.LeftColumnWidth"
    static let rightWidthDefaultsKey = "RAGWorkspace.SceneV2.RightColumnWidth"

    static func clampedLeftWidth(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), leftMinimumWidth), leftMaximumWidth)
    }

    static func clampedRightWidth(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), rightMinimumWidth), rightMaximumWidth)
    }
}

/// 只测量 `HSplitView` 最终分配的实际栏宽；默认值 0 代表该栏当前未挂载或已折叠。
private struct RAGWorkspaceRightWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
    private var persistedRightColumnWidth = Double(RAGWorkspaceLayoutMetrics.rightIdealWidth)

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
            // Conversation rail 使用原生 Sidebar；Answer 与 Citation Inspector 仍保留
            // 既有 HSplitView，避免牺牲右栏独立折叠、拖拽和宽度持久化能力。
            HSplitView {
                RAGWorkspaceAnswerSurface(viewModel: viewModel)
                    .frame(minWidth: RAGWorkspaceLayoutMetrics.answerMinimumWidth)
                    .layoutPriority(1)

                if !chromeState.isRightColumnCollapsed {
                    RAGWorkspaceInspector(viewModel: viewModel)
                        .frame(
                            minWidth: RAGWorkspaceLayoutMetrics.rightMinimumWidth,
                            idealWidth: restoredRightColumnWidth,
                            maxWidth: RAGWorkspaceLayoutMetrics.rightMaximumWidth
                        )
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: RAGWorkspaceRightWidthPreferenceKey.self,
                                    value: proxy.size.width
                                )
                            }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // 工作台已有右上角统一控制组；移除系统自动插入的第二个 Sidebar 按钮。
        .toolbar(removing: .sidebarToggle)
        // RAG 是独立窗口，无底层 WKWebView cursor 穿透问题。
        // `defaultCursorShield` 会在 mouseMoved 里强制 NSCursor.arrow，盖掉
        // Markdown 链接与芯片的 pointing-hand，故此处不加。
        .task { await viewModel.bootstrap() }
        .task { await viewModel.observeKnowledgeBoundaryChanges() }
        .task { await viewModel.observeIndexChanges() }
        .onPreferenceChange(RAGWorkspaceRightWidthPreferenceKey.self) { width in
            scheduleRightWidthPersistence(width)
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

    /// 原生 Sidebar 与 `HSplitView` Inspector 都会连续报告尺寸；静止 250ms 后才保存最终值。
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
