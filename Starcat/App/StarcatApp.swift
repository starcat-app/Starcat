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
