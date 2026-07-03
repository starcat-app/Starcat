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
//  测试连接约定（R-03 2026-06-11 重构）：
//  以前用「/healthz（无鉴权）+ 业务 endpoint（带鉴权）」两阶段探测，体验上有坑——
//  sharing 的 GET /api/v1/share 返 404/405、wiki 的 GET /api/v1/wikis 缺参数返 400，
//  客户端要写一堆「这个状态码其实算 ok」的特殊判定。
//
//  现在统一走 **`/api/v1/ping`**（R-03.1 起 sharing 也走绝对 `/api/v1/ping`，
//  不再因 baseURL 含 `/api` 而特殊），这是后端专门为 Starcat 客户端「测试连接」按钮
//  加的端点，行为完全标准化：
//   - 200 + `data.service` 匹配 + `data.ok` → 服务可达 + Key 正确 + 地址没配错
//   - 200 但 `data.service` 不匹配 → 客户端报 serviceMismatch（防端口 / 服务填错）
//   - 401 → Key 错（缺 Authorization 头 / 错 token 都走这里）
//   - 其他 4xx/5xx → 服务有问题（含状态码）
//   - 网络错 → 完全连不上
//  `ServiceHealthChecker` 基于本端点单步探测。
//
//  状态栏可用性约定（2026-06-21）：
//  状态栏只需要知道自建 API 进程是否在线，因此走后端专门暴露的无鉴权 `GET /healthz`。
//  它不校验 API Key，也不替代设置页「测试连接」；两个入口语义分离，避免状态面板把
//  “Key 错”误报成“服务不可用”。
//
//  URL 规范化（R-03.1 2026-06-11）：
//  用户在设置页可能输入各种形态——`http://127.0.0.1:5004`、`http://127.0.0.1:5004/`
//  甚至（历史 sharing）`https://x.fly.dev/api`。这些都应当规范化为「裸 host + 端口」
//  形态再持久化和发起请求，避免后续拼接出现双斜杠 / 多一段 `/api`。
//  - `validate(_:)`：把用户输入字符串解析、校验、并 trim 末尾 `/`（通用，所有服务一视同仁）。
//  - `normalizedBaseURL(_:)`：服务感知归一化——sharing 额外剥末尾 `/api`（兼容 R-03 前
//    历史持久化数据），其它服务直透。
//  调用顺序：`validate → 调用方拿到 .valid(url) → service.normalizedBaseURL(url) → 持久化 / 探测`。
//

import Foundation
import SwiftUI

/// Starcat 依赖的第三方 / 自建后端服务。
///
/// rawValue 用作 UserDefaults 持久化键，**不要**轻易改，否则用户已配置的自定义 URL 会丢。
enum ThirdPartyService: String, CaseIterable, Identifiable, Sendable {
    /// GitHub Trending 抓取后端（GET /api/v1/repos）。
    case trending
    /// 阮一峰周刊推荐 GitHub 项目后端（GET /api/v1/weekly）。
    case weekly
    /// AI 分享卡后端（POST /api/v1/share）。
    case sharing
    /// 外部文档站索引探测后端（GET /api/v1/wikis）。
    case wiki
    /// 相似仓库推荐后端（GET /api/v1/repos/{repo_id}/recommendations）。
    case recommend
    /// 探索发现后端（GET /api/v1/discovery/*）。
    case discovery

    var id: String { rawValue }

    /// `Info.plist` / xcconfig 里该服务 baked-in production API Key 的字段名。
    var productionAPIKeyInfoPlistKey: String {
        switch self {
        case .trending: return "STARCAT_PRODUCTION_API_KEY_TRENDING"
        case .weekly:   return "STARCAT_PRODUCTION_API_KEY_WEEKLY"
        case .sharing:  return "STARCAT_PRODUCTION_API_KEY_SHARING"
        case .wiki:     return "STARCAT_PRODUCTION_API_KEY_WIKI"
        case .recommend: return "STARCAT_PRODUCTION_API_KEY_RECOMMEND"
        case .discovery: return "STARCAT_PRODUCTION_API_KEY_DISCOVERY"
        }
    }

    // MARK: - 展示元数据

    /// 设置页卡片标题（i18n key）。
    var titleKey: LocalizedStringKey {
        switch self {
        case .trending: return "settings.services.trending.title"
        case .weekly:   return "settings.services.weekly.title"
        case .sharing:  return "settings.services.sharing.title"
        case .wiki:     return "settings.services.wiki.title"
        case .recommend: return "settings.services.recommend.title"
        case .discovery: return "settings.services.discovery.title"
        }
    }

