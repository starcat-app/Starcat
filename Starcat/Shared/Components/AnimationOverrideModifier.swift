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
//  4. **挂载位置**：每个独立 SwiftUI root 都必须挂一次。除主窗口和
//     Settings scene 外，AppKit 手动创建的 AI / About hosting controller
//     也必须注入，否则设置开关无法穿透到这些独立 view tree。
//
//  5. **AppSettings 必须先注入**：modifier 通过 `@Environment(AppSettings.self)`
//     读 `disableAnimations`，调用方需保证 `.environment(dependencies.settings)`
//     在 `.starcatAnimationOverride()` 之前——已在 `StarcatApp.swift`
//     按这个顺序挂上。
//
//  6. **关闭动画是双层保障**：视图仍应读取 `starcatReduceMotion`，在关闭时
//     不创建 TimelineView / shader 等持续刷新源；root transaction 负责兜住
//     遗漏的 implicit animation、`withAnimation` 和 symbol transition。
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

/// 暂停仅用于装饰的持续刷新源，例如 `TimelineView` / Canvas 动画。
///
/// 它与 reduce motion 的语义不同：后者是用户无障碍偏好；这里是宿主在 Sheet
/// 转场等高优先级交互期间临时让出主线程和渲染预算。默认不暂停，只有明确知道
/// 自己覆盖着持续动画的宿主才注入 true。
private struct StarcatContinuousAnimationsPausedKey: EnvironmentKey {
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

    /// 是否临时暂停装饰性持续动画。暂停时视图应切到静态分支，而不是只把 opacity 设为 0；
    /// 后者仍会保留 display-link 并持续触发 SwiftUI 更新。
    var starcatContinuousAnimationsPaused: Bool {
        get { self[StarcatContinuousAnimationsPausedKey.self] }
        set { self[StarcatContinuousAnimationsPausedKey.self] = newValue }
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
        content
            .environment(\.starcatReduceMotion, effective)
            // Environment 值用于让持续动画改走静态分支；transaction
            // 则是全局兜底，会截断遗漏的隐式动画、withAnimation 和
            // SF Symbol content transition。两者缺一不可：单纯禁用
            // transaction 无法停止 TimelineView/display-link，单纯 Environment
            // 又要求每个后续调用点都永不遗漏。
            .transaction { transaction in
                guard effective else { return }
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
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
