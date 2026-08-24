//
//  AppWebsiteLinks.swift
//  Starcat
//
//  按分发渠道隔离用户可见的网站入口。
//

import Foundation

/// App 内用户可见的网站链接。
///
/// App Store 和 Direct 共用同一套功能代码，但可见外链必须按渠道隔离：
/// App Store build 只指向 `dong4j.app` 下的合规页面；Direct build 继续指向
/// `starcat.ink`，用于官网、DMG、Sparkle 和外部支付相关说明。
struct AppWebsiteLinks: Sendable {
    /// Starcat 开源仓库与分发渠道无关；增长归因、帮助菜单和 About 必须共用这一入口。
    static let sourceRepository = URL(string: "https://github.com/starcat-app/Starcat")!

    let home: URL
    let support: URL
    let privacy: URL
    let eula: URL

    /// 当前构建渠道对应的网站链接集合。
    static var current: AppWebsiteLinks {
        links(for: .current)
    }

    /// 当前渠道下用于短品牌展示的域名。分享卡底部只放域名，不放完整路径。
    static var currentDisplayHost: String {
        current.home.host() ?? "starcat.ink"
    }

    static func links(for channel: DistributionChannel) -> AppWebsiteLinks {
        switch channel {
        case .appStore:
            return AppWebsiteLinks(
                home: URL(string: "https://dong4j.app/starcat")!,
                support: URL(string: "https://dong4j.app/starcat/support")!,
                privacy: URL(string: "https://dong4j.app/starcat/privacy")!,
                eula: URL(string: "https://dong4j.app/starcat/eula")!
            )
        case .direct:
            return AppWebsiteLinks(
                home: URL(string: "https://starcat.ink")!,
                support: URL(string: "https://starcat.ink/support")!,
                privacy: URL(string: "https://starcat.ink/privacy")!,
                eula: URL(string: "https://starcat.ink/eula")!
            )
        }
    }
}
