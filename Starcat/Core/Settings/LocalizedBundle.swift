//
//  LocalizedBundle.swift
//  Starcat
//
//  `Bundle.main` 的 dynamic localization wrapper —— 让 `String(localized:)` /
//  `NSLocalizedString(...)` / 任何走 `Bundle.main.localizedString(forKey:value:table:)`
//  的本地化调用,**跟随 `LocaleStore.shared.selection` 实时切换**。
//
//  ───────────────────────────────────────────────────────────────────────────
//  问题背景（dong4j 2026-06-16 验收发现 root cause #2）
//  ───────────────────────────────────────────────────────────────────────────
//
//  前一批已修复 root cause #1：AppKit 自建 NSWindow（AI 助手浮窗 / 关于窗口）
//  没注入 SwiftUI `\.locale` environment,通过 `appLocaleEnvironment()` modifier
//  解决——SwiftUI `Text("key")` 等通过 environment 查表的 API 已经能跟随设置
//  页 picker 切换。
//
//  但还有 root cause #2：`String(localized: ...)` / `NSLocalizedString(...)` /
//  `Bundle.main.localizedString(forKey:...)` 这三类 API 默认按 `Locale.current`
//  解析,**等价于按系统 locale 解析**,完全不走 SwiftUI environment——所以哪怕
//  设置页切到 English,这些 API 仍然返回中文。
//
//  全工程 50+ 文件、~250 处 callsite 用了 `String(localized:)`(这是必要的——
//  NSWindow.title / NSTextView.placeholder / String(format:_:) / contextMenu /
//  errorDescription 等场景必须返回 String 而非 LocalizedStringKey)。逐个 callsite
//  改写为 `String(localized: key, locale: LocaleStore.shared.selection.effectiveLocale)`
//  风险高、PR 大,而且**未来新代码很容易再次漏写 locale 参数**——架构上不健壮。
//
//  ───────────────────────────────────────────────────────────────────────────
//  本方案：Bundle.main ISA swap
//  ───────────────────────────────────────────────────────────────────────────
//
//  Swift Bundle 是 NSObject 子类,可以**只针对 `Bundle.main` 这个单例实例**
//  做 ISA swap,把它的实际类型从 `Bundle` 改成 `LocalizedBundle`。后续所有
//  走 `Bundle.main.localizedString(...)` 的调用都会进入本类的 override,
//  从而能根据 `LocaleStore.shared.selection` 动态选择对应 .lproj 子目录。
//
//  这是 iOS / macOS 国际化生态的**行业标准做法**(参考 `Localize-Swift` /
//  `BartyCrouch` 等开源库),与官方推荐"用户重启 App 才能切语言"的限制并行
//  存在多年,稳定无坑。Swift 6 strict concurrency 下需要把 wrapper 标 `@unchecked
//  Sendable`,因为 `Bundle.main` 本身是全局单例不归 Sendable 检查管。
//
//  关键约束：
//  1. **只换 `Bundle.main` 单实例 ISA**,不影响 SPM 包的 `Bundle.module` /
//     framework bundle / 用户用 `Bundle(for:)` 自取的 bundle —— 避免污染整个
//     Foundation Bundle 系统;
//  2. `LocaleStore.selection == .system` 时调 super,完全退化为原始行为,
//     兜底安全;
//  3. swizzle 在 App init 早期(`StarcatApp.bootstrap()` 顶部)调用一次,
//     之后的所有本地化查询自然走 override —— 包括 SPM 模块、第三方库的
//     `NSLocalizedString` 调用(只要它们走 `Bundle.main`,不走自己的 bundle);
//  4. UserDefaults `AppLocaleOverride` 是 LocaleStore 的持久化键,这里直接
//     读 UserDefaults 而不是访问 `LocaleStore.shared`(后者是 `@MainActor`,
//     `localizedString(forKey:...)` 可能从任意线程调用,加 `@MainActor` 守卫
//     会破坏 API 兼容性)。`UserDefaults.standard` 是 thread-safe;
//  5. SwiftUI re-render 自动配合：`appLocaleEnvironment()` 已挂 `.id(selection)`,
//     用户切语言时整子树重建,view body 内的 `String(localized:)` 自动重新
//     调用本 override 拿到新 locale 字符串;
//  6. **NSWindow.title 等"一次性赋值"的 String 字段例外**：必须在调用方监听
//     `LocaleStore` 变化主动 `window.title = ...` 重赋值,本 swizzle 不能自动
//     刷新已绘制的 AppKit UI string(它们已经写到 NSWindow / NSToolbar 等
//     state 里,需要触发 set 才会重绘)。详见 `RepoAIWindowController` /
//     `AboutWindowController` 实例。
//
//  ───────────────────────────────────────────────────────────────────────────
//  已知局限
//  ───────────────────────────────────────────────────────────────────────────
//
//  - macOS 顶部 NSMenu(File / Edit / View 等系统菜单)和 dock menu 的字符串
//    在 `NSApplication` 启动早期一次性加载并缓存,本 swizzle 跑得再早也来不及
//    覆盖系统主菜单的本地化(它们走 `NSCocoaXX.lproj`,与 `Bundle.main` 不同
//    路径)。这与 SwiftUI environment 方案的局限完全一致,文档已在 `LocaleStore.swift`
//    顶部说明。
//

