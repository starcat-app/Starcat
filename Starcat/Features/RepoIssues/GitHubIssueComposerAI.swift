//
//  GitHubIssueComposerAI.swift
//  Starcat
//
//  新建 Issue 的 AI 生成上下文打包与请求构造（2026-11-01 dong4j 需求）。
//
//  交互契约：用户先按自己的理解写一段粗略描述 → ✨ AI 生成完善且规范的 Issue 正文。
//  若仓库有 Issue 模板（.md 传统模板 / .yml 表单定义），AI 必须按最匹配的模板结构生成。
//
//  关键约束：
//  - 走与通知评论框同一 Chat 任务与门禁（`ensureGitHubCommentReady`：Pro / 本地 AI），
//    `disableThinking` 同款关闭。
//  - 输出语言跟用户的粗略描述走（NL 检测，同评论框的语种判定工具）——在谁的仓库
//    用谁社区的语言提问。
//  - 只生成「描述正文」，标题保持用户输入不动（AI 保守策略：AI 给建议，用户确认后提交）。
//  - Prompt 本文件内联（v1 不进 AIDefaultPrompts 设置目录，避免动设置 schema）。
//

import Foundation
import NaturalLanguage

/// Issue 生成的输入快照。生成期间用户继续改草稿也不会偷换上下文。
struct GitHubIssueComposerPack: Equatable, Sendable {
    var outputLanguage: String
    var repositoryFullName: String
    var primaryLanguage: String?
    var titleDraft: String
    var userDescription: String
    /// 仓库 Issue 模板原文；空数组 = 仓库未提供模板。
    var templates: [GitHubIssueTemplate]

    var hasDescription: Bool {
        !userDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum GitHubIssueComposerAI {

    /// 输出语言跟用户的粗略描述走（NL 检测；不确定回退 English）。
    static func outputLanguage(forDescription text: String) -> String {
        GitHubNotificationCommentAI.outputLanguage(forThread: text)
    }

    static func makeRequest(
        pack: GitHubIssueComposerPack,
        model: String,
        parameters: AIModelParameters
    ) -> AIChatRequest {
        AIChatRequest(
            systemPrompt: Self.systemPrompt(outputLanguage: pack.outputLanguage),
            userPrompt: Self.userPrompt(pack: pack),
            model: model,
            parameters: parameters,
            responseFormat: .text,
            usageContext: AIUsageContext(feature: .repoChat, phase: "github_issue_compose"),
            disableThinking: true
        )
    }

    /// 模型偶尔把整段正文包进 ``` 围栏；复用评论框的剥离逻辑。
    static func sanitizeIssueDraft(_ raw: String) -> String {
        GitHubNotificationCommentAI.sanitizeComment(raw)
    }

    // MARK: - Prompt（v1 内联，不进 AIDefaultPrompts 设置目录）

    private static func systemPrompt(outputLanguage: String) -> String {
        [
            "You are a GitHub issue writing assistant. Turn the user's rough description into a",
            "complete, well-structured, ready-to-submit GitHub issue body in Markdown.",
            "Write the entire output in \(outputLanguage).",
            "Output ONLY the issue body Markdown — no greetings, no explanations, no code fences",
            "around the whole answer. Keep every concrete fact the user provided; do not invent",
            "details they did not mention.",
        ]
        .joined(separator: " ")
    }

    private static func userPrompt(pack: GitHubIssueComposerPack) -> String {
        var lines: [String] = []
        lines.append("Repository: \(pack.repositoryFullName)")
        if let language = pack.primaryLanguage, !language.isEmpty {
            lines.append("Primary language: \(language)")
        }
        let title = pack.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Title (for reference, do not repeat it inside the body): \(title.isEmpty ? "(empty)" : title)")
        lines.append("User's rough description:")
        let description = pack.userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(description.isEmpty ? "(empty)" : pack.userDescription)

        if pack.templates.isEmpty {
            lines.append(
                "The repository has no issue template. Use a conventional bug-report / feature-request "
                + "structure that fits the description (e.g. Background, Steps to reproduce, "
                + "Expected behavior, Actual behavior, Environment)."
            )
        } else {
            lines.append(
                "Repository issue templates (choose the one that best matches the description "
                + "and strictly follow its section structure; keep its headings):"
            )
            for template in pack.templates {
                lines.append("--- Template: \(template.name) ---")
                lines.append(template.content)
            }
        }
        lines.append("Now write the issue body.")
        return lines.joined(separator: "\n\n")
    }
}
