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
        AppHostEnvironmentContainer(
            content: self,
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
    }

    /// SwiftUI `.sheet` / `.popover` 根视图的标准 environment 链。
    ///
    /// macOS sheet 通常继承 presenter environment，但 nested sheet 或 item 驱动
    /// 的重复 presentation 下可能丢失；显式注入可避免 `@Environment` 断言崩溃。
    /// `ProPaywallSheet.hosted` 与本 modifier 共用同一注入口径。
    @MainActor
    func appSheetRootEnvironment(_ dependencies: AppDependencies) -> some View {
        // Sheet 与 AppKit hosting root 面临同一种边界：都不能假设 presenter 的
        // Observation environment 永远完整继承。复用标准链，避免两份清单再次漂移。
        appHostEnvironment(dependencies)
    }
}

/// AppKit 独立窗口的 environment 根节点。
///
/// 必须在 SwiftUI `body` 内读取 `settings.interfaceScale`：在 window controller init 里把值
/// 直接塞进 modifier 只会得到打开窗口那一刻的快照，Settings 后续改字号不会重绘。
private struct AppHostEnvironmentContainer<Content: View>: View {
    let content: Content
    let dependencies: AppDependencies
    let homeViewModel: HomeViewModel?

    var body: some View {
        // AppSettings 是 @Observable；这里的读取会令独立 NSHostingController 根视图订阅字号变化。
        let interfaceScale = dependencies.settings.interfaceScale
        let rooted = content
            .starcatAnimationOverride()
            .appLocaleEnvironment()
            // AppKit 自建窗口不经过 StarcatApp.contentRoot,需要在这里同步注入
            // 主窗口同款字号倍率,否则 Agent/RAG/AI 独立窗口会退回 standard。
            .environment(\.starcatInterfaceScale, interfaceScale)
            // 知识库浏览器等仍使用 `.caption` / `.body` 的原生 text style 也随设置更新。
            // 显式 `StarcatTypography` 已自行乘倍率，不会受到 Dynamic Type 的二次影响。
            .dynamicTypeSize(interfaceScale.dynamicTypeSize)
            .environment(dependencies)
            .environment(dependencies.authSession)
            .environment(dependencies.syncManager)
            .environment(dependencies.settings)
            .environment(dependencies.subscriptionManager)
            .environment(dependencies.directLicenseManager)
            .environment(dependencies.entitlementGate)
            // 独立窗口不会继承 StarcatApp Scene；漏掉命令路由会在详情页的
            // refresh / repository AI modifier 读取 @Environment 时直接断言崩溃。
            .starcatCommandRouterEnvironment()
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
}