    /// 简短功能介绍（i18n key），告诉用户"这个服务在 Starcat 哪里被用到"。
    var descriptionKey: LocalizedStringKey {
        switch self {
        case .trending: return "settings.services.trending.description"
        case .weekly:   return "settings.services.weekly.description"
        case .sharing:  return "settings.services.sharing.description"
        case .wiki:     return "settings.services.wiki.description"
        case .recommend: return "settings.services.recommend.description"
        case .discovery: return "settings.services.discovery.description"
        }
    }

    /// 设置页行首 SF Symbol。
    /// 选取依据：与该服务在主 UI 的图标语义一致——trending 用 `flame`（"热"），
    /// weekly 用 `newspaper`（与 Explore Weekly 同款），sharing 用
    /// `square.and.arrow.up`（macOS 标准分享语义）。
    var systemImage: String {
        switch self {
        case .trending: return "flame.fill"
        case .weekly:   return "newspaper"
        case .sharing:  return "square.and.arrow.up"
        case .wiki:     return "book.pages"
        case .recommend: return "point.3.connected.trianglepath.dotted"
        case .discovery: return "safari"
        }
    }

    /// Hex 强调色（GitHub Linguist 调色板）。装饰用，不参与功能逻辑。
    /// 与 ActivityCategory / Sidebar 现有色块共存时不冲突。
    var accentColorHex: String {
        switch self {
        case .trending: return "#F05138" // Swift orange-red：与 trending"火"语义一致
        case .weekly:   return "#dea584" // Rust beige：与 Explore Weekly 视觉保持一致
        case .sharing:  return "#3178c6" // TypeScript blue：与"分享 / 公开链接"的"链接蓝"语义一致
        case .wiki:     return "#8B5CF6" // Violet：与知识库 / 文档入口区分现有三个服务
        case .recommend: return "#34D399" // Emerald：与"发现相似项目"的推荐语义区分现有服务
        case .discovery: return "#F59E0B" // Amber：探索入口用暖色，与推荐 emerald 区分
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
        case .wiki:     return URL(string: "https://github.com/dong4j/starcat-wiki-api")!
        case .recommend: return URL(string: "https://github.com/dong4j/starcat-recommend-api")!
        case .discovery: return URL(string: "https://github.com/dong4j/starcat-discovery-api")!
        }
    }

    /// 给定生效 baseURL 构造「测试连接」探测 URL（R-03 2026-06-11）。
    ///
    /// R-03.1 起自建后端**统一**暴露 `GET /api/v1/ping`，由 BearerAuth middleware 保护。
    /// 200 = 服务可达 + Key 正确；401 = Key 错；其他 = 服务异常。
    ///
    /// 内部先调 `normalizedBaseURL(base)` 兜底「baseURL 末尾 `/` 或（仅 sharing）末尾 `/api`」
    /// 这两种历史/容错形态，再拼 path。调用方传未规范化的 URL 也安全。
    ///
    /// 调用方一般是 `ServiceHealthChecker`，传入"当前生效"或"用户草稿"的 baseURL，
    /// 让"测试连接"按钮不依赖已持久化的值，能预先验证草稿。
    ///
    /// 历史 baggage：原本有 `healthCheckURL` + `authProbeURL` 两个函数（两阶段探测），
    /// R-03 合并为 `pingURL`；R-03.1 又取消了 sharing 的 `/v1/ping` 特例。
    /// 详见文件顶部注释 + ServiceHealthChecker.swift。
    func pingURL(base: URL) -> URL {
        let normalized = normalizedBaseURL(base)
        switch self {
        case .weekly:
            return AppEndpoints.appendPath(AppEndpoints.Weekly.Paths.ping, to: normalized)
        case .trending:
            return AppEndpoints.appendPath(AppEndpoints.Trending.Paths.ping, to: normalized)
        case .sharing:
            return AppEndpoints.appendPath(AppEndpoints.Sharing.Paths.ping, to: normalized)
        case .wiki:
            return AppEndpoints.appendPath(AppEndpoints.Wiki.Paths.ping, to: normalized)
        case .recommend:
            return AppEndpoints.appendPath(AppEndpoints.Recommend.Paths.ping, to: normalized)
        case .discovery:
            return AppEndpoints.appendPath(AppEndpoints.Discovery.Paths.ping, to: normalized)
        }
    }

