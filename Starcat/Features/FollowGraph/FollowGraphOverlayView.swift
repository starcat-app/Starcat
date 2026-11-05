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
    let onClose: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardContentHeight: CGFloat = 280
    @State private var toolbarHeight: CGFloat = 100
    @State private var canvasSize = CGSize.zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            FollowGraphWebView(model: model, graphRevision: model.revision,
                               selectionID: model.selectedID, viewportRevision: model.viewportRevision)
                .id(model.rendererRevision)
                .ignoresSafeArea()
            // 只放实际大小的卡片，避免透明的全屏布局容器参与画布事件命中。
            if let node = model.selected {
                selectedInfo(node)
                    .transition(reduceMotion ? .opacity : .offset(y: 12).combined(with: .opacity))
                    // 移除过渡仍需位于不透明画布之上，否则关闭会直接消失。
                    .zIndex(1)
            }
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    Spacer(minLength: 40)
                    toolbar
                    Spacer(minLength: 8)
                    SheetCloseButton(action: onClose)
                        .accessibilityLabel(Text("common.close"))
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolbarHeight = $0 }
                if !model.search.isEmpty { searchResults }
                Spacer(minLength: 0)
                if model.rendererError {
                    Button("followGraph.action.reloadRenderer") {
                        model.rendererError = false
                        model.rendererRevision += 1
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .zIndex(2)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        .animation(.easeOut(duration: reduceMotion ? 0.16 : 0.22), value: model.selectedID != nil)
        .task { model.open(user: user, client: client) }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.stop() } }
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    Text("followGraph.title").font(.headline)
                    searchField
                    actions
                }
                VStack(spacing: 8) {
                    searchField
                    actions
                }
            }
            status
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var searchField: some View {
        TextField("followGraph.search.placeholder", text: $model.search)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 120, idealWidth: 210, maxWidth: 280)
            .onSubmit {
                if let first = model.results.first {
                    model.select(first.id, expand: false)
                    model.focus(first.id)
                    model.search = ""
                }
            }
    }

    private var actions: some View {
        HStack(spacing: 14) {
            SyncIconButton(isRefreshing: model.isLoading, disabled: model.isLoading,
                           tooltip: String.l10n("followGraph.action.refresh")) { model.refresh() }
            if model.isLoading {
                tool("stop.fill", "followGraph.action.stop") { model.stop() }
            } else {
                tool("play.fill", "followGraph.action.continue") { model.resume() }
            }
            tool("arrow.up.left.and.arrow.down.right", "followGraph.action.reset") { model.focus(nil) }
            tool("person.crop.circle", "followGraph.action.self") { model.focus(model.snapshot?.rootID) }
        }
    }

    private func tool(_ symbol: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
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
                }
            }
        }
        .frame(maxWidth: 440, maxHeight: 230)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func selectedInfo(_ node: FollowGraphNode) -> some View {
        let width = min(370, max(1, canvasSize.width - 40))
        let height = min(cardContentHeight, max(1, canvasSize.height - toolbarHeight - 60))
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

    private var status: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(model.statusKey))
                if let snapshot = model.displayedSnapshot {
                    let counts = model.renderedCounts ?? (nodes: 0, edges: 0)
                    Text(verbatim: "\(counts.nodes.formatted(.number.locale(locale))) · \(counts.edges.formatted(.number.locale(locale)))")
                        .accessibilityLabel(Text("followGraph.status.counts") +
                            Text(verbatim: " \(counts.nodes) · \(counts.edges)"))
                        .help(Text("followGraph.status.counts") + Text(verbatim: "\n") +
                              Text("followGraph.status.snapshot") + Text(verbatim: "\n") +
                              Text(snapshot.savedAt, format: .dateTime.month().day().hour().minute().locale(locale)))
                }
            }
            if let error = model.errorText { Text(verbatim: error).lineLimit(2).help(error) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
