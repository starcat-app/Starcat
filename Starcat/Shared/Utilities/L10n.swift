//
//  L10n.swift
//  Starcat
//
//  LocaleStore-aware 本地化查表 wrapper —— 替代 `String(localized:)` 让结果跟随用户在
//  「设置 → 通用 → 语言」选的语言,而不是按系统 locale。
//
//  ───────────────────────────────────────────────────────────────────────────
//  问题背景（dong4j 2026-06-16 实测确认）
//  ───────────────────────────────────────────────────────────────────────────
//
//  Foundation `String(localized: key, locale: someLocale)` 的 `locale` 参数**仅用于
//  格式化 plural / number / date**,**不**用于选 lproj 子目录。选 lproj 走的是
//  `Bundle.main.preferredLocalizations`(由 macOS 系统语言决定),用户在设置页选的
//  `LocaleStore.selection` 完全失效。
//
//  实测验证(`Starcat/Features/Profile/ContributionGraphView.swift` 调试 callsite):
//
//  ```swift
//  // 三个写法在系统中文 + LocaleStore 选 English 时全部返回中文:
//  String(localized: "contribution.totalCount")                                  // 默认 .current
//  String(localized: "contribution.totalCount", locale: envLocale)               // \.locale environment
//  String(localized: "contribution.totalCount", locale: Locale(identifier: "en")) // 硬编码英文也无效
//  ```
//
//  之前尝试的 `LocalizedBundle.swift` ISA swap 也对 `String(localized:)` 无效——
//  Swift Foundation 内部不走 `Bundle.main.localizedString(forKey:value:table:)` 的
//  ObjC 方法分派,swap 拦不到。已加诊断 log 验证一条都没打。
//
//  ───────────────────────────────────────────────────────────────────────────
//  本方案
//  ───────────────────────────────────────────────────────────────────────────
//
//  **完全绕开** `String(localized:)`,直接按 `AppLocaleOverride`(LocaleStore 持久化键)
//  选 lproj 子 bundle,从子 bundle 调 `localizedString(forKey:value:table:)` 拿翻译。
//
//  这就是 `LocalizedBundle.localizedString` 内部已经写好的逻辑,但因为入口 API 不调
//  Bundle.main 方法分派,swap 没机会执行——这里改成"调用方主动走子 bundle 路径"。
//
//  使用方式:
//
//  ```swift
//  // 替换原本的 String(localized: "key"):
//  Text(String(format: String.l10n("contribution.totalCount"), count))
//
//  // 替换 NSWindow.title / errorDescription / contextMenu 等需要 String 的场景:
//  window.title = String(format: String.l10n("ai.assistant.window.titleFormat"), repo.fullName)
//  ```
//
//  关键约束:
//  1. **直接读 UserDefaults**,不访问 `LocaleStore.shared`(后者 `@MainActor`)。
//     `localizedString` 调用方可能在任意线程,加 `@MainActor` 守卫会破坏 API 兼容性。
//     `UserDefaults.standard` 自身 thread-safe;
//  2. **不接受 `locale:` 参数**——刻意如此。`l10n(_:)` 的语义就是"按 LocaleStore 当前
//     选择查表",外部不该重载 locale。需要按特定 locale 渲染时(如分享卡导出)直接用
//     原生 `String(localized: key, locale: <explicit>)` —— 但要清楚 locale 参数只
//     影响 plural/number/date 格式化,不影响选 lproj;
//  3. **plural / 复杂格式不走本 wrapper**——`%lld` 这种 printf 占位符是 `String(format:_:)`
//     的事,本 wrapper 只负责"按当前语言查到模板字符串";真复杂的 plural rules 应该用
//     SwiftUI `Text("key \(count)")` 让 SwiftUI 自己处理(但需要改 xcstrings key 风格,
//     是后续重构议题);
//  4. **找不到子 bundle 时兜底走 super**:.lproj 不存在(理论 Xcode 编译 xcstrings 必生成,
//     但防御性兜底)/ system 模式都退化为 `Bundle.main.localizedString(...)` —— 这一路径
//     仍然会被 LocalizedBundle ISA swap 拦截(这是 swap 仍然有意义的场景)。
//
//  ───────────────────────────────────────────────────────────────────────────
//  迁移路线（dong4j 2026-06-16 拍板)
//  ───────────────────────────────────────────────────────────────────────────
//
//  - 第一步(本次):wrapper 落地 + sidebar autoTidyFooter / contribution.totalCount
//    两处先验证生效;
//  - 第二步:全工程 80+ 文件 ~250 处 `String(localized: "key")` 批量迁移到
//    `String.l10n("key")`(单独 PR);
//  - 第三步:清理 `LocalizedBundle` 顶部"覆盖 String(localized:)"的过时注释,
//    保留 ISA swap 作为 NSLocalizedString / 第三方库直调 Bundle.main 的兜底。
//

import Foundation

extension String {

    /// LocaleStore-aware 本地化查表,替代 `String(localized:)` 让结果跟随
    /// `LocaleStore.shared.selection`(用户在「设置 → 通用 → 语言」的选择),
    /// 而非按系统 locale。
    ///
    /// 详细原理与使用约束见本文件顶部注释。
    ///
    /// - Parameter key: String Catalog (`Localizable.xcstrings`) 中的 key,如
    ///   `"contribution.totalCount"`。约定全工程使用 `<section>.<subsection>.<component>`
    ///   命名风格(`.` 分隔)。
    /// - Returns: 当前 LocaleStore 选择对应 lproj 中的翻译字符串;找不到则兜底走
    ///   `Bundle.main.localizedString(...)`(即 LocalizedBundle ISA swap 路径)。
    static func l10n(_ key: String) -> String {
        let raw = UserDefaults.standard.string(forKey: "AppLocaleOverride") ?? "system"

        // system 模式:不强制 locale,走 Bundle.main 默认查表(可能被 LocalizedBundle
        // ISA swap 拦到 → 但 swap 在 .system 分支也是直接 super,所以等价于系统行为)。
        guard raw != "system" else {
            return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        }

        // raw 由 AppLocale rawValue 严格控制为 "en" / "zh-Hans"。
        // 找不到 .lproj 子目录(理论上 Xcode 编译 xcstrings 必生成,这里是防御性兜底)
        // 或加载子 bundle 失败 → 退化为 Bundle.main 的默认查表行为。
        guard let path = Bundle.main.path(forResource: raw, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
