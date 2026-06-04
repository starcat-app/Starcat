//
//  DebugLocaleStore.swift
//  Starcat
//
//  DEBUG 模式专用：运行时语言切换的状态容器（用于测试 i18n 是否正确覆盖所有用户面向字符串）。
//
//  设计要点：
//  - 整文件包在 `#if DEBUG`，Release 包不参与编译，零成本、零风险泄漏到生产
//  - 用 `@Observable` 让 SwiftUI 视图自动响应切换；选中项持久化到 UserDefaults，
//    重启 App 后保留上次选中的调试语言，避免每次启动都要重设
//  - 切换到 "system" 时使用 `Locale.autoupdatingCurrent`，这是 Apple 推荐的
//    "不强制 locale、跟随系统设置变化"的 sentinel 值
//
//  使用方式（StarcatApp 里）：
//  ```
//  #if DEBUG
//  @State private var debugLocaleStore = DebugLocaleStore.shared
//  // ...
//  .environment(\.locale, debugLocaleStore.selection.effectiveLocale)
//  // 在 .commands 内追加 DebugMenuCommands(store: debugLocaleStore)
//  #endif
//  ```
//
//  ⚠️ 已知局限（写给未来的协作者）：
//  - `.environment(\.locale, _)` 只影响 SwiftUI 视图层的 `Text("key")` 等查表行为；
//    macOS 顶部菜单栏（NSMenu）和部分 AppKit 弹窗的字符串走 `Bundle.main.localized*`
//    在 App 启动时一次性加载，**不会**跟随 environment 切换刷新。
//  - 想要"连菜单栏一起切语言"，必须在切换时写入 `UserDefaults.standard.set([code], forKey: "AppleLanguages")`
//    并提示用户重启 App。本文件暂未提供这条路径——一次性测试视图层 i18n 已经够用，
//    需要时再补 `restartWithLanguage(_:)` 方法。
//

#if DEBUG

import Foundation
import SwiftUI
import Observation

/// 调试语言枚举。
///
/// 当前仅支持 App 实际维护的两种语言 + "跟随系统"。
/// 未来新增 ja / ko / fr 时，在此追加 case + 同步更新 `Localizable.xcstrings`。
enum DebugLocale: String, CaseIterable, Identifiable {
    /// 跟随系统设置（不强制 locale，等价于不修改 environment）
    case system
    /// 强制英语
    case english = "en"
    /// 强制简体中文
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// 菜单显示名。
    ///
    /// 故意用 `verbatim` 不走本地化——调试菜单本身不应该跟随当前选中语言切换，
    /// 否则用户切到一个看不懂的语言后会找不到"切回去"的入口。
    /// "简体中文"用其原生写法、"English"亦然，符合 macOS "Language & Region" 系统设置
    /// 列出语言时的惯例。
    var displayName: String {
        switch self {
        case .system:            return "System (跟随系统)"
        case .english:           return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    /// SwiftUI `.environment(\.locale, _)` 实际写入的 Locale 值。
    ///
    /// - `.system` → `Locale.autoupdatingCurrent`：Apple 推荐的"跟随系统变化"sentinel；
    ///   等价于不写 `.environment(\.locale, _)`，但显式写出便于阅读
    /// - 其余 → 用 BCP-47 identifier 构造 Locale
    var effectiveLocale: Locale {
        switch self {
        case .system:            return .autoupdatingCurrent
        case .english:           return Locale(identifier: "en")
        case .simplifiedChinese: return Locale(identifier: "zh-Hans")
        }
    }
}

/// 调试语言选择的运行时状态。
///
/// 单例 + `@Observable`：单例方便 StarcatApp 持有同时 ContentView 任意子视图也能
/// 直接读（虽然当前只在 StarcatApp 写、Picker 在 .commands 里读）；@Observable
/// 让 environment locale 改变时 SwiftUI 自动重渲染。
///
/// 持久化键 `DebugLocaleOverride` 与 `DebugFlags` 用的 `Debug*` 命名约定保持一致，
/// 便于 `defaults read com.starcat.app` 时一眼看到所有调试相关键。
@MainActor
@Observable
final class DebugLocaleStore {

    static let shared = DebugLocaleStore()

    /// 当前选中的调试语言。
    ///
    /// `didSet` 立即写盘——切换语言是低频操作，不需要 debounce；
    /// 写盘失败也不抛错（UserDefaults 本身极少失败），失败时下次启动回落到 `.system`。
    var selection: DebugLocale {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: Keys.debugLocale)
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Keys.debugLocale) ?? DebugLocale.system.rawValue
        self.selection = DebugLocale(rawValue: raw) ?? .system
    }

    private enum Keys {
        static let debugLocale = "DebugLocaleOverride"
    }
}

#endif
