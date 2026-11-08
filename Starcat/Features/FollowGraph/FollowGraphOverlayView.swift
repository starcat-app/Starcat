//
//  FollowGraphOverlayView.swift
//  Starcat
//
//  全窗口画布和悬浮操作区。没有左右分栏；查找结果同时提供键盘可用的文本入口，
//  选中路径只代表本地已加载图，不暗示 GitHub 全网最短路径。
//

import SwiftUI
import AppKit

/// 产品入口完全免费；用户、认证客户端和生命周期由主窗口传入。
struct FollowGraphOverlayView: View {
    @Bindable var model: FollowGraphViewModel
    let user: GitHubUserDTO
    let client: GitHubAPIClient
    var relation: FollowGraphRelation = .following
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var canvasPrepared = false
    @State private var cardContentHeight: CGFloat = 280
    @State private var toolbarHeight: CGFloat = 28
    @State private var canvasSize = CGSize.zero
    @State private var toolbarExpanded = false
    @State private var toolbarHovered = false
    @State private var refreshHovered = false
    @State private var showsInitializeConfirmation = false
    // 每个控件使用唯一焦点值，Tab 移向操作按钮或结果后也不会被自动收起打断。
    @FocusState private var focusedControl: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 与 Canvas 的主题底色一致，WebKit 加载期间也不会露出另一种颜色。
            Color(white: colorScheme == .dark ? 28.0 / 255 : 245.0 / 255).ignoresSafeArea()
            if canvasPrepared, !model.isPreparing {
                FollowGraphWebView(model: model, graphRevision: model.revision,
                                   selectionID: model.selectedID, viewportRevision: model.viewportRevision,
                                   avatarRevision: model.avatarUpdate?.revision ?? 0)
                    .id(model.rendererRevision)
                    .ignoresSafeArea()
                    .opacity(model.rendererPresented ? 1 : 0)
                    .allowsHitTesting(model.rendererPresented)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.rendererPresented)
            }
            // 只放实际大小的卡片，避免透明的全屏布局容器参与画布事件命中。
            if canvasPrepared, let node = model.selected {
                selectedInfo(node)
                    .transition(reduceMotion ? .opacity : .offset(y: 12).combined(with: .opacity))
                    // 移除过渡仍需位于不透明画布之上，否则关闭会直接消失。
                    .zIndex(1)
            }
            VStack(spacing: 8) {
                toolbarPanel
                    .frame(maxWidth: .infinity, alignment: .top)
                Spacer(minLength: 0)
                if model.rendererError {
                    Button("followGraph.action.reloadRenderer") {
                        model.rendererError = false
                        model.rendererRevision += 1
                    }
                    .buttonStyle(.bordered)
                }
            }
            .overlay(alignment: .topTrailing) {
                SheetCloseButton(action: onClose)
                    .accessibilityLabel(Text("common.close"))
            }
            .padding(16)
            .zIndex(2)
        }
        .toast(message: $model.toastMessage,
               icon: model.toastIsError ? "exclamationmark.circle.fill" : "info.circle.fill",
               duration: model.toastIsError ? 4 : 2,
               iconColor: model.toastIsError ? .orange : nil,
               bottomPadding: model.selected != nil && canvasSize.width < 1_100 ? cardHeight + 36 : 24)
        .alert("followGraph.initialize.title", isPresented: $showsInitializeConfirmation) {
            Button("common.cancel", role: .cancel) {}
            Button("followGraph.action.initialize") {
                focusedControl = nil
                model.initialize()
            }
        } message: {
            Text("followGraph.initialize.message")
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        .animation(.easeOut(duration: reduceMotion ? 0.16 : 0.22), value: model.selectedID != nil)
        .task {
            // open 会重置 rendererRevision；先初始化再挂载，避免初次出现就销毁重建 WebView。
            model.open(user: user, client: client, relation: relation)
            canvasPrepared = true
        }
        .task(id: shouldAutoHideToolbar) {
            guard shouldAutoHideToolbar else { return }
            // 结构化任务在重新悬停、输入获焦或浮层关闭时取消，旧计时不能收起新交互。
            do {
                try await Task.sleep(for: .milliseconds(1_500))
            } catch { return }
            guard !Task.isCancelled, shouldAutoHideToolbar else { return }
            toolbarExpanded = false
        }
        .onChange(of: focusedControl) { _, control in
            if let control {
                toolbarExpanded = true
                if control == "handle" { focusedControl = "search" }
            }
        }
        .onChange(of: model.search) { _, search in
            if !search.isEmpty { toolbarExpanded = true }
        }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.stop() } }
    }

    /// 只对实际浮层范围感应悬停；不把透明全窗口容器变成画布的事件遮挡层。
    private var toolbarPanel: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                if toolbarExpanded {
                    toolbar
                        .transition(toolbarTransition)
                } else {
                    Button {
                        toolbarExpanded = true
                        focusedControl = "search"
                    } label: {
                        Capsule()
                            .fill(.secondary)
                            .frame(width: 44, height: 4)
                            .frame(width: 96, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .focused($focusedControl, equals: "handle")
                    .accessibilityLabel(Text("followGraph.action.showToolbar"))
                    .help(String.l10n("followGraph.action.showToolbar"))
                    .transition(toolbarTransition)
                }
            }
            .frame(width: toolbarExpanded ? min(440, max(120, canvasSize.width - 112)) : 96)
            // Reduce Motion 只淡换内容，不对外框宽度或位置做插值。
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: toolbarExpanded)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolbarHeight = $0 }
            if toolbarExpanded, !model.search.isEmpty {
                searchResults
                    .transition(.opacity)
            }
        }
        // 搜索结果与工具栏共享悬停区域，中间间隙不会触发提前收起。
        .contentShape(Rectangle())
        .onHover { hovering in
            toolbarHovered = hovering
            if hovering { toolbarExpanded = true }
        }
    }

    private var toolbarTransition: AnyTransition {
        // 将内容过渡的动画附在 transition 上，减少动态效果时外框可以直接切换尺寸。
        let transition: AnyTransition = reduceMotion ? .opacity : .offset(y: -6).combined(with: .opacity)
        return transition.animation(.easeInOut(duration: 0.2))
    }

    private var shouldAutoHideToolbar: Bool {
        toolbarExpanded && !toolbarHovered && focusedControl == nil && !showsInitializeConfirmation
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                searchField
                actions
            }
            VStack(spacing: 8) {
                searchField
                actions
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var searchField: some View {
        TextField("followGraph.search.placeholder", text: $model.search)
            .textFieldStyle(.roundedBorder)
            .focused($focusedControl, equals: "search")
            .frame(minWidth: 120, idealWidth: 210, maxWidth: 280)
            .onSubmit {
                if let first = model.results.first {
                    model.select(first.id, expand: false)
                    model.focus(first.id)
                    model.search = ""
                    focusedControl = nil
                }
            }
    }

    private var actions: some View {
        HStack(spacing: 14) {
            // 停止后的视觉状态必须立即与真实任务一致，关闭最短旋转兜底。
            // 同一按钮在加载期间始终执行停止，悬停 / 键盘聚焦只改变图标。
            SyncIconButton(isRefreshing: model.isLoading,
                           showsStop: model.isLoading && (refreshHovered || focusedControl == "refresh"),
                           minVisibleDuration: 0,
                           tooltip: model.isLoading ? String.l10n("followGraph.action.stop") :
                            (model.errorText ?? String.l10n("followGraph.action.refresh"))) {
                if model.isLoading { model.stop() } else { model.refresh() }
            }
                .focused($focusedControl, equals: "refresh")
                .onHover { refreshHovered = $0 }
            tool("arrow.up.left.and.arrow.down.right", "followGraph.action.reset") { model.focus(nil) }
            tool("person.crop.circle", "followGraph.action.self") { model.focus(model.snapshot?.rootID) }
            Divider().frame(height: 18)
            // 初始化改变展示范围并重播入场，独立分组，不能与网络刷新或视角适配混淆。
            tool("arrow.counterclockwise.circle", "followGraph.action.initialize") {
                showsInitializeConfirmation = true
            }
            .disabled(model.isPreparing || model.snapshot == nil)
        }
    }

    private func tool(_ symbol: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedControl, equals: key)
        .help(String.l10n(key))
        .accessibilityLabel(Text(LocalizedStringKey(key)))
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if model.results.isEmpty {
                    Text("followGraph.search.empty").foregroundStyle(.secondary).padding(8)
                }
                ForEach(model.results) { node in
                    Button {
                        model.select(node.id, expand: false)
                        model.focus(node.id)
                        model.search = ""
                        focusedControl = nil
                    } label: {
                        HStack {
                            Text(verbatim: node.name ?? node.login).foregroundStyle(.primary)
                            Text(verbatim: "@\(node.login)").foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .focused($focusedControl, equals: "result.\(node.id)")
                }
            }
        }
        .frame(maxWidth: 440, maxHeight: 230)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func selectedInfo(_ node: FollowGraphNode) -> some View {
        let width = min(370, max(1, canvasSize.width - 40))
        let height = cardHeight
        return ScrollView {
            FollowGraphUserCard(node: node, model: model)
                .id(node.id)
                .transition(.opacity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardContentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // 只淡换卡片内容，不把外框尺寸或位置变化纳入切换动画。
        .animation(.easeInOut(duration: 0.16), value: node.id)
        .frame(width: width, height: height)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        // 用实际卡片尺寸定位，卡片以外的画布保持命中；节点移出视野也不隐藏资料。
        .offset(x: max(20, canvasSize.width - width - 20), y: max(toolbarHeight + 40, canvasSize.height - height - 20))
    }

    /// 窄窗口把提示放在卡片上方，复用实际滚动高度，避免底部 Toast 覆盖加载按钮。
    private var cardHeight: CGFloat {
        min(cardContentHeight, max(1, canvasSize.height - toolbarHeight - 60))
    }
}
