//
//  RAGWorkspaceBottomScrollBridge.swift
//  Starcat
//
//  将 RAG 时间线的每次“贴住尾部”请求交给当前原生滚动容器。
//

import AppKit
import QuartzCore
import SwiftUI

/// 向当前 RAG 时间线的 `NSScrollView` 发送新的尾部滚动请求。
///
/// SwiftUI 的 `ScrollPosition` 适合表达当前位置，但当它已经是 `.bottom` 时，
/// 连续流式内容增长不一定构成新的位置变化。此桥接消费递增请求编号，确保每次
/// 真实可视快照提交后都重新定位；它不保存 `ScrollViewProxy`，避免跨重绘失效。
@MainActor
struct RAGWorkspaceBottomScrollBridge: NSViewRepresentable {
    let requestID: UInt
    let shouldFollow: Bool
    let animatesScroll: Bool

    func makeNSView(context: Context) -> RAGWorkspaceBottomScrollAnchorView {
        let view = RAGWorkspaceBottomScrollAnchorView(frame: .zero)
        // 请求可能早于 SwiftUI 把 background mount 到时间线；先记录，待进入 window 后执行。
        view.apply(
            requestID: requestID,
            shouldFollow: shouldFollow,
            animatesScroll: animatesScroll
        )
        return view
    }

    func updateNSView(_ nsView: RAGWorkspaceBottomScrollAnchorView, context: Context) {
        nsView.apply(
            requestID: requestID,
            shouldFollow: shouldFollow,
            animatesScroll: animatesScroll
        )
    }
}

/// 放在时间线末尾的零尺寸原生视图。
///
/// 请求使用下一轮主运行循环执行：此时 SwiftUI 已把最新 Markdown 高度提交给
/// `NSScrollView.documentView`。延迟的是稳定的原生 anchor，而非会过期的 SwiftUI proxy；
/// 用户手势开始后 `shouldFollow` 会更新为 false，尚未执行的请求会被丢弃。
@MainActor
final class RAGWorkspaceBottomScrollAnchorView: NSView {
    private var pendingRequestID: UInt = 0
    private var handledRequestID: UInt = 0
    private var shouldFollow = true
    private var animatesPendingScroll = false
    private var isScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedulePendingScroll()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // 初次 mount 时可能已进入 window、但尚未挂到 ScrollView 层级；此回调是容器
        // 关系稳定后的补偿点。这里不轮询，避免异常层级下持续占用主线程。
        schedulePendingScroll()
    }

    /// 同步 SwiftUI 最新请求与用户跟随意图。
    func apply(requestID: UInt, shouldFollow: Bool, animatesScroll: Bool) {
        self.shouldFollow = shouldFollow
        animatesPendingScroll = animatesScroll
        guard requestID != pendingRequestID else { return }
        pendingRequestID = requestID
        schedulePendingScroll()
    }

    private func schedulePendingScroll() {
        guard pendingRequestID != handledRequestID,
              !isScheduled,
              window != nil else {
            return
        }

        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isScheduled = false
            performPendingScrollIfNeeded()
        }
    }

    private func performPendingScrollIfNeeded() {
        guard pendingRequestID != handledRequestID else { return }
        guard shouldFollow else {
            // 用户已开始拖动时取消旧请求；之后只有新请求才会恢复跟随。
            handledRequestID = pendingRequestID
            return
        }
        guard let scrollView = verticalScrollView,
              let documentView = scrollView.documentView else {
            return
        }

        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let targetY: CGFloat
        if documentView.isFlipped {
            targetY = max(
                documentView.bounds.minY,
                documentView.bounds.maxY - clipView.bounds.height
            )
        } else {
            targetY = documentView.bounds.minY
        }
        let targetOrigin = NSPoint(x: clipView.bounds.origin.x, y: targetY)
        if animatesPendingScroll {
            // 动画只来自用户点击，不能用于高频流式更新；否则新 token 会不断重设
            // 进行中的动画，造成视口“追逐”底部的卡顿感。
            //
            // 时长按滚动量自适应：固定 0.22s 在长会话里会像被拽下去；短距又拖太久。
            // 钳在 0.35…0.65s，easeInEaseOut 起停更稳。
            let distance = abs(clipView.bounds.origin.y - targetY)
            let duration = Self.scrollAnimationDuration(forDistance: distance)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                clipView.animator().setBoundsOrigin(targetOrigin)
            } completionHandler: {
                scrollView.reflectScrolledClipView(clipView)
            }
        } else {
            clipView.scroll(to: targetOrigin)
            scrollView.reflectScrolledClipView(clipView)
        }
        handledRequestID = pendingRequestID
    }

    /// 按垂直距离估算点击「滚到底」的动画时长；单位 pt。
    private static func scrollAnimationDuration(forDistance distance: CGFloat) -> TimeInterval {
        // 约每 1800pt 对应 1s，短跳也不低于 0.35s，避免「闪一下」；长跳封顶 0.65s。
        let scaled = Double(distance) / 1800
        return min(0.65, max(0.35, scaled))
    }

    /// 选择包含当前 anchor 的最近一个可垂直滚动容器，避开未来消息块内部可能新增的
    /// 局部 scroll view。当前 anchor 位于时间线最末尾，因此最近可滚动祖先就是中栏。
    private var verticalScrollView: NSScrollView? {
        var candidate: NSView? = self
        while let current = candidate {
            if let scrollView = current as? NSScrollView,
               let documentView = scrollView.documentView,
               documentView.bounds.height > scrollView.contentView.bounds.height {
                return scrollView
            }
            candidate = current.superview
        }
        return enclosingScrollView
    }
}
