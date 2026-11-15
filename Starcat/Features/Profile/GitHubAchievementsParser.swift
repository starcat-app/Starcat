//
//  GitHubAchievementsParser.swift
//  Starcat
//
//  解析公开成就页的卡片摘要；GitHub 尚无官方成就读取 API，结构变化必须报错以保留旧缓存。
//

import Foundation

/// 仅解析成就卡片，不执行网页脚本，也不从 README 图片或侧栏重复头像推算勋章。
enum GitHubAchievementsParser {
    /// 要求成就路由与资料主体同时存在，阻止登录页、限流页被当成“没有勋章”缓存。
    static func parse(_ html: String) throws -> [GitHubAchievement] {
        guard html.contains("profiles_achievements"), html.contains("user-profile-frame") else {
            throw NetworkError.invalidResponse
        }
        let cardPattern = #"<details\b[^>]*\bdata-achievement-slug\s*=\s*["']([^"']+)["'][^>]*>\s*<summary\b[^>]*>([\s\S]*?)</summary>"#
        let cards = try matches(cardPattern, in: html)
        var achievements: [GitHubAchievement] = []
        var seen: Set<String> = []
        for card in cards {
            let slug = card[1]
            guard seen.insert(slug).inserted else { continue }
            let summary = card[2]
            guard let imageTag = try matches(#"<img\b[^>]*>"#, in: summary).first?.first,
                  let source = try attribute("src", in: imageTag),
                  let imageURL = URL(string: source),
                  imageURL.scheme == "https", imageURL.host == "github.githubassets.com",
                  let alt = try attribute("alt", in: imageTag), alt.hasPrefix("Achievement: ") else {
                throw NetworkError.invalidResponse
            }
            let name = String(alt.dropFirst("Achievement: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw NetworkError.invalidResponse }
            let tier = try matches(
                #"<span\b[^>]*class\s*=\s*["'][^"']*\bachievement-tier-label\b[^"']*["'][^>]*>\s*([^<]+)</span>"#,
                in: summary
            ).first?[1].trimmingCharacters(in: .whitespacesAndNewlines)
            achievements.append(GitHubAchievement(id: slug, name: name, imageURL: imageURL, tier: tier))
        }
        // 页面仍有成就标记却读不到卡片时，属于网页契约变化，不是成功的空列表。
        if achievements.isEmpty && (html.contains("achievement-badge") || html.contains("data-achievement-slug")) {
            throw NetworkError.invalidResponse
        }
        return achievements
    }

    /// 正则只处理有明确边界的 summary / img 子集，不尝试重建完整 HTML DOM。
    private static func matches(_ pattern: String, in text: String) throws -> [[String]] {
        let expression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// 使用 XML 仅解码属性实体，避免引入 HTML 解析依赖；不把整张 HTML5 页面交给 XML tidy。
    private static func attribute(_ name: String, in tag: String) throws -> String? {
        guard let raw = try matches(#"\b"# + name + #"\s*=\s*["']([^"']*)["']"#, in: tag).first?[1] else {
            return nil
        }
        let fragment = try XMLDocument(xmlString: "<value>\(raw)</value>", options: [.nodeLoadExternalEntitiesNever])
        return fragment.rootElement()?.stringValue
    }
}
