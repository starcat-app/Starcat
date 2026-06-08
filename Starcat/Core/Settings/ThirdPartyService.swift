//
//  ThirdPartyService.swift
//  Starcat
//
//  Starcat 依赖的第三方 / 自建后端服务清单。
//
//  这里把每个外部服务的全部元数据（标题、简介、生产 URL、源码地址、icon、accent 色、
//  健康检查路径）集中在一个枚举里，让设置页 / DI / 启动日志 / 测试连接 等多个调用方
//  共享同一份事实。新增服务时只要：
//    1. 加一个 case
//    2. 在 metadata 区每个属性的 switch 里补一行
//    3. 在 `AppSettings.customServiceURLs` 持久化字典里它会自动以 rawValue 为键存活
//    4. 在 `AppDependencies` 的 `setServiceURL` 里把热更新分发到对应 actor
//  即可，**不需要**改设置页 UI（`ServicesSettingsView` 用 `ThirdPartyService.allCases`
//  自动渲染）。
//
//  健康检查约定：每个后端都暴露 `GET <baseURL>/healthz`，返回 2xx 即视为可用。
//  `ServiceHealthChecker` 据此构造探测请求。如果将来某个服务路径不一样，把
//  `healthCheckPath` 改成对应的 case 即可。
//

import Foundation
import SwiftUI

/// Starcat 依赖的第三方 / 自建后端服务。
///
/// rawValue 用作 UserDefaults 持久化键，**不要**轻易改，否则用户已配置的自定义 URL 会丢。
enum ThirdPartyService: String, CaseIterable, Identifiable, Sendable {
    /// GitHub Trending 抓取后端（GET /repo）。
    case trending
    /// 阮一峰周刊推荐 GitHub 项目后端（GET /api/weekly/projects）。
    case weekly
    /// AI 分享卡后端（POST /api/share）。
    case sharing

    var id: String { rawValue }

    // MARK: - 展示元数据

    /// 设置页卡片标题（i18n key）。
    var titleKey: LocalizedStringKey {
        switch self {
        case .trending: return "settings.services.trending.title"
        case .weekly:   return "settings.services.weekly.title"
        case .sharing:  return "settings.services.sharing.title"
        }
    }

    /// 简短功能介绍（i18n key），告诉用户"这个服务在 Starcat 哪里被用到"。
    var descriptionKey: LocalizedStringKey {
        switch self {
        case .trending: return "settings.services.trending.description"
        case .weekly:   return "settings.services.weekly.description"
        case .sharing:  return "settings.services.sharing.description"
        }
    }

    /// 设置页行首 SF Symbol。
    /// 选取依据：与该服务在主 UI 的图标语义一致——trending 用 `flame`（"热"），
    /// weekly 用 `newspaper`（与 ActivityCategory.weekly 同款），sharing 用
    /// `square.and.arrow.up`（macOS 标准分享语义）。
    var systemImage: String {
        switch self {
        case .trending: return "flame.fill"
        case .weekly:   return "newspaper"
        case .sharing:  return "square.and.arrow.up"
        }
    }

    /// Hex 强调色（GitHub Linguist 调色板）。装饰用，不参与功能逻辑。
    /// 与 ActivityCategory / Sidebar 现有色块共存时不冲突。
    var accentColorHex: String {
        switch self {
        case .trending: return "#F05138" // Swift orange-red：与 trending"火"语义一致
        case .weekly:   return "#dea584" // Rust beige：与 ActivityCategory.weekly 完全一致
        case .sharing:  return "#3178c6" // TypeScript blue：与"分享 / 公开链接"的"链接蓝"语义一致
        }
    }

    /// SwiftUI Color；hex 非法时回退到系统强调色。
    var accentColor: Color {
        Color(hex: accentColorHex) ?? .accentColor
    }

    // MARK: - 网络元数据

    /// 生产环境默认 URL（fly.io 部署）。
    /// 与 `AppEndpoints.production(for:)` 完全一致——这里再列一遍只是为了让
    /// ThirdPartyService 自身就是"信息完整"的，不强迫调用方再绕回 AppEndpoints。
    var productionURL: URL {
        AppEndpoints.production(for: self)
    }

