//
//  AuthHeroCarouselView.swift
//  Starcat
//
//  登录页 hero 区:5 张图片轮播 + 平滑淡入淡出过渡。
//
//  规则(dong4j 2026-06-03 09:55 需求):
//  - 5 张图片(AuthHero1 ~ AuthHero5,@2x 856×400 已在 Assets.xcassets)
//  - 每次打开登录页**随机起始位置**(用户每次看到的不一样)
//  - 自动轮播,过渡平滑(opacity 渐变 1.2s,切换间隔 5s)
//  - sheet 关闭时自动暂停 timer(`onDisappear`)避免后台空跑
//
//  ========================================================================
//  ⚠️ Swift / SwiftUI 关键概念(dong4j 初学者向)
//  ========================================================================
//  - **Image(_:) 从 Asset Catalog 加载**:`Image("AuthHero1")` 会去 .xcassets 找
//    同名 imageset,自动按设备 scale(@1x/@2x/@3x)选最合适的图。
//    本项目 5 张图都只提供了 @2x(macOS 主流场景),@1x/@3x 留空 SwiftUI 会自动缩放兜底。
//    官方搜索词:「SwiftUI Image init(_:)」「Asset Catalog imageset」
//
//  - **ZStack + opacity 切换**:实现"淡入淡出"的标准做法。
//    5 张图同时在 ZStack 里,只显示 opacity=1 的那张,其他 opacity=0。
//    切换时 `withAnimation` 让 opacity 平滑过渡,GPU 合成新旧两张的混合帧,
//    比 SwiftUI 的 `transition()` 修饰器更可控(transition 只在 view 进出时触发)。
//
//  - **@State 在 view 重建时重新初始化**:这就是"每次打开 sheet 随机起始位置"的实现。
//    SwiftUI sheet dismiss 后,内层 view 实例被销毁;再次 present 时新实例被创建,
//    @State 重新走初始化表达式 `Int.random(in: 0..<imageNames.count)`,所以每次起始 index 都不同。
//    官方搜索词:「@State initialization」「SwiftUI sheet lifecycle」
//
//  - **Timer.scheduledTimer + onDisappear cleanup**:
//    Timer 是 RunLoop-based 长生命对象,view 销毁不会自动 release timer,
//    必须在 `onDisappear` 显式 `invalidate()`,否则会泄漏 + 后台空跑耗电。
//    官方搜索词:「Timer scheduledTimer」「RunLoop common modes」
//  ========================================================================
//

import SwiftUI

struct AuthHeroCarouselView: View {

    // MARK: - 数据源

    /// 5 张 hero 图片的 Asset Catalog 名(必须跟 .imageset 目录名一致)。
    private let imageNames: [String] = (1...5).map { "AuthHero\($0)" }

    // MARK: - 状态

    /// 当前显示的图片 index。初始值用 `Int.random` 实现"每次打开随机起始"。
    @State private var currentIndex: Int = Int.random(in: 0..<5)

    /// 轮播 timer。`onDisappear` 时必须 invalidate。
    @State private var timer: Timer?

    // MARK: - 参数(按需调整)

    /// 切换间隔(秒)。dong4j 2026-06-03 10:13 调整:5s → 9s,让用户更从容看完每张图。
    /// 9s = 7s "稳定停留" + 2s 过渡,过渡阶段两张图叠加但仍可辨认主视觉。
    private let switchInterval: TimeInterval = 9.0
    /// 过渡动画时长(秒)。dong4j 2026-06-03 10:13 调整:1.2s → 2.0s,
    /// 配合下方 timingCurve 形成"慢起慢收"的更柔和电影感淡入淡出。
    private let crossfadeDuration: Double = 2.0

    /// 2026-06-15:hero 图片轮播在「关闭应用内动画」时瞬切,
    /// 仍按 `switchInterval` 切换显示但不做 2s 淡入淡出,避免视觉刺激。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        ZStack {
            // 5 张图同时存在,只显示 opacity=1 的那张。
            // GPU 合成开销小;5 张 856×400 解码后内存 ~7MB 完全可接受。
            ForEach(imageNames.indices, id: \.self) { i in
                Image(imageNames[i])
                    .resizable()
                    .scaledToFill()
                    .opacity(i == currentIndex ? 1 : 0)
                    // 自定义 cubic-bezier (0.4, 0.0, 0.2, 1.0) 即 Material "standard easing":
                    // 起步慢 → 中段加速 → 收尾慢,比 .easeInOut 的 sine 曲线更柔和、不"硬"。
                    // 想再丝滑可换 (0.25, 0.1, 0.25, 1.0) 即 CSS "ease" 曲线。
                    .animation(
                        reduceMotion ? nil : .timingCurve(0.4, 0.0, 0.2, 1.0, duration: crossfadeDuration),
                        value: currentIndex
                    )
            }
        }
        .clipped()  // ZStack 默认不裁剪 scaledToFill 溢出部分,加 clipped 防止越界
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    // MARK: - Timer 控制

    private func startTimer() {
        stopTimer()  // 防御:onAppear 可能被多次调用(动画过程 / sheet 重新 present)
        timer = Timer.scheduledTimer(withTimeInterval: switchInterval, repeats: true) { [imageCount = imageNames.count] _ in
            // Swift 6 下 Timer block 视为 @Sendable；显式切回 MainActor 后再写 @State。
            Task { @MainActor in
                currentIndex = (currentIndex + 1) % imageCount
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Hero Carousel(实际尺寸)") {
    AuthHeroCarouselView()
        .frame(width: 428, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(40)
        .background(Color.black.opacity(0.85))
}
#endif
