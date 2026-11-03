//
//  GitHubNotificationIssueSummaryResizablePanel.swift
//  Starcat
//
//  总结面板的局部纵向尺寸容器。只拉伸顶边，宽度与底边由外层锚点固定；
//  拖动状态不写入会话、详情页或中栏，避免高频尺寸更新重新派生整页内容。
//

import SwiftUI

/// 容器始终保留，正文仅展开时挂载：收起后保留本帖高度，同时停止隐藏正文的布局更新。
struct GitHubNotificationIssueSummaryResizablePanel<Content: View>: View {
    let isPresented: Bool
    let width: CGFloat
    let maximumHeight: CGFloat
    let transition: AnyTransition
    let content: Content

    @Environment(\.locale) private var locale
    @State private var preferredHeight: CGFloat = 480
    @GestureState private var dragTranslation: CGFloat = 0

    /// 从当前可见高度开始拉伸，不能从超出视口的偏好值开始，否则小窗口向下拖也不会缩小。
    private var baseHeight: CGFloat { clampedHeight(preferredHeight) }
    private var panelHeight: CGFloat { clampedHeight(baseHeight - dragTranslation) }

    var body: some View {
        if isPresented {
            content
                .frame(width: width, height: panelHeight)
                .overlay(alignment: .top) { resizeHandle }
                .transition(transition)
        }
    }

    /// 顶边独占 10pt 命中带，不把手势挂到标题或正文，保留复制、关闭和滚动操作。
    private var resizeHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 32, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: 10)
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .pointerStyle(.rowResize)
            .gesture(resizeGesture)
            .help("activity.issueSummary.resizeHeight")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("activity.issueSummary.resizeHeight"))
            .accessibilityValue(Text(Int(panelHeight), format: .number.locale(locale)))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: preferredHeight = clampedHeight(baseHeight + 32)
                case .decrement: preferredHeight = clampedHeight(baseHeight - 32)
                @unknown default: break
                }
            }
    }

    /// 顶边本身会移动，必须用 global 坐标累计位移；局部坐标会把面板移动再算进下一帧。
    /// GestureState 在结束或取消时自动复位，只有拖动结束才保存本帖的高度偏好。
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($dragTranslation) { value, translation, transaction in
                transaction.animation = nil
                translation = value.translation.height
            }
            .onEnded { value in
                preferredHeight = clampedHeight(baseHeight - value.translation.height)
            }
    }

    /// 小视口优先尊重详情页边界，最小 300pt 不能把面板强行撑出可用区域。
    private func clampedHeight(_ height: CGFloat) -> CGFloat {
        let upperBound = max(0, maximumHeight)
        let lowerBound = min(300, upperBound)
        return min(upperBound, max(lowerBound, height))
    }
}
