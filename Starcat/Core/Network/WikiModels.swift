//
//  WikiModels.swift
//  Starcat
//
//  starcat-wiki-api 单仓库探测响应模型。
//
//  关键约束：
//  - 后端 v2 当前状态为 indexed / not_indexed / error，但服务仍在快速演进；未知值必须
//    宽松解码，不能因为新增一个状态或来源导致整个详情页响应解码失败。
//  - 客户端只把 indexed 当成可跳转结果。not_indexed / error / unknown 都不猜测 URL 可用性。
//  - URL 由服务端返回；真正展示前由 RepoWikiMenuState 再校验 http/https + host。
//
//  2026-06-15 起补 `Encodable`（→ `Codable`）：`DiskWikiCache` 把整个 `[WikiStatusItem]`
//  连同 probe 时间戳一起序列化进 JSON 落盘，所以网络 DTO 同时也是 disk schema。
//  原因：(a) 项目近期 4 个磁盘缓存（HOM-68 v2 / HOM-69 / HOM-70 / 即将的 wiki）都按
//  "wire DTO 直接 Codable 落盘" 同款风格，单一信任源；(b) 项目未上线无 schema 迁移
//  负担，以后改 wire DTO 直接覆写 cache 即可。带关联值的 `unknown(String)` 案的
//  encode 需要手写，写法是把 raw value 字符串编码到 single-value container（与
//  decode 对称）。
//

import Foundation

/// 外部 Wiki 来源。
///
/// 使用带关联值的 `unknown` 而非普通 raw-value enum，是为了让后端以后增加来源时老客户端
/// 仍能解码整包数据，并继续展示已经认识的来源。
enum WikiSource: Codable, Sendable, Hashable {
    case deepWiki
    case zread
    case codeWiki
    case unknown(String)

    var rawValue: String {
        switch self {
        case .deepWiki: return "deepwiki"
        case .zread: return "zread"
        case .codeWiki: return "codewiki"
        case .unknown(let raw): return raw
        }
    }

    var displayName: String {
        switch self {
        case .deepWiki: return String(localized: "wiki.source.deepwiki")
        case .zread: return String(localized: "wiki.source.zread")
        case .codeWiki: return String(localized: "wiki.source.codewiki")
        case .unknown(let raw): return raw
        }
    }

    /// 菜单固定顺序不依赖后端并发探测的返回顺序。
    var sortOrder: Int {
        switch self {
        case .deepWiki: return 0
        case .zread: return 1
        case .codeWiki: return 2
        case .unknown: return 3
        }
    }

    /// 菜单行图标。v1.4（2026-06-12）：从 SF Symbol 切换为各家品牌 logo（PNG），
    /// 提升来源识别度和品牌一致性。资源位于 `Assets.xcassets/WikiSources/` 命名空间。
    ///
    /// 适配细节：
    /// - `zread` 原图是深灰圆角方形 + 浅灰 V 线条，dark mode 下与背景融合不可见；
    ///   imageset 已配置 luminosity=dark appearance 走反色版本（浅底 + 深灰线条）。
    /// - `deepwiki` / `codewiki` 自身明暗对比足够，两种 mode 共用单版本。
    /// - `unknown` 后备：用 SF Symbol `doc.text`，避免新来源出现时图标空白。
    ///
    /// 返回 `nil` 表示走 SF Symbol fallback（仅 `.unknown` 走此路径）。
    var assetName: String? {
        switch self {
        case .deepWiki: return "WikiSources/deepwiki"
        case .zread: return "WikiSources/zread"
        case .codeWiki: return "WikiSources/codewiki"
        case .unknown: return nil
        }
    }

    /// `assetName` 为 nil 时的 SF Symbol fallback（目前只有 unknown 来源走这里）。
    var fallbackSFSymbol: String {
        "doc.text"
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "deepwiki": self = .deepWiki
        case "zread": self = .zread
        case "codewiki": self = .codeWiki
        default: self = .unknown(raw)
        }
    }

    /// 2026-06-15：手写 encode 配合磁盘缓存（`DiskWikiCache`）落盘。
    /// `unknown(raw)` 需要把关联值字符串写回，让下次 decode 还能还原成同一个 case。
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Wiki 探测状态。
///
/// `probing` 理论上会被后端映射为 `not_indexed`，这里仍通过 unknown 容忍服务端契约漂移。
enum WikiProbeStatus: Codable, Sendable, Equatable {
    case indexed
    case notIndexed
    case error
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "indexed": self = .indexed
        case "not_indexed": self = .notIndexed
        case "error": self = .error
        default: self = .unknown(raw)
        }
    }

    /// 2026-06-15：手写 encode 配合磁盘缓存。raw value 跟服务端契约保持一致
    /// （`indexed` / `not_indexed` / `error`），未知 case 透传原 raw。
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let raw: String
        switch self {
        case .indexed: raw = "indexed"
        case .notIndexed: raw = "not_indexed"
        case .error: raw = "error"
        case .unknown(let value): raw = value
        }
        try container.encode(raw)
    }
}

/// 单个外部 Wiki 来源的探测结果。
///
/// 2026-06-15 起从 `Decodable` 升级为 `Codable`：除原网络解码路径外，磁盘缓存
/// （`DiskWikiCache`）同时把此 struct 数组直接编码进缓存 JSON。
struct WikiStatusItem: Codable, Sendable, Identifiable, Equatable {
    let source: WikiSource
    let status: WikiProbeStatus
    let url: URL
    let probeMethod: String?
    let httpStatus: Int?
    let matchedSignals: [String]?

    var id: String { source.rawValue }
}

/// 详情页菜单使用的已确认外部链接。
struct WikiLink: Identifiable, Sendable, Equatable {
    let source: WikiSource
    let url: URL

    var id: String { source.rawValue }
    var title: String { source.displayName }
}

/// 把网络 DTO 收敛成 UI 可展示链接的纯状态转换。
///
/// 单独保留纯函数便于测试显隐、URL 安全校验和固定排序，不需要为一次请求引入 ViewModel。
enum RepoWikiMenuState {
    static func make(items: [WikiStatusItem]) -> [WikiLink] {
        items.compactMap { item in
            guard item.status == .indexed,
                  !isUnknown(item.source),
                  let scheme = item.url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  item.url.host?.isEmpty == false else {
                return nil
            }
            return WikiLink(source: item.source, url: item.url)
        }
        .sorted { lhs, rhs in
            lhs.source.sortOrder < rhs.source.sortOrder
        }
    }

    private static func isUnknown(_ source: WikiSource) -> Bool {
        if case .unknown = source { return true }
        return false
    }
}