import Foundation
import ObjectiveC

/// `Bundle.main` 的 ISA-swapped 替身,根据 `LocaleStore` 选择动态查表。
///
/// 设计为 `final class` + `@unchecked Sendable`：
/// - `final` 关闭进一步派生(本类只用于 swap 单实例 `Bundle.main`,不该被继承);
/// - `@unchecked Sendable` 因为 `Bundle.main` 是全局单例已脱离 Sendable 检查范畴,
///   override 内部只读 `UserDefaults.standard` 是 thread-safe,可以安全跨线程调用。
final class LocalizedBundle: Bundle, @unchecked Sendable {

    /// 把 `Bundle.main` 的 ISA 换成 `LocalizedBundle`。**调用一次即可,幂等**。
    ///
    /// 应在 App init 最早期(`StarcatApp.bootstrap()` 第一行)调用,先于任何
    /// `String(localized:)` / `NSLocalizedString(...)` / SwiftUI Text 解析。
    /// 调晚了不致命(swizzle 后续生效),但调早可以保证启动期所有本地化查询
    /// 都走我们的 override,行为一致性最好。
    static func install() {
        // 幂等防护：避免重复 swap(虽然多次调用也不致命,但会浪费 dispatch
        // 一次,且二次 swap 后 ISA 仍是 LocalizedBundle —— object_setClass
        // 的同类操作 Apple 没明确文档保证幂等,显式 guard 更稳)。
        guard !Bundle.main.isMember(of: LocalizedBundle.self) else { return }
        object_setClass(Bundle.main, LocalizedBundle.self)
    }

    /// `Bundle.main.localizedString(forKey:value:table:)` 的 override。
    ///
    /// 三类 API 都最终走这个方法：
    /// - `String(localized: "key")`         (Foundation macro)
    /// - `NSLocalizedString("key", comment:)` (Cocoa macro,本质 `Bundle.main` 调用)
    /// - 直接 `Bundle.main.localizedString(forKey:value:table:)` (基础 API)
    ///
    /// 流程：
    /// 1. 读 `UserDefaults.standard["AppLocaleOverride"]` —— `LocaleStore` 的持久化键;
    /// 2. 若是 `.system` 或未设置,调 `super` 退化为系统默认行为;
    /// 3. 否则按 selection 取 `<lang>.lproj/Localizable.strings` 子 bundle 查表;
    /// 4. 子 bundle 找不到或 lookup 失败,兜底回 `super`,绝不返回空串。
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        // 注意：直接读 UserDefaults 而不访问 LocaleStore.shared(@MainActor)。
        // localizedString 可能被任意线程调用(SwiftUI 后台 diff / 第三方库)。
        let raw = UserDefaults.standard.string(forKey: "AppLocaleOverride") ?? "system"
        guard raw != "system" else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        // raw 现在是 "en" 或 "zh-Hans"(AppLocale rawValue 严格控制为这两个之一,
        // LocaleStore 的 init 会做 fallback 到 .system 防御异常值)。
        guard let path = Bundle.main.path(forResource: raw, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            // .lproj 子目录不存在(理论不会发生,Xcode 编译 xcstrings 必生成),
            // 兜底走 super 返回系统默认 locale 字符串。
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return bundle.localizedString(forKey: key, value: value, table: tableName)
    }
}
