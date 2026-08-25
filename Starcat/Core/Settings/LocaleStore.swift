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
/// 暴露 App 实际维护的 18 种语言 + “跟随系统”。语言 identifier 必须与
/// `supports/starcat-localization/locales.json` 保持一致，避免设置项、Catalog
/// 和 AI 输出语言三者发生漂移。
enum AppLocale: String, CaseIterable, Identifiable, Sendable {
    /// 跟随系统设置（不强制 locale，等价于不修改 environment）
    case system
    /// 强制英语
    case english = "en"
    /// 强制简体中文
    case simplifiedChinese = "zh-Hans"
    /// 强制繁体中文
    case traditionalChinese = "zh-Hant"
    /// 强制日语
    case japanese = "ja"
    /// 强制韩语
    case korean = "ko"
    /// 强制德语
    case german = "de"
    /// 强制法语
    case french = "fr"
    /// 强制西班牙语
    case spanish = "es"
    /// 强制巴西葡萄牙语
    case brazilianPortuguese = "pt-BR"
    /// 强制意大利语
    case italian = "it"
    /// 强制俄语
    case russian = "ru"
    /// 强制荷兰语
    case dutch = "nl"
    /// 强制波兰语
    case polish = "pl"
    /// 强制乌克兰语
    case ukrainian = "uk"
    /// 强制土耳其语
    case turkish = "tr"
    /// 强制越南语
    case vietnamese = "vi"
    /// 强制印度尼西亚语
    case indonesian = "id"
    /// 强制阿拉伯语
    case arabic = "ar"

    var id: String { rawValue }

    /// 菜单显示文案。
    ///
    /// 每种语言故意使用母语写法，与 macOS Language & Region 系统设置列出语言时
    /// 的惯例一致。这些名字不应跟随当前选中语言切换，否则用户切到一个看不懂的
    /// 语言后可能找不到“切回去”的入口。
    ///
    /// `system` 用 i18n key 是有意为之：用户切到任何语言都能看到本语言下的"跟随系统"
    /// 字样，与同 Section 下的"语言"标题、说明文字风格一致；它不存在"看不懂找不到入口"
    /// 风险，因为语言选项始终保留各自的母语名称。
    ///
    /// 菜单展示请用 `menuTitle`：跟随系统用 🌐 与各国旗同一列，但文案仍走本 key，
    /// 不能把地球写进 Catalog，否则 18 种语言都要改 `Localizable.xcstrings`。
    var displayName: LocalizedStringKey {
        switch self {
        case .system:              return "settings.general.language.system"
        case .english:             return LocalizedStringKey("🇺🇸 English")
        case .simplifiedChinese:   return LocalizedStringKey("🇨🇳 简体中文")
        case .traditionalChinese:  return LocalizedStringKey("🇨🇳 繁體中文")
        case .japanese:            return LocalizedStringKey("🇯🇵 日本語")
        case .korean:              return LocalizedStringKey("🇰🇷 한국어")
        case .german:              return LocalizedStringKey("🇩🇪 Deutsch")
        case .french:              return LocalizedStringKey("🇫🇷 Français")
        case .spanish:             return LocalizedStringKey("🇪🇸 Español")
        case .brazilianPortuguese: return LocalizedStringKey("🇧🇷 Português (Brasil)")
        case .italian:             return LocalizedStringKey("🇮🇹 Italiano")
        case .russian:             return LocalizedStringKey("🇷🇺 Русский")
        case .dutch:               return LocalizedStringKey("🇳🇱 Nederlands")
        case .polish:              return LocalizedStringKey("🇵🇱 Polski")
        case .ukrainian:           return LocalizedStringKey("🇺🇦 Українська")
        case .turkish:             return LocalizedStringKey("🇹🇷 Türkçe")
        case .vietnamese:          return LocalizedStringKey("🇻🇳 Tiếng Việt")
        case .indonesian:          return LocalizedStringKey("🇮🇩 Bahasa Indonesia")
        case .arabic:              return LocalizedStringKey("🇸🇦 العربية")
        }
    }

    /// 设置页语言菜单的一行。
    ///
    /// 具体语言已经把国旗写进 `displayName`；跟随系统没有对应国家，用地球 emoji
    /// 占同一列，避免菜单第一项左边空一格。文案继续走 SwiftUI 查表，这样切界面
    /// 语言后「跟随系统」仍会本地化（`String.l10n` 走 Bundle，跟不上 in-app locale）。
    var menuTitle: Text {
        if self == .system {
            return Text("🌐 ") + Text(displayName)
        }
        return Text(displayName)
    }

    /// SwiftUI `.environment(\.locale, _)` 实际写入的 Locale 值。
    ///
    /// - `.system` → `Locale.autoupdatingCurrent`：Apple 推荐的"跟随系统变化"sentinel，
    ///   等价于不写 `.environment(\.locale, _)`，但显式写出便于阅读
    /// - 其余 → 用 BCP-47 identifier 构造 Locale
    var effectiveLocale: Locale {
        if self == .system {
            return .autoupdatingCurrent
        }
        // 非 system case 的 rawValue 全部是 locales.json 中的 BCP-47 identifier，
        // 保持二者一致可避免 Catalog、设置选项和 AI 输出语言发生漂移。
        return Locale(identifier: rawValue)
    }

    /// SwiftUI 子树使用的书写方向。
    ///
    /// 仅注入 `\.locale` 不足以保证应用内运行时切换为 Arabic 后整棵视图树立即
    /// 镜像；显式同步 `\.layoutDirection`，让主窗口、sheet、popover 和 AppKit
    /// hosting window 走同一条 RTL 路径。`.system` 仍依据系统当前语言判断。
    var effectiveLayoutDirection: LayoutDirection {
        effectiveLocale.language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
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

/// 把 `LocaleStore.shared` 的当前选择注入子树的 locale 与书写方向 environment。
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
            .environment(\.layoutDirection, localeStore.selection.effectiveLayoutDirection)
            .id(localeStore.selection.rawValue)
    }
}

extension View {

    /// 订阅 `LocaleStore.shared` 并把当前 locale 与书写方向注入子树。
    ///
    /// 用于 AppKit 自建的独立 NSWindow / NSPanel hosting root，以及 macOS 上不会
    /// 稳定继承父 scene locale / layoutDirection 的 sheet、popover 根视图。
    func appLocaleEnvironment() -> some View {
        modifier(AppLocaleEnvironmentModifier())
    }
}
