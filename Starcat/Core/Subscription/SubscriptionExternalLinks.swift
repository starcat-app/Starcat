//
//  SubscriptionExternalLinks.swift
//  Starcat
//
//  订阅相关外部链接。
//

import Foundation

/// 订阅相关外部链接集中定义。
///
/// 当前 macOS SDK 中 `AppStore.showManageSubscriptions` 不可用，本轮先使用 Apple 官方
/// 账户订阅管理 URL。后续如果 SDK 暴露 macOS 原生管理面板，只需替换这里的入口。
enum SubscriptionExternalLinks {
    static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
}
