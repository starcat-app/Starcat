//
//  GitHubNotificationTranslation.swift
//  Starcat
//
//  通知详情（Issue / PR 对话）的翻译切段。
//
//  为什么独立于 README：
//  - README 从 WebView DOM 抽段，这里是 Markdown 评论卡片；
//  - 缓存必须按 threadId 隔离。若复用 owner/repo 目录，会覆盖该仓库 README 译文，
//    同仓库其它 Issue 也会互相踩。
//  - 分段 / 全文共用同一套 Markdown 切段；呈现和磁盘文件名（`.full` 后缀）走
//    ReadmeTranslationMode，不在这里再抽一套 text node。
//

import Foundation

enum GitHubNotificationTranslation {

    /// 磁盘缓存 owner。以下划线前缀避开真实 GitHub login。
    static let cacheOwner = "_starcat-inbox"

    /// 一条通知对话里的一块 Markdown（开贴或某条评论的一段）。
    struct Block: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case opening
            case comment(id: Int64)
        }

        let kind: Kind
        let index: Int
        let markdown: String
        /// 可送 AI 时才有。围栏代码为 nil。
        let segmentId: String?

        /// ForEach 必须用「评论 id + 段序」，不能只用 `index`。
        /// 多条评论各自第一段都是 0，撞 id 时 SwiftUI 只会更新最后一张卡。
        var id: String {
            if let segmentId { return segmentId }
            switch kind {
            case .opening:
                return "fence:o:\(index)"
            case .comment(let commentID):
                return "fence:c:\(commentID):\(index)"
            }
        }
    }

    struct Document: Equatable, Sendable {
        let sourceText: String
        let segments: [ReadmeSourceSegment]
        let blocks: [Block]
    }

    static func identity(threadId: String) -> String {
        "inbox:\(threadId)"
    }

    /// threadId 用作目录名：去掉 `/`，避免 path traversal。
    static func cacheRepo(threadId: String) -> String {
        let trimmed = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.replacingOccurrences(of: "/", with: "-")
        if safe.isEmpty || safe == "." || safe == ".." {
            return "unknown"
        }
        return safe
    }

    /// 按空行切段；``` 围栏整块保留，避免把代码拆进翻译请求。
    static func splitBlocks(_ markdown: String) -> [String] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var blocks: [String] = []
        var current: [String] = []
        var inFence = false

        func flush() {
            let joined = current.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(joined)
            }
            current = []
        }

        for line in normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    current.append(text)
                    flush()
                    inFence = false
                } else {
                    flush()
                    inFence = true
                    current.append(text)
                }
                continue
            }
            if inFence {
                current.append(text)
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else {
                current.append(text)
            }
        }
        flush()
        return blocks
    }

    static func isTranslatableBlock(_ markdown: String) -> Bool {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.hasPrefix("```")
    }

    static func makeDocument(
        opening: String?,
        comments: [GitHubNotificationComment]
    ) -> Document {
        var blocks: [Block] = []
        var segments: [ReadmeSourceSegment] = []

        func append(kind: Block.Kind, markdown: String) {
            let pieces = splitBlocks(markdown)
            for (index, piece) in pieces.enumerated() {
                let translatable = isTranslatableBlock(piece)
                let segmentId: String?
                if translatable {
                    let id = segmentID(kind: kind, index: index)
                    segmentId = id
                    segments.append(ReadmeSourceSegment(id: id, text: piece))
                } else {
                    segmentId = nil
                }
                blocks.append(Block(kind: kind, index: index, markdown: piece, segmentId: segmentId))
            }
        }

        if let opening, !opening.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(kind: .opening, markdown: opening)
        }
        for comment in comments {
            append(kind: .comment(id: comment.id), markdown: comment.body)
        }

        // opening 为空时不要先拼一个空串，否则 sourceText 以 `---` 开头，
        // 全文模式会把第一段对到空内容，后面的评论整体错位。
        var parts: [String] = []
        if let opening, !opening.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(opening)
        }
        parts.append(contentsOf: comments.map(\.body).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        let sourceText = parts.joined(separator: "\n\n---\n\n")
        return Document(sourceText: sourceText, segments: segments, blocks: blocks)
    }

    /// 卡片和工具栏必须用同一份 Document，按评论 id 切开对照。
    static func blocks(in document: Document, commentID: Int64) -> [Block] {
        document.blocks.filter { block in
            if case .comment(let id) = block.kind { return id == commentID }
            return false
        }
    }

    static func openingBlocks(in document: Document) -> [Block] {
        document.blocks.filter { $0.kind == .opening }
    }

    static func cardTranslations(
        for blocks: [Block],
        from rendered: [ReadmeRenderedTranslation]
    ) -> [ReadmeRenderedTranslation] {
        let translationsByID = Dictionary(
            rendered.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        return blocks.compactMap { block in
            block.segmentId.flatMap { translationsByID[$0] }
        }
    }

    static func preparedComments(_ comments: [GitHubNotificationComment]) -> [GitHubNotificationComment] {
        comments.map { comment in
            GitHubNotificationComment(
                id: comment.id,
                login: comment.login,
                body: GitHubNotificationMapper.prepareMarkdown(comment.body),
                htmlURL: comment.htmlURL,
                createdAt: comment.createdAt
            )
        }
    }

    static func translation(
        for segmentId: String,
        from rendered: [ReadmeRenderedTranslation]
    ) -> String? {
        rendered.first(where: { $0.id == segmentId })?.translatedText
    }

    private static func segmentID(kind: Block.Kind, index: Int) -> String {
        switch kind {
        case .opening:
            return "o:\(index)"
        case .comment(id: let id):
            return "c:\(id):\(index)"
        }
    }
}
