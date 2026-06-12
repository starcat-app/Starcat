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

import Foundation

/// 外部 Wiki 来源。
///
/// 使用带关联值的 `unknown` 而非普通 raw-value enum，是为了让后端以后增加来源时老客户端
/// 仍能解码整包数据，并继续展示已经认识的来源。
enum WikiSource: Decodable, Sendable, Hashable {
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

    /// 菜单行图标。给三家用各有区分度的 SF Symbol，避免列表里三个 `arrow.up.right.square`
    /// 让用户分不清来源。选 symbol 原则：
    /// - 体现该来源的产品调性（DeepWiki 偏"理解 / 深度"→ brain / sparkles，Zread 偏"快速阅读"
    ///   → bolt.text，Code Wiki 偏"代码索引"→ chevron.left.forwardslash.chevron.right）
    /// - 同时全部在 macOS 15+ 可用，不需要额外可用性 fallback
    var sfSymbol: String {
        switch self {
        case .deepWiki: return "sparkles.rectangle.stack"
        case .zread: return "text.book.closed"
        case .codeWiki: return "chevron.left.forwardslash.chevron.right"
        case .unknown: return "doc.text"
        }
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
}

/// Wiki 探测状态。
///
/// `probing` 理论上会被后端映射为 `not_indexed`，这里仍通过 unknown 容忍服务端契约漂移。
enum WikiProbeStatus: Decodable, Sendable, Equatable {
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
}

/// 单个外部 Wiki 来源的探测结果。
struct WikiStatusItem: Decodable, Sendable, Identifiable {
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
