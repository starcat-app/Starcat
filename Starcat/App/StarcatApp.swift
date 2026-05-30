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
                .task {
                    await dependencies.authSession.restoreSessionIfAvailable()
                }
        }
        .windowResizability(.contentSize)

        // macOS 原生 Settings 窗口（Cmd+,）
        Settings {
            SettingsView()
                .environment(dependencies.settings)
        }
    }

    // MARK: - Bootstrap

    private static func bootstrap() {
        AppLog.general.info("Starcat starting (bundle=\(AppConstants.bundleIdentifier, privacy: .public))")
        DatabaseManager.bootstrap()
        do {
            try KeychainManager.shared.ping()
        } catch {
            AppLog.keychain.error("Keychain self-check failed: \(error.localizedDescription, privacy: .public)")
        }
        AppLog.general.info("Starcat bootstrap complete")
    }
}
