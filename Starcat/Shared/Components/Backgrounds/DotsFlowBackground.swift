//
//  DotsFlowBackground.swift
//  Starcat
//
//  从 ShipSwift（`refer/ShipSwift/ShipSwift/SWPackage/SWAnimation/SWMetal/SWDots.swift`）
//  移植，**仅保留 `.flow` 平面网格样式**，作为页面 / sheet 装饰背景使用。
//  配套 Metal stitchable shader 在同目录的 `DotsFlowBackground.metal`，函数名
//  保持原 `swDotsFlow`，因为 `ShaderLibrary.default` 是按函数名查找的——
//  Swift 端类型名可改，但 Metal 端导出符号一旦改了 Swift 端就找不到。
//
//  **为什么放在 Shared/Components/Backgrounds/**：
//      Metal shader 背景是跨 feature 可复用的视觉装饰，等级与 `ToastOverlay` /
//      `RemoteAvatar` 同。首批调用方是 `ShareCardSheet`，后续可能扩展到其它
//      sheet / onboarding / paywall。新建 `Backgrounds/` 子目录是因为
//      Metal 组件天然是 .swift + .metal 文件对，扁平放在 Shared/Components/ 会乱。
//
//  **相对 ShipSwift 原版精简了什么**：
//      - 7 种 style 只保留 `.flow`（其余 6 个需要再移植对应 .metal）
//      - 删去 `showsControls` 调参 sheet 路径（demo only：`SWDotsControlled` /
//        `SWDotsControlsSheet` / `SliderRow` 共 ~150 行）
//      - 删去 iOS-only 分支（项目 macOS-only，少一层 `#if os(iOS)`）
//      - **`background` 保持 ShipSwift 原默认 `.black`**（曾经尝试改 `.clear`
//        以为是更安全的"页面背景默认"，实测踩坑——见下方第 3 条约束）
//
//  **关键约束 / 已踩过的坑**：
//      1. **最低 macOS 14**：依赖 SwiftUI `ShaderLibrary` / `Shader` /
//         Metal `[[ stitchable ]]`。Starcat 部署 macOS 15.0（project.yml）满足。
//      2. **.metal 文件必须进 Compile Sources**：xcodegen 默认按 `sources: Starcat`
//         扫所有文件，所以新增后 **必须 `xcodegen generate`** 重生 .xcodeproj，
//         否则 `default.metallib` 里没有 `swDotsFlow` 符号，运行时 `colorEffect`
//         会**静默无效**（不抛错、不打日志、就是看不到效果）——历史踩坑首位。
//      3. **`background` 必须传不透明色（默认 `.black`），不要传 `.clear`**：
//         内部走 `background.colorEffect(Shader)`，**SwiftUI `.colorEffect` 要求
//         source view 有像素才会触发 fragment shader 调用**——`Color.clear`
//         在 SwiftUI 里被优化为"不绘制"，shader 根本不会被调用，结果是整片
//         什么都看不到（**dong4j 2026-06-06 实测踩坑、灯下黑半小时**）。
//         **做"半透明叠加"的正确做法：传不透明色（如 `.black`），然后调用方
//         在外面套 `.blendMode(.plusLighter)` 或 `.blendMode(.screen)`**——
//         黑色部分会"加 0 = 不变"自动消失，只留亮点叠加到底层 material 上。
//      4. **持续渲染限频**：内部 Timeline 固定最高 30 FPS，不跟随
//         60/120 Hz 屏幕刷新率盲目重画；`starcatReduceMotion` 开启时彻底
//         移除 Timeline，只渲染时间 0 的静态帧。**别叠多个实例**。
//      5. **ImageRenderer 截不出 Metal shader 帧**：SwiftUI snapshot 不渲染 GPU
//         shader。所以这个组件**不要**放进 `ShareCardContent` 期望"出现在导出图
//         里"；它只能作为 sheet / view 的 **运行时装饰**。
//
//  Usage（"亮点叠加在 sheet 原 material 上"标准做法）：
//      VStack { ... }
//          .frame(width: 480, height: 820)
//          .background {
//              DotsFlowBackground(
//                  tint: .accentColor,
//                  background: .black,  // 不能传 .clear，见约束 3
//                  speed: 0.35,
//                  brightness: 0.9,
//                  vignette: 0.0
//              )
//              .blendMode(.plusLighter)  // 黑底消失，只留亮点叠加到底层
//          }
//
//  Usage（"独立全屏装饰"）：
//      DotsFlowBackground(tint: .accentColor, background: .black)
//          .ignoresSafeArea()
//

