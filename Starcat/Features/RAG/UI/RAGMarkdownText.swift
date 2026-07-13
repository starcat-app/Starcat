//
//  RAGMarkdownText.swift
//  Starcat
//
//  RAG 回答 Markdown 的展示层格式化与引用链接化。
//

import AppKit
import MarkdownUI
import SwiftUI

struct RAGMarkdownText: View {
    let content: String
    var citations: [RAGCitation] = []

    var body: some View {
        // 与详情页 AI 摘要同一条 MarkdownUI 路线，段落/列表间距由主题控制。
        Markdown(Self.prepareForDisplay(content, citations: citations))
            .markdownTheme(Self.ragAnswerTheme)
            .textSelection(.enabled)
    }

    /// 仅影响展示：松散段落 → 链接化引用；不改会话持久化原文。
    static func prepareForDisplay(_ content: String, citations: [RAGCitation]) -> String {
        linkifyCitations(in: loosenBlockSpacing(content), citations: citations)
    }

    /// 模型常把多条仓库挤在同一段；展示层补换行，让编号项 / 下一仓库能成块阅读。
    static func loosenBlockSpacing(_ content: String) -> String {
        var text = content
        // 引用簇后紧贴 `owner/repo`：`][S3]dong4j/foo` → 换段
        text = replace(
            in: text,
            pattern: #"((?:\[S\d+\])+)\s*([A-Za-z0-9][\w.-]*/[\w.-]+)"#,
            template: "$1\n\n$2"
        )
        // 非行首的编号项：`：1.` / `。2.` → 另起一段，便于 Markdown 识别为列表
        text = replace(
            in: text,
            pattern: #"([^\n])([：:。；;）\)])\s*(\d+\.\s+)"#,
            template: "$1$2\n\n$3"
        )
        // 紧列表升松列表：单换行后的 `1.` → 双换行
        text = replace(
            in: text,
            pattern: #"([^\n])\n(\d+\.\s+)"#,
            template: "$1\n\n$2"
        )
        // 相邻 `[S1][S3]` 加空格，避免链接挤成一团
        text = text.replacingOccurrences(of: "][", with: "] [")
        return text
    }

    private static func replace(in text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// 把裸 `[S1]` 转成 Markdown 链接，交给上层 `openURL` → `openCitationLink`。
    /// 已是 `[S1](...)` 形式的不二次改写，避免流式中间态或导出文案被破坏。
    static func linkifyCitations(in content: String, citations: [RAGCitation]) -> String {
        guard !citations.isEmpty else { return content }
        let byMarker = Dictionary(uniqueKeysWithValues: citations.map { ($0.marker, $0) })
        guard let regex = try? NSRegularExpression(pattern: #"\[(S\d+)\](?!\()"#) else { return content }
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        var result = ""
        var lastEnd = content.startIndex
        for match in regex.matches(in: content, range: nsRange) {
            guard let fullRange = Range(match.range, in: content),
                  match.numberOfRanges >= 2,
                  let markerRange = Range(match.range(at: 1), in: content) else { continue }
            result += content[lastEnd..<fullRange.lowerBound]
            let marker = String(content[markerRange])
            if let citation = byMarker[marker] {
                result += "[\(marker)](starcat-rag://citation/\(citation.id.uuidString))"
            } else {
                result += content[fullRange]
            }
            lastEnd = fullRange.upperBound
        }
        result += content[lastEnd...]
        return result
    }
    /// RAG 回答专用主题：段落/列表更疏；每次构建避免 Theme 非 Sendable 静态存储告警。
    private static var ragAnswerTheme: Theme {
        Theme()
            .text {
                ForegroundColor(.primary)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                BackgroundColor(.secondary.opacity(0.12))
            }
            .link {
                ForegroundColor(.accentColor)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.22))
                    .markdownMargin(top: .zero, bottom: .em(0.95))
            }
            .list { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.2), bottom: .em(0.95))
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.45))
            }
            .codeBlock { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.15))
                    .markdownMargin(top: .em(0.35), bottom: .em(0.95))
            }
    }
}
