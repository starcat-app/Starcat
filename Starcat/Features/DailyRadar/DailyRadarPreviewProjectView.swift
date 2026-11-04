//
//  DailyRadarPreviewProjectView.swift
//  Starcat
//
//  日报相关项目的独立详情层。复用公共仓库详情与 README 缓存，
//  不读取主窗口原选中项；只有用户显式点击 Star 才改变收藏状态。
//

import SwiftUI

/// 顶部可拖动的窄幅详情；工作区限制在阅读横条下方，不创建另一个系统窗口。
struct DailyRadarPreviewProjectView: View {
    let project: DailyRadarReport.Project
    let store: DailyRadarProjectStore
    let onBack: () -> Void
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    private let sheetShape = UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let item = store.item(for: project.id, scope: dependencies.databaseScopeRevision) {
                // Discovery 独立创建 README VM，不会错用 HomeViewModel.selectedRepo。
                DiscoveryDetailView(item: item)
                    .id(dependencies.databaseScopeRevision)
            } else if store.failed(for: project.id, scope: dependencies.databaseScopeRevision) {
                ContentUnavailableView {
                    Label("error.loadFailed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: project.id)
                } actions: {
                    Button("action.retry") {
                        Task { await store.load(project: project, dependencies: dependencies, retry: true) }
                    }
                    Link("dailyRadar.openGitHub", destination: project.url)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView { Text("weekly.detail.loadingRepo") }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: dependencies.databaseScopeRevision) {
            await store.load(project: project, dependencies: dependencies)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(sheetShape)
        .overlay(sheetShape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 18, y: -2)
        .offset(y: dragOffset)
    }

    /// 手势只安装在顶部，README 的滚动、链接和文本选择继续由原详情组件处理。
    private var header: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.secondary.opacity(0.45))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                Text(verbatim: project.id)
                    .font(scale.font(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                SheetCloseButton(action: onBack, helpKey: "dailyRadar.backToStory")
                    .accessibilityLabel(Text("dailyRadar.backToStory"))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .frame(height: 40)
        }
        .contentShape(Rectangle())
        .gesture(dismissGesture)
    }

    /// 仅明显下拉或向下甩动才关闭；轻微移动、横向拖动和上拉都回到完整高度。
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard value.translation.height > abs(value.translation.width) else { return }
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let distance = value.translation.height
                let isDownward = distance > abs(value.translation.width)
                let dismisses = distance > 110 || (distance > 24 && value.predictedEndTranslation.height > 220)
                if isDownward && dismisses {
                    onBack()
                } else {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) { dragOffset = 0 }
                }
            }
    }
}
