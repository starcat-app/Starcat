//
//  StarcatApp.swift
//  Starcat
//
//  @main 入口。
//
//  启动期职责：
//  1. 触发 DatabaseManager 单例初始化（含 Migration）
//  2. 跑 KeychainManager 自检
//  3. 构造 AppDependencies（API / OAuth / AuthSession / SyncManager）
//  4. 尝试从 Keychain 恢复登录态
//

import SwiftUI

@main
struct StarcatApp: App {

    /// 应用级依赖容器，必须在 init 中创建并通过 environment 传给 ContentView。
    @State private var dependencies: AppDependencies

    init() {
        Self.bootstrap()
        // 注意：AppDependencies 是 @MainActor，App init 已在 main thread
        _dependencies = State(initialValue: AppDependencies())
    }

    var body: some Scene {
        WindowGroup("Starcat") {
            ContentView()
                .environment(dependencies)
                .environment(dependencies.authSession)
                .environment(dependencies.syncManager)
                .environment(dependencies.settings)
                // W4-5 D1：用户主题偏好应用到主窗口。
                // dependencies / settings 都是 @Observable，appearanceMode 变化
                // 会自动触发本 scene body 重新计算 → preferredColorScheme 即时切换。
                .preferredColorScheme(dependencies.settings.appearanceMode.colorScheme)
                // W4-5 D1 follow-up：隐式动画兜底。SettingsView 的 Picker 已经在 setter
                // 里包了 `withAnimation(.easeInOut(0.3))`，但如果以后从其他入口（菜单 /
                // 快捷键 / URL scheme）切主题，那条路径不会带 transaction，这里挂一道
                // `.animation(_:value:)` 让 colorScheme 相关的视图重渲染都自动 0.3s 淡变。
                //
                // 注意：macOS NSWindow titlebar / chrome 由 AppKit 即时切换，SwiftUI
                // 动画系统覆盖不到，所以 titlebar 仍是瞬切；视图内容区（动态色 / 材质 /
                // 文字色）会跟随过渡。这是系统级约束，不可避免。
                .animation(.easeInOut(duration: 0.3), value: dependencies.settings.appearanceMode)
                .task {
                    await dependencies.authSession.restoreSessionIfAvailable()
                }
        }
        .commands {
            // 替换系统默认的"关于 Starcat"菜单项，打开自定义 SwiftUI 关于窗口。
            CommandGroup(replacing: .appInfo) {
                Button("app.about") {
                    AboutPanelController.show()
                }
                .keyboardShortcut("I", modifiers: .command)
            }
        }

        // macOS 原生 Settings 窗口（Cmd+,）
        Settings {
            SettingsView()
                .environment(dependencies)        // W4-4 D4：StorageSettingsTab 需要 readmeRepository
                .environment(dependencies.settings)
                // W4-5 D1：Settings 窗口也要同步主题，否则用户切了主题后
                // Settings 窗口跟主窗口主题不一致，会非常诡异。
                .preferredColorScheme(dependencies.settings.appearanceMode.colorScheme)
                // W4-5 D1 follow-up：Settings 窗口本身的内容区也带过渡，
                // 跟主窗口节奏一致（0.3s easeInOut），避免出现"主窗口在淡变、
                // Settings 窗口瞬切"的视觉撕裂。
                .animation(.easeInOut(duration: 0.3), value: dependencies.settings.appearanceMode)
        }
    }

    // MARK: - Bootstrap

    private static func bootstrap() {
        AppLog.general.info("Starcat starting (bundle=\(AppConstants.bundleIdentifier, privacy: .public))")
        DatabaseManager.bootstrap()

        // 测试期跳过 Keychain 自检：ad-hoc 签名 + ACL 不匹配会触发 GUI 授权弹窗，
        // 测试 host 主线程被对话框阻塞 → testmanagerd 永远连不上 App。
        // 详见 docs/工程进度/2026-05-30-Keychain-临时绕过方案.md
        if TestEnvironment.isRunning {
            AppLog.general.info("Test host detected, skipping Keychain self-check")
        } else {
            do {
                try KeychainManager.shared.ping()
            } catch {
                AppLog.keychain.error("Keychain self-check failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        AppLog.general.info("Starcat bootstrap complete")
    }
}
