//
//  GitHubNotificationCommentAI.swift
//  Starcat
//
//  把一条 GitHub 通知会话收成评论模型的上下文，并构造关 thinking 的 Chat 请求。
//

import Foundation

/// Issue / PR 评论生成的输入快照。生成期间用户继续改草稿也不会偷换 thread。
struct GitHubNotificationCommentPack: Equatable, Sendable {
    var outputLanguage: String
    var subjectType: String
    var currentUserLogin: String
    var draft: String
    var thread: String

    var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 评论上下文打包。截断时保开帖和最近评论，丢掉最旧的中间段。
enum GitHubNotificationCommentAI {
    static let characterBudget = 12_000
    static let recentCommentLimit = 15
    static let olderCommentPreview = 200
    static let openingPostLimit = 4_000

    static func pack(
        title: String,
        payload: ActivityNotificationPayload,
        repo: Repo?,
        summaryMarkdown: String?,
        currentUserLogin: String,
        draft: String
    ) -> GitHubNotificationCommentPack {
        let thread = threadMarkdown(
            title: title,
            payload: payload,
            repo: repo,
            summaryMarkdown: summaryMarkdown
        )
        return GitHubNotificationCommentPack(
            outputLanguage: outputLanguage(forThread: languageSource(title: title, payload: payload)),
            subjectType: payload.subjectType.lowercased() == "pullrequest" ? "pull request" : "issue",
            currentUserLogin: currentUserLogin.nilIfBlank ?? "user",
            draft: draft,
            thread: thread
        )
    }

    /// 输出语言跟帖子走，不跟 App 显示语言，也不跟草稿语言。
    /// 检测文本必须是标题 / 开帖 / 评论，不能用带英文标签的打包 markdown。
    static func outputLanguage(forThread text: String) -> String {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else if CharacterSet.letters.contains(scalar) {
                latin += 1
            }
        }
        if cjk > 0, cjk * 3 >= latin {
            return "Simplified Chinese"
        }
        return "English"
    }

    static func makeRequest(
        pack: GitHubNotificationCommentPack,
        model: String,
        parameters: AIModelParameters
    ) -> AIChatRequest {
        let taskInstruction = pack.hasDraft
            ? "The user already started a draft. Improve, complete, and tighten it into a postable comment. Keep their intent. If the draft is in a different language from {outputLanguage}, translate the intent into {outputLanguage}."
            : "Write a new comment that fits the thread and the notification reason."
        return AIChatRequest(
            systemPrompt: AIDefaultPrompts.githubIssueComment.renderedSystemPrompt(placeholders: [
                "outputLanguage": pack.outputLanguage,
                "currentUser": pack.currentUserLogin
            ]),
            userPrompt: AIDefaultPrompts.githubIssueComment.renderedUserPrompt(placeholders: [
                "outputLanguage": pack.outputLanguage,
                "subjectType": pack.subjectType,
                "taskInstruction": taskInstruction,
                "currentUser": pack.currentUserLogin,
                "draft": pack.draft.nilIfBlank ?? "(empty)",
                "thread": pack.thread
            ]),
            model: model,
            parameters: parameters,
            responseFormat: .text,
            usageContext: AIUsageContext(feature: .repoChat, phase: "github_comment"),
            disableThinking: true
        )
    }

    static func sanitizeComment(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func threadMarkdown(
        title: String,
        payload: ActivityNotificationPayload,
        repo: Repo?,
        summaryMarkdown: String?
    ) -> String {
        var lines: [String] = []
        lines.append("Repository: \(payload.repositoryFullName)")
        if let language = repo?.language, !language.isEmpty {
            lines.append("Primary language: \(language)")
        }
        if let description = repo?.description, !description.isEmpty {
            lines.append("Description: \(clip(description, limit: 400))")
        }
        if let summary = summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("Cached AI summary: \(clip(summary, limit: 800))")
        }
        let number = payload.subjectNumber.map { "#\($0)" } ?? ""
        lines.append("Subject: \(payload.subjectType) \(number)".trimmingCharacters(in: .whitespaces))
        lines.append("Title: \(title)")
        lines.append("Notification reason: \(payload.reason)")
        if let author = payload.authorLogin, let excerpt = payload.excerpt, !excerpt.isEmpty {
            lines.append("")
            lines.append("Opening post by @\(author):")
            lines.append(clip(excerpt, limit: openingPostLimit))
        }

        let comments = payload.comments
        if !comments.isEmpty {
            lines.append("")
            lines.append("Comments (\(comments.count)):")
            lines.append(contentsOf: clippedComments(comments))
        }

        var text = lines.joined(separator: "\n")
        if text.count > characterBudget {
            text = clip(text, limit: characterBudget)
        }
        return text
    }

    /// 语言检测只看用户帖子，避免英文脚手架把短中文 Issue 判成 English。
    private static func languageSource(title: String, payload: ActivityNotificationPayload) -> String {
        var parts = [title]
        if let excerpt = payload.excerpt, !excerpt.isEmpty {
            parts.append(excerpt)
        }
        parts.append(contentsOf: payload.comments.map(\.body))
        return parts.joined(separator: "\n")
    }

    private static func clippedComments(_ comments: [GitHubNotificationComment]) -> [String] {
        let recentStart = max(0, comments.count - recentCommentLimit)
        var result: [String] = []
        for (index, comment) in comments.enumerated() {
            let body: String
            if index >= recentStart {
                body = comment.body
            } else {
                body = clip(comment.body, limit: olderCommentPreview)
            }
            result.append("- @\(comment.login): \(body)")
        }
        return result
    }

    private static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "…"
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x3040...0x30FF).contains(scalar.value)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
