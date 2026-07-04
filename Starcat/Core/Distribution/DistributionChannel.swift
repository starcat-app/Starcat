//
//  DistributionChannel.swift
//  Starcat
//
//  构建分发渠道。
//

import Foundation

/// Starcat 的构建分发渠道。
///
/// 渠道必须来自构建配置注入，而不是运行时猜测 bundle 路径、receipt 或是否存在某个
/// framework。App Store 审核边界需要可复现：App Store build 永远只走 Apple 分发，
/// Direct build 才允许 Sparkle 和外部授权入口。
enum DistributionChannel: String, Sendable {
    case appStore = "appstore"
    case direct

    private static let infoPlistKey = "STARCAT_DISTRIBUTION"

    /// 当前 App bundle 声明的渠道。缺省回退 App Store，避免新 contributor 没有本地配置时
    /// 意外暴露 Direct / Sparkle / 外部支付路径。
    static var current: DistributionChannel {
        resolve(from: Bundle.main)
    }

    static func resolve(from bundle: Bundle) -> DistributionChannel {
        let rawValue = (bundle.object(forInfoDictionaryKey: infoPlistKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let rawValue, rawValue.isEmpty == false else {
            return .appStore
        }
        return DistributionChannel(rawValue: rawValue) ?? .appStore
    }

    var isAppStore: Bool { self == .appStore }
    var isDirect: Bool { self == .direct }
}
