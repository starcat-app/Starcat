//
//  AIChatBubble.swift
//  Starcat
//
//  详情页 AI 助手窗口里的一条聊天气泡（HOM-150）。
//
//  设计动机：
//  - User 与 Assistant 视觉差异化：user 走"右侧 + 紫蓝色填充"，assistant 走
//    "左侧 + 卡片背景 + sparkles 头像"，让用户一眼分辨方向，无需打 label。
//  - Assistant 文本走 MarkdownUI 渲染（代码块 / 列表 / 链接），与详情页 AI 摘要
//    一致；user 是纯文本，避免用户复制粘贴的代码片段被错误格式化。
//  - 流式中显示"…"指示，stream 结束就消失。
//
//  关键约束：
//  - 气泡最大宽度限制为 ~76%：避免一条短回复横拉整个窗口。
//  - 使用 `.textSelection(.enabled)` 让用户能复制聊天内容（与 Apple Messages 行为
//    对齐）。
//

import SwiftUI

struct AIChatBubble: View {

    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            switch message.role {
            case .user:
                Spacer(minLength: 40)
                userBubble
            case .assistant:
                assistantAvatar
                assistantBubble
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 子视图

    /// 助手头像：sparkles + 紫蓝色背景，与窗口主入口的"AI"按钮视觉呼应。
    private var assistantAvatar: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(
                LinearGradient(
                    colors: [.purple.opacity(0.85), .blue.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
            .padding(.top, 2)
    }

    /// 用户消息气泡：右对齐 + 紫蓝色填充。
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.content)
                .font(.body)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [.purple.opacity(0.85), .blue.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            timestampLabel
        }
    }

    /// 助手消息气泡：左对齐 + **无背景** + Markdown 渲染（HOM-150 dong4j 2026-06-04
    /// 反馈：AI 回复不要加背景色，主题色由窗口承担，避免明暗主题切换时"卡片色"和
    /// 窗口色对不上）。
    ///
    /// 为了在没有 fill 的情况下保留"这是 AI 回复"的视觉锚点：
    /// - 左侧 sparkles 头像保留（user / assistant 一眼可区分）；
    /// - 头像与正文之间用 12pt 文字大小 + 行高自然撑出节奏；
    /// - 流式末尾仍保留"生成中…"小提示，让用户感知 token 还在流。
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                if message.content.isEmpty {
                    // 占位指示：避免气泡彻底空着像"什么都没发生"。
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("思考中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    RepoAISummaryMarkdownView(markdown: message.content)
                    if message.isStreaming {
                        // 流式末尾追加一个柔和的"光标在闪烁"提示。用图标而不是字符
                        // 是为了避免与 markdown 自身的句末符号混在一起。
                        HStack(spacing: 4) {
                            Image(systemName: "ellipsis")
                                .font(.caption2)
                            Text("生成中…")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)

            timestampLabel
        }
    }

    private var timestampLabel: some View {
        Text(message.timestamp, style: .time)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

#Preview("AIChatBubble") {
    VStack(spacing: 12) {
        AIChatBubble(message: ChatMessage(
            role: .user,
            content: "这个项目用什么语言？"
        ))
        AIChatBubble(message: ChatMessage(
            role: .assistant,
            content: "这是一段 **Markdown** 示例 — `swift` 代码：\n\n```swift\nlet x = 1\n```\n\n你可以继续追问。",
            isStreaming: false
        ))
        AIChatBubble(message: ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true
        ))
    }
    .padding(.vertical, 12)
    .frame(width: 720)
}
