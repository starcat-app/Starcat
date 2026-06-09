//
//  RepoRowSkeletonView.swift
//  Starcat
//
//  骨架屏行视图，RepoListView 加载中时替代真实行显示。
//
//  设计约束：
//  - 骨架行尺寸严格匹配 RepoRowView（compact / card 两种密度）
//  - shimmer 动画必须穿越父层 `.transition` / `.animation(_:value:)` 不被吞掉
//  - 不持有任何业务数据，纯展示型组件
//
//  ⚠️ 实现踩坑（2026-06-02 修复）
//  ------------------------------------------------------------------
//  旧实现用 `onAppear { withAnimation(.repeatForever) { isAnimating = true } }`。
//  在 RepoListView 中骨架屏是通过 `.id(contentAnimationID)` 重建并以 `.transition`
//  插入的，父层同时挂着 `.animation(easeOut(0.22), value: contentAnimationID)`。
//  `withAnimation` 是"瞬时调度型"——它把动画绑到当前帧的 state 变化上；当父层 transition
//  动画正在跑时，`repeatForever` 这条 implicit 动画上下文会被吞掉，结果只跑半个 cycle
//  就停在 opacity 0.6，UI 看起来像"定格"。
//
//  正确做法（本文件采用）：
//  1. 用声明式 `.animation(.repeatForever, value: isAnimating)` 修饰符显式把动画绑到值
//     变化上，不依赖 onAppear 那一帧的动画上下文。
//  2. 用 `.task` 替代 `.onAppear` —— `.task` 在视图真正稳定后才跑，绕开 transition 重叠期。
//  3. shimmer 改用 `TimelineView(.animation)` 驱动的"移动高光带"，由 display link 直接驱动，
//     完全独立于 SwiftUI 动画系统/transition，即使外层有任何动画干扰也保证一直在跑。
//  4. 给每行加 stagger phase offset，让 shimmer 形成"波浪传递"，比齐刷刷亮灭更接近真实
//     加载反馈。
//

import SwiftUI

/// 骨架屏行视图入口：根据密度参数选子视图。
///
/// - Parameters:
///   - density: 列表密度，决定子视图布局（compact 单行 / card 多行）
///   - phaseOffset: 0...1 的相位偏移；同一时刻不同行用不同 offset，shimmer 会形成波浪效果
struct RepoRowSkeletonView: View {
    let density: RepoListDensity
    let phaseOffset: Double

    init(density: RepoListDensity, phaseOffset: Double = 0) {
        self.density = density
        self.phaseOffset = phaseOffset
    }

    var body: some View {
        // R-01 §3.1.1：仅 .card 单 case 保留，紧凑骨架已删。
        switch density {
        case .card: RepoRowSkeletonCard(phaseOffset: phaseOffset)
        }
    }
}

// MARK: - Card 骨架行

private struct RepoRowSkeletonCard: View {
    let phaseOffset: Double
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.skeletonBase)
                .frame(width: 40, height: 40)
                .shimmer(phaseOffset: phaseOffset)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.skeletonBase)
                    .frame(width: 160, height: 14)
                    .shimmer(phaseOffset: phaseOffset)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.skeletonBase)
                    .frame(height: 12)
                    .shimmer(phaseOffset: phaseOffset)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.skeletonBase)
                    .frame(width: 200, height: 12)
                    .shimmer(phaseOffset: phaseOffset)

                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.skeletonBase)
                        .frame(width: 50, height: 12)
                        .shimmer(phaseOffset: phaseOffset)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.skeletonBase)
                        .frame(width: 40, height: 12)
                        .shimmer(phaseOffset: phaseOffset)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.skeletonBase)
                        .frame(width: 60, height: 12)
                        .shimmer(phaseOffset: phaseOffset)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .opacity(pulse ? 0.85 : 1.0)
        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
        .task {
            pulse = true
        }
    }
}

// MARK: - Shimmer 高光带（TimelineView 驱动）

