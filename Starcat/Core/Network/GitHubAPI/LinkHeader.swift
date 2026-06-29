//
//  LinkHeader.swift
//  Starcat
//
//  GitHub Link 响应头解析。
//
//  示例：
//      Link: <https://api.github.com/user/starred?page=2>; rel="next",
//            <https://api.github.com/user/starred?page=50>; rel="last"
//
//  GitHub 分页 API 使用 RFC 5988 Web Linking。我们关心 `next` 和 `last`。
//

import Foundation

/// 解析后的 Link 头。
struct LinkHeader: Equatable, Sendable {
    /// 下一页页码（rel="next"），nil 表示无下一页（即当前是最后一页）。
    let nextPage: Int?
    /// 最后一页页码（rel="last"），nil 表示无法判定总页数（当前是最后一页时通常没有 last）。
    let lastPage: Int?

    /// 解析 Link 头字符串。
    ///
    /// 容错策略：单条解析失败不中断整个解析，返回部分结果。
    /// 这样即便 GitHub 返回意外格式，我们仍能尽力前进。
    static func parse(_ header: String?) -> LinkHeader {
        guard let header, !header.isEmpty else {
            return LinkHeader(nextPage: nil, lastPage: nil)
        }

        var nextPage: Int?
        var lastPage: Int?

        // 按逗号分割多条 link
        let entries = header.components(separatedBy: ",")
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            // 形如 <url>; rel="xxx"
            let parts = trimmed.components(separatedBy: ";")
            guard parts.count >= 2 else { continue }

            let urlPart = parts[0].trimmingCharacters(in: .whitespaces)
            guard urlPart.hasPrefix("<"), urlPart.hasSuffix(">") else { continue }
            let urlString = String(urlPart.dropFirst().dropLast())
            guard let page = pageNumber(from: urlString) else { continue }

            // 在剩余 parts 中找 rel
            let rel = parts.dropFirst()
                .compactMap { partRel($0) }
                .first

            switch rel {
            case "next": nextPage = page
            case "last": lastPage = page
            default: break
            }
        }

        return LinkHeader(nextPage: nextPage, lastPage: lastPage)
    }

    // MARK: - private helpers

    private static func partRel(_ part: String) -> String? {
        // 形如 ` rel="next"`
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("rel=") else { return nil }
        var value = trimmed.dropFirst("rel=".count)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = value.dropFirst().dropLast()
        }
        return String(value)
    }

    private static func pageNumber(from urlString: String) -> Int? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        for item in items where item.name == "page" {
            if let value = item.value, let page = Int(value) {
                return page
            }
        }
        return nil
    }
}
