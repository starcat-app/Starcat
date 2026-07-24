//
//  LocaleStore.swift
//  Starcat
//
//  生产级运行时语言切换状态容器。
//
//  设计要点（与 `DebugLocaleStore` 的关系）：
//  - `DebugLocaleStore` 包在 `#if DEBUG` 里，是给开发者临时调试 i18n 用的菜单入口；
//    本 `LocaleStore` 是给最终用户用的「设置 → 通用 → 语言」入口，**任何模式下都生效**。
//  - 两者的 UserDefaults key 不同（`AppLocaleOverride` vs `DebugLocaleOverride`），
//    所以 release 构建删除 debug 选项不会影响生产持久化。
//  - 在 `StarcatApp` 的 modifier 链中：`localeStore` 先注入（靠根），`debugLocaleStore`
//    后注入（靠子树端）—— SwiftUI environment 链规则下，**后注入的覆盖先注入的**，
//    所以 DEBUG 期间 debug 菜单可以临时覆盖生产配置；关闭 debug override（选回
//    "跟随系统"）就回退到生产 LocaleStore 的选择。
//
//  使用方式：
//  ```
//  @State private var localeStore = LocaleStore.shared
//  // ...
//  ContentView()
//      .environment(\.locale, localeStore.selection.effectiveLocale)
//      .id(localeStore.selection)
//  ```
//
//  ⚠️ 已知局限（与 DebugLocaleStore 一致）：
//  - `.environment(\.locale, _)` 只影响 SwiftUI 视图层 `Text("key")` 等查表行为，
//    macOS 顶部菜单栏（NSMenu）和部分 AppKit 弹窗的字符串走 `Bundle.main.localized*`
//    在 App 启动时一次性加载，**不会**跟随 environment 切换刷新。
//  - 如果用户期望连菜单栏一起切语言，必须额外写入
//    `UserDefaults.standard.set([code], forKey: "AppleLanguages")` 并重启 App。
//    本文件暂未提供这条路径——视图层 i18n 已覆盖 99% 用户面向字符串，剩余的
//    AppKit 菜单项与系统 dialog 等到用户提需求再补。
//

import Foundation
import SwiftUI
import Observation

/// 用户可选的应用显示语言。
///
/// 当前只暴露 App 实际维护翻译的两种语言 + "跟随系统"。新增 ja / ko / fr 等语言时：
/// ① 在此追加 case；② `Localizable.xcstrings` 补对应翻译；③ 视情况追加
/// `displayName` 母语写法（与 macOS Language & Region 系统设置惯例一致）。
enum AppLocale: String, CaseIterable, Identifiable, Sendable {
    /// 跟随系统设置（不强制 locale，等价于不修改 environment）
    case system
    /// 强制英语
    case english = "en"
    /// 强制简体中文
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// 菜单显示文案。
    ///
    /// `english` / `simplifiedChinese` 故意用其原生写法（"English" / "简体中文"），
    /// 与 macOS Language & Region 系统设置列出语言时的惯例一致——这种写法**不**
    /// 应该跟随当前选中语言切换，否则用户切到一个看不懂的语言后会找不到"切回去"的入口。
    ///
    /// `system` 用 i18n key 是有意为之：用户切到任何语言都能看到本语言下的"跟随系统"
    /// 字样，与同 Section 下的"语言"标题、说明文字风格一致；它不存在"看不懂找不到入口"
    /// 风险，因为即便用户误切到日语 / 韩语，"English" / "简体中文" 选项原生显示
    /// 仍然能让用户切回去。
    var displayName: LocalizedStringKey {
        switch self {
        case .system:            return "settings.general.language.system"
        case .english:           return LocalizedStringKey("English")
        case .simplifiedChinese: return LocalizedStringKey("简体中文")
        }
    }

    /// SwiftUI `.environment(\.locale, _)` 实际写入的 Locale 值。
    ///
    /// - `.system` → `Locale.autoupdatingCurrent`：Apple 推荐的"跟随系统变化"sentinel，
    ///   等价于不写 `.environment(\.locale, _)`，但显式写出便于阅读
    /// - 其余 → 用 BCP-47 identifier 构造 Locale
    var effectiveLocale: Locale {
        switch self {
        case .system:            return .autoupdatingCurrent
        case .english:           return Locale(identifier: "en")
        case .simplifiedChinese: return Locale(identifier: "zh-Hans")
        }
    }

    /// 发给 LLM 的输出语言名。
    ///
    /// 这里刻意跟随 Starcat 的 Display Language，而不是 `Locale.current`。`Locale.current`
    /// 代表系统/进程 locale；用户在设置页切换 App 显示语言时，SwiftUI 只会更新
    /// `\.locale` environment，不会改变进程 locale。AI 摘要 / 标签 / 对话必须跟用户在
    /// Starcat 内看到的界面语言一致，否则会出现 UI 已是 English 但 AI 仍输出中文。
    var aiOutputLanguageDescriptor: String {
        Self.aiOutputLanguageDescriptor(for: effectiveLocale)
    }