/// 骨架占位上叠加的"移动高光带"修饰符。
///
/// 为什么用 `TimelineView(.animation)` 而不是 `.animation(_:value:)`：
/// - shimmer 的"扫光"位置是连续的（每帧一个新值），不是离散 state 翻转；用普通 animation
///   要么写一堆中间 state 一样不雅，要么靠 implicit 动画走，又会被父层 transition 干扰。
/// - `TimelineView(.animation)` 由系统 display link 直接驱动，**完全独立于 SwiftUI 动画系统**。
///   任何外层 transition / animation modifier 都不会停掉它，从根上消除"定格"。
/// - 渲染开销低于全屏 opacity 切换：仅一个 LinearGradient overlay 在 mask 内做平移。
private extension View {
    func shimmer(phaseOffset: Double = 0) -> some View {
        modifier(ShimmerModifier(phaseOffset: phaseOffset))
    }
}

private struct ShimmerModifier: ViewModifier {
    /// 0...1 的相位偏移；同一时刻不同行用不同 offset，形成波浪。
    let phaseOffset: Double

    /// 单次扫光周期（秒）。1.4s 与 macOS 系统 progress shimmer 节奏接近。
    private let period: TimeInterval = 1.4

    func body(content: Content) -> some View {
        content.overlay {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
                // 把当前时间映射到 [0, 1) 周期相位；加 offset 让不同行错峰。
                let t = ctx.date.timeIntervalSinceReferenceDate / period
                let phase = (t + phaseOffset).truncatingRemainder(dividingBy: 1.0)

                // gradient 中心从 -0.3 扫到 1.3，留出进出余量保证高光带平滑划过整个 frame。
                // center 本身可以越界 [0, 1]（视觉上代表"高光带在屏幕外"），
                // 但 SwiftUI 要求 gradient stop locations **必须在 [0, 1] 且单调非降**，
                // 否则会抛 "Gradient stop locations must be ordered." 警告（每帧刷屏）。
                //
                // 解决：三个 stop 的 location 都 clamp 到 [0, 1]。因为
                //   center - 0.25 < center < center + 0.25
                // 本身单调，clamp 是单调操作，clamp 后依然单调（允许相等）。
                // 当 center 越界时，多个 stop 会塌缩到同一边界（0 或 1），
                // 视觉表现是"高光带已完全离开 frame"，正是预期。
                let center = phase * 1.6 - 0.3
                let leftLoc  = min(max(center - 0.25, 0), 1)
                let midLoc   = min(max(center,        0), 1)
                let rightLoc = min(max(center + 0.25, 0), 1)

                LinearGradient(
                    stops: [
                        .init(color: .clear,                  location: leftLoc),
                        .init(color: Color.skeletonHighlight, location: midLoc),
                        .init(color: .clear,                  location: rightLoc)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
        }
        // overlay 必须裁剪到 content 形状，避免高光溢出占位块。
        // content 自己（Circle / RoundedRectangle）已经决定了边界，用 mask 把 overlay 限到 content 形状。
        .mask(content)
    }
}

// MARK: - 骨架专用配色

private extension Color {
    /// 占位块底色：浅色模式偏深灰、深色模式偏浅灰，contrast 适中不刺眼。
    static var skeletonBase: Color {
        Color(nsColor: .quaternaryLabelColor)
    }

    /// shimmer 高光颜色：低饱和高亮，搭配 plusLighter blendMode 在底色上做"扫光"。
    static var skeletonHighlight: Color {
        Color.white.opacity(0.18)
    }
}

// MARK: - 骨架列表视图

/// 骨架屏列表入口，供 RepoListView 在加载中时渲染。
/// 渲染 N 行（默认 8 行）与当前列表密度匹配。
///
/// 行间 `phaseOffset` 按 index 错峰，shimmer 会形成"波浪传递"，避免所有行齐刷刷亮灭。
struct RepoSkeletonListView: View {
    let density: RepoListDensity
    let rowCount: Int

    init(density: RepoListDensity = .card, rowCount: Int = 8) {
        self.density = density
        self.rowCount = rowCount
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { index in
                    // 每行相位错开 0.08 周期，10 行刚好分布在 0.8 个周期内，视觉上呈现传递感。
                    let offset = Double(index) * 0.08
                    RepoRowSkeletonView(density: density, phaseOffset: offset)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)

                    Divider().opacity(0.4)
                }
            }
        }
        // 禁用 ScrollView 自身手势：占位期不需要滚动，避免误触把骨架滚走。
        .scrollDisabled(true)
    }
}
