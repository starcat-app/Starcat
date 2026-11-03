//
//  DailyRadarSafeHTML.swift
//  Starcat
//
//  日报原始 HTML 的有限展示语义：折叠块、行内强调与经过 URL 校验的链接。
//  所有标签都重新生成，不透传事件、样式或其它来源属性；未知元素始终转义。
//

import Foundation

/// 只负责来源 HTML 的白名单重建，不承担完整 HTML 文档解析或 Markdown 语法修复。
enum DailyRadarSafeHTML {
    // 引号内的 > 不结束标签，避免 onclick/title 等属性内容被当作新的标签片段扫描。
    private static let tokens = try! NSRegularExpression(pattern: #"<(?:"[^"]*"|'[^']*'|[^'">])*>"#)
    private static let tag = try! NSRegularExpression(
        pattern: #"^<\s*(/?)\s*([a-z][a-z0-9]*)\b([\s\S]*)>$"#,
        options: .caseInsensitive
    )
    private static let attributes = try! NSRegularExpression(
        pattern: #"\s+([a-z_:][a-z0-9_.:-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#,
        options: .caseInsensitive
    )
    private static let entities = try! NSRegularExpression(
        pattern: #"&(?:amp|lt|gt|quot|apos|nbsp|#[0-9]+|#x[0-9a-f]+);"#,
        options: .caseInsensitive
    )

    /// InlineHTML 与 HTMLBlock 共用入口；文本先解实体再转义，避免双重编码。
    static func render(_ raw: String) -> String {
        let source = raw as NSString
        var end = 0
        var result = ""
        for match in tokens.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
            let text = source.substring(with: NSRange(location: end, length: match.range.location - end))
            result += DailyRadarMarkdownRenderer.escape(decoded(text))
            result += renderTag(source.substring(with: match.range))
            end = NSMaxRange(match.range)
        }
        result += DailyRadarMarkdownRenderer.escape(decoded(source.substring(from: end)))
        return result
    }

    /// 属性扫描消费完整的引号值；不能在 title/onclick 的文本里误认另一个 href。
    private static func renderTag(_ raw: String) -> String {
        let source = raw as NSString
        guard let match = tag.firstMatch(in: raw, range: NSRange(location: 0, length: source.length)) else {
            return DailyRadarMarkdownRenderer.escape(raw)
        }
        let closing = source.substring(with: match.range(at: 1)) == "/"
        let name = source.substring(with: match.range(at: 2)).lowercased()
        let allowed = ["details", "summary", "br", "strong", "b", "em", "i", "s", "del", "code", "a"]
        guard allowed.contains(name) else { return DailyRadarMarkdownRenderer.escape(raw) }
        if closing { return name == "br" ? "" : "</\(name)>" }
        let body = source.substring(with: match.range(at: 3)) as NSString
        let values = attributes.matches(
            in: body as String, range: NSRange(location: 0, length: body.length)
        ).map { attribute -> (name: String, value: String?) in
            let name = body.substring(with: attribute.range(at: 1)).lowercased()
            let valueRange = (2...4).map { attribute.range(at: $0) }.first { $0.location != NSNotFound }
            return (name, valueRange.map { decoded(body.substring(with: $0)) })
        }
        if name == "details" {
            return values.contains(where: { $0.name == "open" }) ? "<details open>" : "<details>"
        }
        if name == "a" {
            let destinations = values.filter { $0.name == "href" }
            // 重复属性或危险协议降级成无跳转锚点，仍保留标题文字和正确的闭合结构。
            guard destinations.count == 1, let rawURL = destinations[0].value,
                  let url = DailyRadarMarkdownRenderer.safeURL(rawURL) else { return "<a>" }
            return "<a href=\"\(DailyRadarMarkdownRenderer.escape(url.absoluteString))\">"
        }
        return "<\(name)>"
    }

    /// 只解有限的标准实体；解码结果必须再次转义或校验 URL，绝不作为 HTML 直接输出。
    private static func decoded(_ value: String) -> String {
        let result = NSMutableString(string: value)
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}"]
        for match in entities.matches(in: value, range: NSRange(location: 0, length: result.length)).reversed() {
            let token = (value as NSString).substring(with: match.range)
            let name = String(token.dropFirst().dropLast()).lowercased()
            let replacement: String?
            if name.hasPrefix("#") {
                let hex = name.hasPrefix("#x")
                let digits = name.dropFirst(hex ? 2 : 1)
                replacement = UInt32(digits, radix: hex ? 16 : 10)
                    .flatMap(UnicodeScalar.init).map(String.init)
            } else {
                replacement = named[name]
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}