import SwiftUI

/// 平面网格 flow 样式 Metal 背景，可作为 sheet / 页面装饰背景。
///
/// 调用方负责限定大小（通常通过 `.background { ... }` 让其撑满宿主 view 的 bounds），
/// 本组件不主动 `ignoresSafeArea`，避免在 sheet 这种"模态无 safe area"语境下做无用功。
struct DotsFlowBackground: View {

    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// 点和高光的颜色。
    /// 做 sheet 背景时建议用 `.accentColor` 或品牌色（暗亮模式都能识别），
    /// 纯白 / 纯黑 在对应模式下会几乎看不见。
    var tint: Color = .accentColor

    /// 底色。**必须传不透明色，默认 `.black`**——见文件头第 3 条约束
    /// （SwiftUI `.colorEffect` 对 `Color.clear` 不触发 shader，会整片不可见）。
    /// 做半透明叠加请保持不透明底 + 外层 `.blendMode(.plusLighter)`。
    var background: Color = .black

    /// 时间倍率。默认 1.0；做背景时 0.3–0.5 更舒服（太快抢前景注意力）。
    var speed: Float = 1.0

    /// 整体亮度倍率。默认 1.0；做背景配 `opacity(0.4)` 时此值可保 0.6-0.8 保留对比。
    var brightness: Float = 1.0

    /// 点直径倍率。默认 1.0。
    var dotSize: Float = 1.0

    /// 网格密度倍率。默认 1.0；越大点越密。
    var gridDensity: Float = 1.0

    /// 空间频率倍率。默认 1.0；控制 flow 纹路的疏密。
    var patternScale: Float = 1.0

    /// 四角晕影强度。默认 1.0；做 sheet 背景建议 0.0 关掉（sheet 自身有边界，
    /// 再叠 vignette 会显得画面"塌"在中间）。
    var vignette: Float = 1.0

    /// shader 时间起点。`TimelineView` 每帧用 `Date().timeIntervalSince(start)`
    /// 喂给 shader 做 wave 动画。
    @State private var start: Date = .now

    var body: some View {
        Group {
            if reduceMotion {
                renderedFrame(elapsed: 0)
            } else {
                // Metal 背景旧实现跟随屏幕 60/120 FPS 重绘。点阵流速很慢，
                // 30 FPS 视觉等价，但可将 sheet 开启时的 shader 调用量至少减半。
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    renderedFrame(elapsed: Float(context.date.timeIntervalSince(start)))
                }
            }
        }
    }

    private func renderedFrame(elapsed: Float) -> some View {
        background
            .colorEffect(
                Shader(
                    function: ShaderFunction(library: .default, name: "swDotsFlow"),
                    arguments: [
                        .boundingRect,
                        .float(elapsed),
                        .float(speed),
                        .float(brightness),
                        .color(tint),
                        .color(background),
                        .float(dotSize),
                        .float(gridDensity),
                        .float(patternScale),
                        .float(vignette),
                        // horizon / amplitude / depthFade 在 .flow 样式下被
                        // shader 端 `(void)x;` 显式忽略，但 stitchable 函数
                        // 签名固定 13 参，必须传齐——传 0 即可。
                        .float(0),
                        .float(0),
                        .float(0)
                    ]
                )
            )
    }
}

// MARK: - Preview

#Preview("Flow on solid (full-screen decor)") {
    ZStack {
        DotsFlowBackground(
            tint: .accentColor,
            background: .black,
            speed: 0.4,
            brightness: 1.0,
            vignette: 0.0
        )
        Text("DotsFlowBackground")
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(.white)
    }
    .frame(width: 480, height: 820)
}

#Preview("Flow over sheet material (additive overlay)") {
    VStack(spacing: 16) {
        Text("分享卡片")
            .font(.headline)
        RoundedRectangle(cornerRadius: 12)
            .fill(.background)
            .frame(width: 400, height: 560)
            .overlay(Text("Card preview").foregroundStyle(.secondary))
        Spacer()
    }
    .frame(width: 480, height: 820)
    .background {
        DotsFlowBackground(
            tint: .accentColor,
            background: .black,
            speed: 0.35,
            brightness: 0.9,
            vignette: 0.0
        )
        .blendMode(.plusLighter)
    }
}
