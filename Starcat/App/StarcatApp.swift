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

    /// 是否处于 XCTest / Swift Testing 测试 host 进程内。
    ///
    /// 判定依据：
    /// - `XCTestCase` 类在测试 host 启动时由 XCTest framework 注入到 ObjC runtime
    /// - `XCTestConfigurationFilePath` 是 xcodebuild 跑测试时必然写入的环境变量
    /// 任一命中即视为测试环境。
    ///
    /// 用途：测试期跳过会触发系统 GUI 授权弹窗 / 阻塞主线程的启动逻辑（如 Keychain.ping），
    /// 避免测试 host App 因为等待用户输入密码而 hang 导致 testmanagerd 5.5min 超时。
    private static let isRunningTests: Bool = {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()

    private static func bootstrap() {
        AppLog.general.info("Starcat starting (bundle=\(AppConstants.bundleIdentifier, privacy: .public))")
        DatabaseManager.bootstrap()

        // 测试期跳过 Keychain 自检：ad-hoc 签名 + ACL 不匹配会触发 GUI 授权弹窗，
        // 测试 host 主线程被对话框阻塞 → testmanagerd 永远连不上 App。
        // 详见 docs/工程进度/2026-05-30-Keychain-临时绕过方案.md
        if isRunningTests {
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