    /// 给定生效 baseURL 构造状态栏服务可用性巡检 URL（2026-06-21）。
    ///
    /// `/healthz` 是后端进程级健康检查，不需要 Authorization。状态栏用它做轻量实时巡检；
    /// 设置页「测试连接」仍走 `pingURL(base:)`，负责校验服务类型 + API Key。
    func healthURL(base: URL) -> URL {
        let normalized = normalizedBaseURL(base)
        switch self {
        case .weekly:
            return AppEndpoints.appendPath(AppEndpoints.Weekly.Paths.healthz, to: normalized)
        case .trending:
            return AppEndpoints.appendPath(AppEndpoints.Trending.Paths.healthz, to: normalized)
        case .sharing:
            return AppEndpoints.appendPath(AppEndpoints.Sharing.Paths.healthz, to: normalized)
        case .wiki:
            return AppEndpoints.appendPath(AppEndpoints.Wiki.Paths.healthz, to: normalized)
        case .recommend:
            return AppEndpoints.appendPath(AppEndpoints.Recommend.Paths.healthz, to: normalized)
        case .discovery:
            return AppEndpoints.appendPath(AppEndpoints.Discovery.Paths.healthz, to: normalized)
        }
    }

    /// 服务感知的 baseURL 规范化（R-03.1 2026-06-11 新增）。
    ///
    /// 用途：在「保存到 customServiceURL」「发送 ping 请求」「构造业务 URL」之前调用，
    /// 把 baseURL 收敛到统一形态，避免后续拼接出现 `//`、`/api/api`、`/api/v1` 多前缀。
    ///
    /// 行为：
    /// 1. **通用**：用 URLComponents 重组，剥末尾连续 `/`（path 为 `/` 时整段清空 → 末尾无 /）。
    /// 2. **Sharing 特例**：再剥末尾的 `/api` 段。这是为兼容 R-03 之前的历史持久化值
    ///    （那时 productionURL 是 `.fly.dev/api`，customServiceURL 也可能是 `something/api`）；
    ///    R-03.1 起所有 Paths 已写成绝对 `/api/v1/...`，base 必须不含 `/api` 才能正确拼接。
    ///
    /// 不做：query / fragment 清理（保留用户原意）；不做 scheme 大小写转换（host 大小写也保留）。
    /// 失败：URLComponents 解析失败时直接返回原 URL（保守兜底，避免 normalize 反而破坏请求）。
    func normalizedBaseURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        while components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }

        if self == .sharing {
            // 兼容 R-03 之前用户已持久化的 `<host>/api` 形态。只剥一段，不递归，
            // 避免误伤用户可能合法填的 `<host>/api/api`（虽然几乎不可能）。
            if components.path == "/api" || components.path.hasSuffix("/api") {
                components.path = String(components.path.dropLast("/api".count))
            }
        }

        return components.url ?? url
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
    /// - **末尾连续 `/` 全剥**：`http://127.0.0.1:5004/` → `http://127.0.0.1:5004`
    ///   （R-03.1 2026-06-11，dong4j 反馈防御编程）
    /// - 走 URLComponents 重组，避免 URL.init 把 `:5004/` 与 `:5004` 当两个等价但字符串
    ///   不同的 URL（后续 `absoluteString` 持久化 + UI 显示就会不一致）
    ///
    /// 不接受 `file://` 等非 http 协议——自建服务都是 HTTP 后端，写 `file://` 一定是误输。
    ///
    /// 注意：本方法是**服务无关**的通用归一化。服务感知的额外归一化（例如 sharing
    /// 剥末尾 `/api`）放在 `ThirdPartyService.normalizedBaseURL(_:)`，调用方在拿到
    /// `.valid(url)` 后再走一次。这样保证：
    ///  - validate 可以作 static func（无 self），单元测试只关心通用规则
    ///  - service-aware 归一化集中在一处，单一信息源
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

        // 通用归一化：用 URLComponents 重组，剥末尾连续 `/`。
        // URLComponents 解析失败时（理论上前面已通过 URL.init，不应失败）安全降级到原 URL。
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .valid(url)
        }
        while components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        let normalized = components.url ?? url
        return .valid(normalized)
    }
}
