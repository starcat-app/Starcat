//
//  AnimationOverrideModifier.swift
//  Starcat
//
//  「关闭应用内动画」用户偏好的全局 Environment 注入 modifier。
//
//  ─────────────────────────────────────────────────────────
//  设计动机（2026-06-15）
//  ─────────────────────────────────────────────────────────
//
//  dong4j 在「设置 → 通用 → 无障碍」加了一个「关闭应用内动画」开关，
//  期望关闭后 Starcat 所有自定义动画（hero 切换 / hover 反馈 / 列表行
//  reveal / sidebar disclosure / sheet content transition 等）全部瞬切。
//
//  工程现状（grep 验证）：30+ 个 SwiftUI 视图都已经主动按
//  `reduceMotion`（局部变量名）做兜底——这是为前庭敏感无障碍用户做的，
//  天然就是「我们已经知道怎么关动画」的代码路径。
//
//  ─────────────────────────────────────────────────────────
//  方案：自家 EnvironmentKey + OR 语义注入
//  ─────────────────────────────────────────────────────────
//
//  原本想直接覆写 `\.accessibilityReduceMotion`，但 Apple 把它声明为
//  `var accessibilityReduceMotion: Bool { get }`（read-only KeyPath，
//  不是 WritableKeyPath），用 `.environment(\.accessibilityReduceMotion, ...)`
//  会编译报错 `cannot convert ... to WritableKeyPath`。
//  系统真值由 SwiftUI 自己从 `NSWorkspace.accessibilityDisplayShouldReduceMotion`
//  推下来，开发者无法在 production 通道把它写回（DEBUG 下有
//  `\._accessibilityReduceMotion` 私有 KeyPath，但不允许进 App Store 包）。
//
//  退路是定义自家 `\.starcatReduceMotion`：
//
//      effective = systemReduceMotion || settings.disableAnimations
//      content.environment(\.starcatReduceMotion, effective)
//
//  代价是项目里所有读 `\.accessibilityReduceMotion` 的视图（30+）必须
//  改成读 `\.starcatReduceMotion`——已用脚本一次性 sed 完成，新代码
//  也沿用 `\.starcatReduceMotion`。语义保持一致：true 时关动画。
//
//  这样：
//  • 系统「减少动态效果」开 → effective = true（与历史行为一致）
//  • Starcat 设置「关闭应用内动画」开 → effective = true（新增能力）
//  • 两个都开 → effective = true（OR 语义）
//  • 两个都关 → effective = false（默认动画全开）
//
//  ─────────────────────────────────────────────────────────
//  关键约束（必读）
//  ─────────────────────────────────────────────────────────
//
//  1. **新增动画兜底位点必须读 `\.starcatReduceMotion`**，不要再读
//     `\.accessibilityReduceMotion`，否则 Starcat toggle 不会生效。
//     正例:
//         @Environment(\.starcatReduceMotion) private var reduceMotion
//
//  2. **不影响系统级动画**：sheet 弹出 / 窗口切换 / Picker 下拉 /
//     Form 滚动等由 macOS AppKit 驱动，与 SwiftUI Environment 无关；
//     这些动画即便 toggle ON 也照常播放。`Localizable.xcstrings`
//     里 `settings.general.disableAnimations.help` 文案已写明此约束。
//
//  3. **OR 不是替换**：必须保留 systemReduceMotion，否则
//     "用户在 Starcat 关闭 toggle 但开了系统减少动态效果"会丢失
//     无障碍兜底。
//
//  4. **挂载位置**：主窗口的 `contentRoot` + Settings 窗口的
//     `SettingsView()` 都要挂一次（两个独立的 SwiftUI scene root），
//     已在 `StarcatApp.swift` 完成接线。
//
//  5. **AppSettings 必须先注入**：modifier 通过 `@Environment(AppSettings.self)`
//     读 `disableAnimations`，调用方需保证 `.environment(dependencies.settings)`
//     在 `.starcatAnimationOverride()` 之前——已在 `StarcatApp.swift`
//     按这个顺序挂上。
//

import SwiftUI

// MARK: - 自家 EnvironmentKey

/// Starcat 自家的「应该关动画」环境值。语义同
/// `\.accessibilityReduceMotion`：true 表示子视图应避免大动画。
///
/// 与系统值的区别：把 `AppSettings.disableAnimations` OR 进来。
/// 默认 false（与 SwiftUI 的 `accessibilityReduceMotion` 默认值一致）。
private struct StarcatReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// Starcat 子树内统一读这个键来判断"是否应关动画"。
    /// 由 `AnimationOverrideModifier` 在 root 注入；未挂 modifier
    /// 时退化为 false（动画全开）。
    var starcatReduceMotion: Bool {
        get { self[StarcatReduceMotionKey.self] }
        set { self[StarcatReduceMotionKey.self] = newValue }
    }
}

// MARK: - Modifier

/// 把「关闭应用内动画」用户偏好与系统 reduceMotion 取 OR 后注入到
/// `\.starcatReduceMotion`。
///
/// 子树里所有按 `reduceMotion` 兜底的视图（约 30+ 文件）只要读
/// `@Environment(\.starcatReduceMotion)` 即可同时尊重两套来源。
struct AnimationOverrideModifier: ViewModifier {

    /// 注入用户偏好——`disableAnimations` 改变会触发 SwiftUI 重新计算
    /// effective 并刷新整棵子树的 environment 值。
    @Environment(AppSettings.self) private var settings

    /// 读系统真值（macOS「系统设置 → 辅助功能 → 显示 → 减少动态效果」）。
    /// SwiftUI 自动同步系统切换，无需手动监听 NSWorkspace 通知。
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func body(content: Content) -> some View {
        let effective = systemReduceMotion || settings.disableAnimations
        content.environment(\.starcatReduceMotion, effective)
    }
}

extension View {
    /// 在 root view 上挂一次：让用户「关闭应用内动画」偏好通过
    /// `\.starcatReduceMotion` 环境值的方式自动生效到全工程
    /// 30+ 个 reduceMotion 兜底路径。
    ///
    /// 与系统「减少动态效果」是 OR 语义：任一为真即关动画。
    ///
    /// 使用示例（已在 `StarcatApp.swift` 完成接线，正常情况下不需要再调）：
    /// ```swift
    /// WindowGroup {
    ///     contentRoot
    ///         .environment(dependencies.settings)
    ///         .starcatAnimationOverride()
    /// }
    /// ```
    func starcatAnimationOverride() -> some View {
        modifier(AnimationOverrideModifier())
    }
}