    /// 把 Locale 映射成 LLM 更稳定理解的英文语言名。
    static func aiOutputLanguageDescriptor(for locale: Locale) -> String {
        let lang = locale.language.languageCode?.identifier ?? "en"
        switch lang {
        case "zh":
            // `zh-Hant` 只有 script、未必带 TW/HK/MO region。只判断 region 会把
            // Starcat 的繁中目标语言错误映射成 Simplified Chinese。
            let script = locale.language.script?.identifier
            let region = locale.language.region?.identifier
            return (script == "Hant" || region == "TW" || region == "HK" || region == "MO")
                ? "Traditional Chinese"
                : "Simplified Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        case "ru": return "Russian"
        case "pt":
            return locale.language.region?.identifier == "BR"
                ? "Brazilian Portuguese"
                : "Portuguese"
        case "it": return "Italian"
        case "nl": return "Dutch"
        case "pl": return "Polish"
        case "uk": return "Ukrainian"
        case "tr": return "Turkish"
        case "vi": return "Vietnamese"
        case "id": return "Indonesian"
        case "ar": return "Arabic"
        default:   return "English"
        }
    }
}

/// 应用语言选择的运行时状态。
///
/// 单例 + `@Observable`：
/// - 单例方便 `StarcatApp` 主 scene 与 Settings scene 共享同一份选择
/// - `@Observable` 让 SwiftUI 在切换时自动重渲染依赖 `\.locale` environment 的视图
///
/// 持久化键 `AppLocaleOverride` 与 `DebugLocaleOverride`（debug 专用）刻意区分，
/// 保证 release 包不会误读 debug 写入的值，反之亦然。
@MainActor
@Observable
final class LocaleStore {

    static let shared = LocaleStore()

    /// 当前选中的应用语言。
    ///
    /// `didSet` 立即写盘——切换语言是低频操作，不需要 debounce；
    /// 写盘失败也不抛错（UserDefaults 本身极少失败），失败时下次启动回落到 `.system`。
    var selection: AppLocale {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: Keys.appLocale)
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Keys.appLocale) ?? AppLocale.system.rawValue
        self.selection = AppLocale(rawValue: raw) ?? .system
    }

    private enum Keys {
        static let appLocale = "AppLocaleOverride"
    }
}

// MARK: - SwiftUI environment helper

/// 把 `LocaleStore.shared` 的当前选择注入子树 `\.locale` environment。
///
/// **为什么需要这道 modifier**：Starcat 有 3 处 SwiftUI 子树**不**在
/// `StarcatApp.WindowGroup` scene tree 里——AI 助手浮窗（`RepoAIWindowController`）、
/// 关于窗口（`AboutWindowController`）等都用 AppKit `NSWindow + NSHostingController`
/// 自建，SwiftUI 的 `.environment(\.locale, _)` 注入只在 scene tree 内传播，**不会**
/// 自动传过来，导致这些独立窗口里的 SwiftUI 子树永远跟随 `Locale.autoupdatingCurrent`
/// 显示系统语言、忽略用户在设置页选的语言。
///
/// 解决方案：在每个 hosting root 显式挂这道 modifier。`@State` 订阅 `@Observable`
/// 单例 `LocaleStore.shared`，用户在设置页改 selection 时这些独立窗口同步刷新。
/// `.id(...)` 与主窗口同款做法，强制重建子树避免缓存了 Locale 的子视图（如
/// `RelativeDateTimeFormatter`）不刷新。
///
/// **重要**（2026-06-16 dong4j 实测修订老版注释）：
///
/// 不只是 AppKit 独立 NSWindow —— **SwiftUI `.sheet` / `.popover` 在 macOS 上的
/// host window 也不会自动从父 scene 继承 `\.locale` environment**（实测分享卡
/// sheet 子树查到的 locale 是 `Locale.autoupdatingCurrent` = 系统语言,无视主
/// scene 注入的 LocaleStore）。**所有 sheet / popover 的根 view 都必须显式挂
/// 这道 modifier**,否则切到 English 时 sheet 内的 `Text("key")` 仍显示中文。
///
/// 老版注释假设"sheet/popover 在 scene tree 内自动继承 `\.locale`",该假设
/// 已被打脸 —— 可能是 SwiftUI 在 macOS 上把 sheet/popover 实现为独立 hosting
/// window 的代价(与 iOS 行为不一致)。
///
/// 调用清单（每新增一个 sheet/popover/AppKit NSWindow 都要登记）：
/// - `RepoAIWindowController`（AppKit NSWindow）
/// - `AboutWindowController`（AppKit NSWindow）
/// - `ShareCardSheet`（SwiftUI sheet,2026-06-16 补挂）
/// - 新增的 sheet / popover：在根 view body 最外层挂一次
private struct AppLocaleEnvironmentModifier: ViewModifier {

    @State private var localeStore = LocaleStore.shared

    func body(content: Content) -> some View {
        content
            .environment(\.locale, localeStore.selection.effectiveLocale)
            .id(localeStore.selection.rawValue)
    }
}

extension View {

    /// 订阅 `LocaleStore.shared` 并把当前选择注入子树 `\.locale` environment。
    ///
    /// 仅用于 AppKit 自建的独立 NSWindow / NSPanel hosting root。普通 SwiftUI
    /// scene 内的 view（含 sheet / popover）已自动继承 `StarcatApp` 注入的 locale，
    /// 不需要重复挂这道 modifier。
    func appLocaleEnvironment() -> some View {
        modifier(AppLocaleEnvironmentModifier())
    }
}
