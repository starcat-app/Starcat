//
//  AppHostEnvironment.swift
//  Starcat
//
//  AppKit 自建窗口与 SwiftUI sheet 的 environment 注入标准链。
//
//  背景：StarcatApp.WindowGroup 在 contentRoot 上挂了 dependencies / subscriptionManager /
//  authSession 等 @Observable 环境值，但以下场景**不会**自动继承：
//  1. AppKit `NSHostingController` 自建的 AI 浮窗、关于窗口；
//  2. macOS 上 nested sheet / 复杂 presentation 时偶发丢失 presenter environment。
//
//  缺失时 SwiftUI 在读取 `@Environment(Foo.self)` 会触发运行时断言崩溃
//  （`EnvironmentValues.subscript.getter` + `_assertionFailure`）。
//

import SwiftUI

extension View {

    /// AppKit 自建 `NSWindow` / `NSPanel` hosting root 的标准 environment 链。
    ///
    /// 与 `StarcatApp` 主窗口注入对齐，避免 AI 浮窗等独立窗口漏挂单项 service。
    @MainActor
    @ViewBuilder
    func appHostEnvironment(
        _ dependencies: AppDependencies,
        homeViewModel: HomeViewModel? = nil
    ) -> some View {
        let rooted = self
            .starcatAnimationOverride()
            .appLocaleEnvironment()
            .environment(dependencies)
            .environment(dependencies.authSession)
            .environment(dependencies.syncManager)
            .environment(dependencies.settings)
            .environment(dependencies.subscriptionManager)
            .environment(dependencies.entitlementGate)
            .environment(dependencies.contributionService)
            .environment(dependencies.userProfileService)
            .environment(dependencies.developerLanguageService)
            .environment(dependencies.autoTidyScheduler)

        if let homeViewModel {
            rooted.environment(homeViewModel)
        } else {
            rooted
        }
    }

    /// SwiftUI `.sheet` / `.popover` 根视图的标准 environment 链。
    ///
    /// macOS sheet 通常继承 presenter environment，但 nested sheet 或 item 驱动
    /// 的重复 presentation 下可能丢失；显式注入可避免 `@Environment` 断言崩溃。
    /// `ProPaywallSheet.hosted` 与本 modifier 共用同一注入口径。
    @MainActor
    func appSheetRootEnvironment(_ dependencies: AppDependencies) -> some View {
        self
            .environment(dependencies)
            .environment(dependencies.authSession)
            .environment(dependencies.subscriptionManager)
            .environment(dependencies.developerLanguageService)
            .appLocaleEnvironment()
    }
}
