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
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let content: String
    var citations: [RAGCitation] = []

    /// 展示规则固定且 `NSRegularExpression` 可安全复用。过去每次 SwiftUI 重绘都会重新编译
    /// 4 个正则；历史回答越多，流式父视图刷新带来的无效 CPU 越明显。
    private static let citationClusterRepoRegex = try! NSRegularExpression(
        pattern: #"((?:\[S\d+\])+)\s*([A-Za-z0-9][\w.-]*/[\w.-]+)"#
    )
    private static let numberedItemRegex = try! NSRegularExpression(
        pattern: #"([^\n])([：:。；;）\)])\s*(\d+\.\s+)"#
    )
    private static let tightNumberedListRegex = try! NSRegularExpression(
        pattern: #"([^\n])\n(\d+\.\s+)"#
    )
    private static let citationMarkerRegex = try! NSRegularExpression(
        pattern: #"\[(S\d+)\](?!\()"#
    )

    var body: some View {
        // 与详情页 AI 摘要同一条 MarkdownUI 路线，段落/列表间距由主题控制。
        //
        // 关键约束：这里故意不启 `.textSelection(.enabled)`。
        // macOS 上 textSelection 会把整段变成 I-beam，盖掉 AttributedString link
        // 自带的 pointing-hand；回答里的外链 / `[S1]` 引用点不开「可点」反馈。
        // 整段复制走消息底栏 CopyFeedbackButton，不依赖拖选。
        Markdown(Self.prepareForDisplay(content, citations: citations))
            .markdownTheme(ragAnswerTheme)
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
            regex: citationClusterRepoRegex,
            template: "$1\n\n$2"
        )
        // 非行首的编号项：`：1.` / `。2.` → 另起一段，便于 Markdown 识别为列表
        text = replace(
            in: text,
            regex: numberedItemRegex,
            template: "$1$2\n\n$3"
        )
        // 紧列表升松列表：单换行后的 `1.` → 双换行
        text = replace(
            in: text,
            regex: tightNumberedListRegex,
            template: "$1\n\n$2"
        )
        // 相邻 `[S1][S3]` 加空格，避免链接挤成一团
        text = text.replacingOccurrences(of: "][", with: "] [")
        return text
    }

    private static func replace(in text: String, regex: NSRegularExpression, template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// 把裸 `[S1]` 转成 Markdown 链接，交给上层 `openURL` → `openCitationLink` → 命中分片 popover。
    /// 已是 `[S1](...)` 形式的不二次改写，避免流式中间态或导出文案被破坏。
    static func linkifyCitations(in content: String, citations: [RAGCitation]) -> String {
        guard !citations.isEmpty else { return content }
        let byMarker = Dictionary(uniqueKeysWithValues: citations.map { ($0.marker, $0) })
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        var result = ""
        var lastEnd = content.startIndex
        for match in citationMarkerRegex.matches(in: content, range: nsRange) {
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
    private var ragAnswerTheme: Theme {
        Theme()
            .text {
                ForegroundColor(.primary)
                // MarkdownUI 使用自己的 FontProperties，不读取外层 SwiftUI font。
                // 必须在 theme 内显式绑定会话字号 token，完成态与流式冻结块才会真正跟随左栏标题。
                FontSize(interfaceScale.scaled(RAGConversationTypography.text.pointSize))
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
                // RAG 回答常包含 YAML / shell 片段；空 Theme 的 codeBlock 只有裸文本，
                // 会让 fenced code 看起来像普通段落。这里显式补齐容器和横向滚动。
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.15))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.92))
                            BackgroundColor(nil)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                )
                .markdownMargin(top: .em(0.35), bottom: .em(0.95))
            }
            // 默认 Theme 表格几乎无内边距 + 全网格描边，宽表/多列时贴边难读。
            // 对齐 DocC 横线分隔 + GitHub 内边距：表头加重、斑马纹、宽表可横向滚。
            .table { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        // 让表格按内容固有宽度布局；过宽时由外层横向滚动，不把列压扁。
                        .fixedSize(horizontal: true, vertical: true)
                        .markdownTableBorderStyle(
                            TableBorderStyle(
                                .horizontalBorders,
                                color: Color.secondary.opacity(0.35),
                                width: 0.5
                            )
                        )
                        .markdownTableBackgroundStyle(
                            .alternatingRows(
                                Color.clear,
                                Color.primary.opacity(0.04),
                                header: Color.primary.opacity(0.08)
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                        )
                }
                .markdownMargin(top: .em(0.25), bottom: .em(0.95))
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                        // 背景交给 tableBackgroundStyle，避免 Text 再铺一层抢斑马纹。
                        BackgroundColor(nil)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .relativeLineSpacing(.em(0.18))
            }
    }
}
