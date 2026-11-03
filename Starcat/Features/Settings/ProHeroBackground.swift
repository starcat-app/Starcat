//
//  ProHeroBackground.swift
//  Starcat
//
//  已开通 Pro 顶部卡片的暖色背景。只负责装饰，不读取授权信息或参与内容尺寸计算。
//  按本次确认的视觉方案局部使用暖色渐变；其他设置分组继续沿用原生表面。
//

import SwiftUI

/// 为已激活卡片提供香槟金 / 深琥珀底色，以及可真正暂停的低幅度渐变动画。
struct ProHeroBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatContinuousAnimationsPaused) private var continuousAnimationsPaused

    @State private var isVisible = false

    private var isDark: Bool { colorScheme == .dark }
    private var canAnimate: Bool {
        isVisible && appearsActive && scenePhase == .active
            && !reduceMotion && !continuousAnimationsPaused
    }

    var body: some View {
        ZStack {
            baseColor

            if canAnimate {
                // 相位只在端点切换，渐变之间由系统插值；不建立逐帧更新的 TimelineView 或 Timer。
                // 往返各 8 秒。暂停时移除整个 PhaseAnimator，避免隐藏后仍持续消耗渲染资源。
                PhaseAnimator([false, true]) { phase in
                    warmthLayers(isShifted: phase)
                } animation: { _ in
                    .easeInOut(duration: 8)
                }
            } else {
                warmthLayers(isShifted: false)
            }

            // 稳定的浅层底色压低文字区域的色差，主文字和绿色权益状态不随暖色漂移闪动。
            LinearGradient(
                colors: [baseColor.opacity(0.45), baseColor.opacity(0.18), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    /// 两套底色独立控制亮度，深色不直接复用浅色金色叠加，避免背景变亮影响文字对比。
    private var baseColor: Color {
        isDark
            ? Color(red: 0.20, green: 0.15, blue: 0.10)
            : Color(red: 1.0, green: 0.96, blue: 0.88)
    }

    /// GeometryReader 只读取宿主行的既定尺寸；位移与透明度不反向影响 Form 的行高。
    private func warmthLayers(isShifted: Bool) -> some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                Ellipse()
                    .fill(RadialGradient(
                        colors: [Color.orange.opacity(isDark ? 0.26 : 0.32), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size.width * 0.48
                    ))
                    .frame(width: size.width * 1.05, height: size.height * 2.4)
                    .offset(
                        x: size.width * (isShifted ? 0.16 : -0.08),
                        y: size.height * (isShifted ? -0.22 : 0.10)
                    )

                Ellipse()
                    .fill(RadialGradient(
                        colors: [Color(red: 1.0, green: 0.48, blue: 0.36).opacity(isDark ? 0.12 : 0.16), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size.width * 0.40
                    ))
                    .frame(width: size.width * 0.90, height: size.height * 2.0)
                    .offset(
                        x: size.width * (isShifted ? -0.12 : 0.18),
                        y: size.height * (isShifted ? 0.18 : -0.12)
                    )
            }
            .frame(width: size.width, height: size.height)
            .opacity(isShifted ? 0.85 : 1.0)
        }
    }
}
