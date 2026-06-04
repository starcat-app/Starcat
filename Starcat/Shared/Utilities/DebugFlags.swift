//
//  DebugFlags.swift
//  Starcat
//
//  集中管理所有「仅开发期可见」的调试开关。
//
//  设计原则：
//  - 所有开关默认 `false`，Release 包永远关闭（双保险：`#if DEBUG` + UserDefaults）
//  - 不引入新的 Settings UI 表面，避免污染产品；开关通过 Xcode Scheme / LLDB 切换
//  - 单文件集中管理，方便审计"项目里有哪些 debug-only 行为"
//
//  历史：2026-06-02 dong4j 验证三栏 min/ideal/max 宽度时引入，首批承载
//  `LayoutDebugOverlay` 显隐控制。后续如需添加新调试能力（例如打印请求耗时、
//  fake 网络延迟），统一在此文件追加 case。
//

import Foundation

/// 调试开关集合，运行期可读，Release 包永远返回 `false`。
///
/// **底层机制**：所有开关都走 `UserDefaults.standard`。Xcode Scheme 的「Arguments Passed
/// On Launch」中以 `-Key Value` 形式传入的参数，会被 macOS / iOS 在 App 启动早期自动
/// 注册到 UserDefaults（称为 "command-line preferences"），所以**不需要写一行解析代码**。
///
/// 这意味着同一个开关有三种等价切换方式，按场景挑：
///
/// ### A. Xcode Scheme 启动参数（推荐，重启 App 立即生效）
///
/// 1. Xcode 菜单 `Product` → `Scheme` → `Edit Scheme...`（或 `⌘<`）
/// 2. 左侧选 `Run` → 顶部 tab 选 `Arguments`
/// 3. `Arguments Passed On Launch` 区域点 `+`，新增一行：
///
///        -DebugLayoutOverlay YES
///
/// 或按需新增其他 key，例如调试 AI HTTP 响应时：
///
///        -DebugAIHTTPLogging YES
///
/// 4. 关闭弹窗，重新 Run。**注意**：Scheme 设置不会跟着 git 提交（默认 .gitignore
///    `xcuserdata/`），所以是每个开发者自己的本地配置，不污染团队。
///
/// 想关掉就把那行勾选去掉或删除，再重启。
///
/// ### B. LLDB 运行时切换（临时，不需要重启）
///
/// 在 Xcode 调试控制台输入：
///
///     expr UserDefaults.standard.set(true, forKey: "DebugLayoutOverlay")
///
/// 然后让 SwiftUI 重读：拖一下窗口大小、切一下 sidebar 选择，或者直接 `continue`。
/// 这种方式不写入 plist，下次启动会丢失。
///
/// ### C. 命令行 `defaults` 命令（持久化，不依赖 Xcode）
///
///     defaults write com.starcat.app DebugLayoutOverlay -bool YES
///     defaults delete com.starcat.app DebugLayoutOverlay   # 关掉
///
/// 这种方式持久化到 `~/Library/Containers/com.starcat.app/Data/Library/Preferences/com.starcat.app.plist`，
/// 直接编辑那个 plist 文件也是一回事。
enum DebugFlags {

    /// 是否在主窗口右上角显示布局尺寸 overlay（W × H 胶囊）。
    ///
    /// 用途：验证三栏 min/ideal/max 宽度是否真的生效、拖窗口时实时观察各栏宽度变化。
    /// 切换方式见类型文档。
    static var layoutOverlay: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "DebugLayoutOverlay")
        #else
        // Release 包永远关闭，即使有人传了 launch argument 也不开。
        return false
        #endif
    }

    /// 是否打印 OpenAI-compatible chat completion 的 HTTP 原始响应。
    ///
    /// 用途：排查 LM Studio / Ollama / OpenRouter 等 OpenAI-compatible provider
    /// 返回格式与 MacPaw/OpenAI SDK 解码结果不一致的问题。该开关只拦截
    /// `/chat/completions`，不会打印 embedding 向量，避免日志被大数组刷屏。
    static var aiHTTPLogging: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "DebugAIHTTPLogging")
        #else
        // Release 包永远关闭，避免把 AI 原始响应写入用户环境日志。
        return false
        #endif
    }
}