    /// 源码仓库 URL，设置页"自部署 / 查看源码"按钮跳转这里。
    /// 用户可以 fork 后自部署到 fly.io / Render / Oracle Cloud / 自建服务器等，
    /// 然后在设置页填入自己的域名。
    var sourceCodeURL: URL {
        switch self {
        case .trending: return URL(string: "https://github.com/dong4j/starcat-trending-api")!
        case .weekly:   return URL(string: "https://github.com/dong4j/starcat-weekly-api")!
        case .sharing:  return URL(string: "https://github.com/dong4j/starcat-sharing-api")!
        }
    }

    /// 健康检查路径（拼接到 baseURL 后面，构造 `GET <baseURL>/healthz`）。
    /// 三个服务约定都暴露这个端点，返回 200 即视为可用。
    ///
    /// 注意 `sharing` 的 baseURL 含 `/api` 后缀，但 `/healthz` 通常挂在根路径，
    /// 所以这里走 `healthCheckURL(for:base:)` 时会**剥掉** `/api` 后再拼。
    var healthCheckPath: String { "/healthz" }

    /// 给定生效 baseURL 构造健康检查 URL。
    ///
    /// 处理 `sharing` 的特殊情况：baseURL 是 `https://.../api`，`/healthz` 挂在根路径。
    /// 实现：如果 baseURL path 以 `/api` 结尾，则去掉再拼 `/healthz`；否则直接拼。
    /// 这样 trending（baseURL 无 path）/ weekly（无）/ sharing（`/api`）三种约定都能命中。
    func healthCheckURL(base: URL) -> URL {
        let trimmedBase: URL
        if base.path.hasSuffix("/api") {
            // 去掉 `/api` 后缀。`deletingLastPathComponent` 会把它当作 path component 移除。
            trimmedBase = base.deletingLastPathComponent()
        } else {
            trimmedBase = base
        }
        return trimmedBase.appendingPathComponent(healthCheckPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
}

// MARK: - URL 校验

/// 用户在设置页输入 URL 时的校验结果。
///
/// 校验规则极简：必须能解析为 `URL`、scheme ∈ {http, https}、host 非空。
/// 不做 reachability（那是 `ServiceHealthChecker` 的责任）。
enum ServiceURLValidation: Equatable {
    /// 输入合法，返回归一化后的 URL（去掉首尾空白、scheme 小写化等）。
    case valid(URL)
    /// 输入为空——这是合法状态，表示"回退到默认"。
    case empty
    /// 输入非法。message 是面向用户的本地化键。
    case invalid(reasonKey: LocalizedStringKey)

    /// 输入是否可保存（empty 与 valid 都允许，invalid 不允许）。
    var canPersist: Bool {
        switch self {
        case .valid, .empty: return true
        case .invalid:       return false
        }
    }
}

extension ThirdPartyService {
    /// 把用户输入字符串规范化 + 校验为 `ServiceURLValidation`。
    ///
    /// 规则：
    /// - 全部去掉首尾空白
    /// - 空串 → `.empty`（合法，表示"用默认"）
    /// - 必须能 `URL.init(string:)`、scheme ∈ {http, https}、host 非空
    /// - 末尾多余 `/` 不强制去掉（用户写法各异，统一以 `URL` 解析结果为准）
    ///
    /// 不接受 `file://` 等非 http 协议——三个服务都是 HTTP 后端，写 `file://` 一定是误输。
    static func validate(_ raw: String) -> ServiceURLValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        guard let url = URL(string: trimmed) else {
            return .invalid(reasonKey: "settings.services.error.invalidFormat")
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .invalid(reasonKey: "settings.services.error.invalidScheme")
        }
        guard let host = url.host, !host.isEmpty else {
            return .invalid(reasonKey: "settings.services.error.missingHost")
        }
        return .valid(url)
    }
}
