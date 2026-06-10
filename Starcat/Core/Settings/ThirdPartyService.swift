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

    /// 给定生效 baseURL 构造健康检查 URL。
    ///
    /// healthz path 由各自命名空间下的 `Paths.healthz` 提供（sharing 例外，见下）。
    /// 调用方一般是 `ServiceHealthChecker`，传入"当前生效"或"用户草稿"的 baseURL，
    /// 让"测试连接"按钮不依赖已持久化的值，能预先验证草稿。
    ///
    /// **sharing 的特殊处理**：sharing 的 baseURL 含 `/api` 后缀（业务请求语义），
    /// 而 `/healthz` 挂在根路径，所以走 `AppEndpoints.Sharing.healthzURL(over:)` 单独
    /// 处理（内部会剥掉 `/api` 再拼）。weekly / trending 无此特例，直接 appendPath。
    func healthCheckURL(base: URL) -> URL {
        switch self {
        case .weekly:
            return AppEndpoints.appendPath(AppEndpoints.Weekly.Paths.healthz, to: base)
        case .trending:
            return AppEndpoints.appendPath(AppEndpoints.Trending.Paths.healthz, to: base)
        case .sharing:
            return AppEndpoints.Sharing.healthzURL(over: base)
        }
    }

    /// R-01 v1.2 2026-06-10：构造「鉴权探测」URL，用于在 healthz 通过后追加一次轻量
    /// `/api/v1/*` GET 探测，验证 Bearer Token 是否被后端 authMiddleware 接受。
    ///
    /// 每服务选最便宜 / 副作用最小的 GET 端点：
    /// - trending: `/api/v1/languages` —— 启动期会缓存的语言字典（~几 KB），开销最低
    /// - weekly: `/api/v1/issues` —— 周刊期号列表（轻量 GET）
    /// - sharing: `/api/v1/share` —— GET 方法在后端无注册（业务是 POST），但 authMiddleware
    ///   先于路由匹配执行：无 / 错 token → 401；有正确 token → 404 或 405（路由不匹配）。
    ///   ServiceHealthChecker 把「401 = unauthorized；其他 = 鉴权通过（即便路由 404/405）」。
    ///
    /// **sharing 与 healthz 同款剥 /api 处理**：sharing 的 baseURL 已经含 `/api` 后缀
    /// （业务请求拼出 `<base>/v1/share`，等价于 `<host>/api/v1/share`）；这里 authProbeURL
    /// 走 `AppEndpoints.Sharing.url(_:)` 拼出 `<host>/api/v1/share`，与 baseURL 形态一致。
    func authProbeURL(base: URL) -> URL {
        switch self {
        case .weekly:
            return AppEndpoints.appendPath(AppEndpoints.Weekly.Paths.issues, to: base)
        case .trending:
            return AppEndpoints.appendPath(AppEndpoints.Trending.Paths.languages, to: base)
        case .sharing:
            // sharing 的 base 含 /api；业务拼 <base>/v1/share；这里也拼 <base>/v1/share
            // 即 <host>/api/v1/share，让 authMiddleware 鉴权后路由到 GET（未注册 → 404/405）。
            return AppEndpoints.appendPath(AppEndpoints.Sharing.Paths.share, to: base)
        }
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
