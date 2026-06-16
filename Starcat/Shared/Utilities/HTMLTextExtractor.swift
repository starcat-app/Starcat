//
//  HTMLTextExtractor.swift
//  Starcat
//
//  Activity PR-3（2026-06-17）：从 HTML 片段提取纯文本，用于 announcement 卡片摘要。
//
//  设计：走 `NSAttributedString` HTML 解码（系统自带，不引第三方库）。
//  失败时原样返回输入（宁可显示带标签也不阻塞 feed）。
//

import Foundation

enum HTMLTextExtractor {

    /// 从 HTML 片段提取纯文本，可选截断到 `maxLength` 字符（超出加 `…`）。
    static func plainText(from html: String, maxLength: Int? = nil) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return html
        }
        var text = attributed.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let maxLength, text.count > maxLength {
            text = String(text.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
    }
}
