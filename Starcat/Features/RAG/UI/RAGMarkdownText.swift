//
//  RAGMarkdownText.swift
//  Starcat
//
//  RAG 回答 Markdown 的展示层格式化与引用链接化。
//

import AppKit
import Kingfisher
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
    /// 仅接受模型按 Prompt 输出的 `[owner/repo](https://github.com/owner/repo)`。
    /// 不扫描裸 `owner/repo`，避免把本地路径、包名或代码片段误当作仓库。
    private static let canonicalGitHubRepositoryLinkRegex = try! NSRegularExpression(
        pattern: #"(?<!\!)\[([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9][A-Za-z0-9_.-]*)\]\((https?://[^\s)]+)\)"#
    )

    var body: some View {
        // 与详情页 AI 摘要同一条 MarkdownUI 路线，段落/列表间距由主题控制。
        //
        // 关键约束：这里故意不启 `.textSelection(.enabled)`。
        // macOS 上 textSelection 会把整段变成 I-beam，盖掉 AttributedString link
        // 自带的 pointing-hand；回答里的外链 / `[S1]` 引用点不开「可点」反馈。
        // 整段复制走消息底栏 CopyFeedbackButton，不依赖拖选。
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(RAGMarkdownTableParser.split(content).enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let markdown):
                    markdownView(markdown)
                case .table(let rawMarkdown):
                    VStack(alignment: .trailing, spacing: 4) {
                        CopyFeedbackButton(
                            providesContent: { rawMarkdown },
                            tooltip: "rag.workspace.table.copy"
                        ) { didCopy in
                            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(interfaceScale.font(size: 12, weight: .medium))
                                .foregroundStyle(didCopy ? Color.green : .secondary)
                                .frame(width: 20, height: 20)
                        }
                        markdownView(rawMarkdown)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func markdownView(_ markdown: String) -> some View {
        Markdown(Self.prepareForDisplay(markdown, citations: citations))
            .markdownTheme(ragAnswerTheme)
            .markdownInlineImageProvider(
                RAGRepositoryAvatarInlineImageProvider(
                    displaySize: interfaceScale.scaled(14)
                )
            )
    }

    /// 仅影响展示：松散段落 → 链接化引用；不改会话持久化原文。
    static func prepareForDisplay(_ content: String, citations: [RAGCitation]) -> String {
        let citationLinked = linkifyCitations(in: loosenBlockSpacing(content), citations: citations)
        return addRepositoryAvatars(to: citationLinked)
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

    /// 为可确认的 GitHub 仓库链接增加 owner avatar。
    ///
    /// 图标由本地受控的 `starcat-rag-avatar` scheme 驱动，模型无法指定远程图片地址；
    /// 渲染器再复用 `RemoteAvatar` 的 Kingfisher 内存/磁盘缓存。GitHub 链接仍保留原 URL，
    /// 因此 `KnowledgeRAGWorkspaceViewModel.handleLink(_:)` 可以保持“本地详情优先”的既有分流。
    static func addRepositoryAvatars(to content: String) -> String {
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        var result = ""
        var lastEnd = content.startIndex

        for match in canonicalGitHubRepositoryLinkRegex.matches(in: content, range: range) {
            guard
                let fullRange = Range(match.range, in: content),
                let ownerRange = Range(match.range(at: 1), in: content),
                let repositoryRange = Range(match.range(at: 2), in: content),
                let destinationRange = Range(match.range(at: 3), in: content)
            else {
                continue
            }

            let owner = String(content[ownerRange])
            let repository = String(content[repositoryRange])
            let destination = String(content[destinationRange])
            guard isCanonicalGitHubRepositoryURL(
                URL(string: destination),
                owner: owner,
                repository: repository
            ) else {
                continue
            }

            result += content[lastEnd..<fullRange.lowerBound]
            result += "[![\(owner) avatar](starcat-rag-avatar://\(owner))](\(destination)) [\(owner)/\(repository)](\(destination))"
            lastEnd = fullRange.upperBound
        }

        result += content[lastEnd...]
        return result
    }

    private static func isCanonicalGitHubRepositoryURL(
        _ url: URL?,
        owner: String,
        repository: String
    ) -> Bool {
        guard
            let url,
            let host = url.host?.lowercased(),
            host == "github.com" || host == "www.github.com"
        else {
            return false
        }

        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count == 2 else { return false }
        return path[0].caseInsensitiveCompare(owner) == .orderedSame
            && path[1].caseInsensitiveCompare(repository) == .orderedSame
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
                RAGCodeBlockView(
                    configuration: configuration,
                    interfaceScale: interfaceScale
                )
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

/// MarkdownUI 的行内图片会被合并进 `Text`，只能通过 `InlineImageProvider` 返回 `Image`。
/// 这里直接取 Kingfisher 缓存，避免错误地把受控 avatar scheme 交给默认网络加载器。
private struct RAGRepositoryAvatarInlineImageProvider: InlineImageProvider {
    let displaySize: CGFloat

    func image(with url: URL, label: String) async throws -> Image {
        guard
            url.scheme == "starcat-rag-avatar",
            let owner = url.host,
            !owner.isEmpty,
            let avatarURL = GitHubAvatarURL.imageURL(
                from: RepoAvatarURL.from(owner: owner),
                displayDiameter: displaySize
            )
        else {
            throw RAGRepositoryAvatarError.unsupportedURL
        }

        let avatar = try await retrieveAvatar(from: avatarURL)
        return Image(nsImage: circularThumbnail(avatar, size: displaySize))
    }

    private func retrieveAvatar(from url: URL) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            KingfisherManager.shared.retrieveImage(with: url) { result in
                continuation.resume(with: result.map(\.image))
            }
        }
    }

    /// 行内 `Image` 无法套 SwiftUI 的 `clipShape`；先压成透明圆形位图，才能和其他 owner avatar 保持一致。
    private func circularThumbnail(_ image: NSImage, size: CGFloat) -> NSImage {
        let thumbnail = NSImage(size: CGSize(width: size, height: size))
        thumbnail.lockFocus()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: thumbnail.size)).addClip()
        image.draw(
            in: NSRect(origin: .zero, size: thumbnail.size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
        thumbnail.unlockFocus()
        return thumbnail
    }
}

private enum RAGRepositoryAvatarError: Error {
    case unsupportedURL
}

/// MarkdownUI 直接提供 fenced code 的语言与原文，因此不需要重解析回答文本即可放置复制入口。
private struct RAGCodeBlockView: View {
    let configuration: CodeBlockConfiguration
    let interfaceScale: InterfaceScale

    private var language: String {
        let raw = configuration.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "TEXT" : raw.uppercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(language)
                    .font(interfaceScale.font(.captionSmall, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                CopyFeedbackButton(
                    providesContent: { configuration.content },
                    tooltip: "rag.workspace.code.copy"
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(interfaceScale.font(size: 12, weight: .medium))
                        .foregroundStyle(didCopy ? Color.green : .secondary)
                        .frame(width: 20, height: 20)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

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
        }
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
        )
        .markdownMargin(top: .em(0.35), bottom: .em(0.95))
    }
}

/// 只拆出标准 GFM 表格；其他内容继续整段交给 MarkdownUI，避免重新实现 Markdown 渲染器。
/// fenced code 内的 `|` 必须保留为代码，不能被误拆成可复制表格。
enum RAGMarkdownTableBlock: Equatable {
    case markdown(String)
    case table(String)
}

enum RAGMarkdownTableParser {
    static func split(_ markdown: String) -> [RAGMarkdownTableBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [RAGMarkdownTableBlock] = []
        var pendingLines: [String] = []
        var index = 0
        var activeFence: Character?

        func flushPending() {
            guard !pendingLines.isEmpty else { return }
            blocks.append(.markdown(pendingLines.joined(separator: "\n")))
            pendingLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            if let fence = fenceCharacter(in: line) {
                activeFence = activeFence == fence ? nil : fence
                pendingLines.append(line)
                index += 1
                continue
            }

            guard activeFence == nil,
                  index + 1 < lines.count,
                  isTableHeader(line),
                  isTableDelimiter(lines[index + 1])
            else {
                pendingLines.append(line)
                index += 1
                continue
            }

            flushPending()
            var tableLines = [line, lines[index + 1]]
            index += 2
            while index < lines.count, isTableRow(lines[index]) {
                tableLines.append(lines[index])
                index += 1
            }
            blocks.append(.table(tableLines.joined(separator: "\n")))
        }

        flushPending()
        return blocks
    }

    private static func fenceCharacter(in line: String) -> Character? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return "`" }
        if trimmed.hasPrefix("~~~") { return "~" }
        return nil
    }

    private static func isTableHeader(_ line: String) -> Bool {
        line.contains("|") && !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.contains("|") && !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.first == "|" { trimmed.removeFirst() }
        if trimmed.last == "|" { trimmed.removeLast() }

        let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let marker = cell.trimmingCharacters(in: .whitespaces)
            let hyphens = marker.filter { $0 == "-" }.count
            return hyphens >= 3 && marker.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}
