//
//  DetailContentTransition.swift
//  Starcat
//
//  详情页 root 切换 transition 共享 modifier。
//
//  原生展示内容统一淡入淡出并解除模糊，不改变页面位置或尺寸。
//  ZStack 协调旧内容退场与新内容入场；外层以稳定内容身份驱动 240ms 动画，
//  减少动态时使用 120ms 纯淡化。同项刷新不能通过随机身份反复触发过渡。
//
//  仅在展示子树切换身份：WKWebView、编辑状态及业务任务必须留在稳定宿主，
//  WebView 的退场 / DOM 更新 / 当前文档 ready / 入场仍由专用协调器完成。
//

import SwiftUI

extension View {

    /// 详情页 root 切换 transition modifier。
    ///
    /// 配合 ZStack、展示内容身份与外层动画使用；本 modifier 不重建内容、不启动加载。
    func detailContentTransition() -> some View {
        modifier(DetailContentTransitionModifier())
    }

}

/// 详情页 root 切换 transition 实现（私有,通过 `.detailContentTransition()`
/// extension 暴露使用入口）。
///
/// `@Environment(\.starcatReduceMotion)` 必须在 ViewModifier 内部读取
/// 而非暴露给调用方,因为 SwiftUI environment 只有在 view tree 内才有效;
/// 把环境读取下沉到 modifier 让调用方完全无需关心 reduceMotion 兜底逻辑。
private struct DetailContentTransitionModifier: ViewModifier {

    /// 开启减少动态时去掉模糊，保留内容切换所需的短淡化反馈。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(transition)
    }

    /// 新旧内容对称交接；模糊只作用于绘制层，不参与布局测量。
    private var transition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .modifier(
            active: DetailBlurFade(opacity: 0, radius: 10),
            identity: DetailBlurFade(opacity: 1, radius: 0)
        )
    }
}

/// 仅改变绘制属性，避免原生详情在交接时位移或改变布局尺寸。
private struct DetailBlurFade: ViewModifier {
    let opacity: Double
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.opacity(opacity).blur(radius: radius)
    }
}
