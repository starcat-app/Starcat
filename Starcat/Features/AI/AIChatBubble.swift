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
    /// - 流式末尾仍保留"生成中"小动画，让用户感知 token 还在流。
    ///
    /// 时间戳右侧的复制按钮（HOM-150 dong4j 2026-06-04 15:13 反馈）：
    /// - 仅 assistant 气泡有（user 消息不需要）；
    /// - 流式中 / 内容为空时隐藏：避免复制到不完整的 Markdown；
    /// - 复用 `CopyFeedbackButton`，与摘要 header 复制按钮 / 对话底部"复制全部"
    ///   同款反馈（icon 切 ✓ + 绿色 + tooltip 切「已复制 ✓」+ 1.5s 复位）。
    ///
    /// HOM-150 dong4j 2026-06-04 15:48 反馈：
    /// - 旧版的"生成中…"是纯静态文本 + 静态 ellipsis icon，没有任何"正在
    ///   工作"的视觉提示，与用户对"流式 AI"的体感不符。改用 SF Symbol
    ///   `variableColor.iterative.dimInactiveLayers` 动效，三个点依次点亮，是
    ///   macOS / iOS 系统级标准的"正在处理"视觉语言（消息 App / 备忘录 etc）。
    /// - 时间戳"是生成完成后才应该显示的"——把 `assistantFooter` 整体在
    ///   流式期间不渲染，等 `isStreaming == false` 才出现 timestamp + 复制按钮。
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                if message.content.isEmpty {
                    // 占位指示：首个 token 还没到。ProgressView 自带旋转动画，
                    // 已足够传达"在思考"，配文字辅助语义即可。
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("思考中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    RepoAISummaryMarkdownView(markdown: message.content)
                    if message.isStreaming {
                        streamingIndicator
                    }
                }
            }
            .padding(.vertical, 2)

            // 流式中故意不渲染 footer：dong4j 2026-06-04 15:48 明确要求"时间戳
            // 是生成完成后才应该显示的"。空内容期间也不需要 footer（连 timestamp
            // 都没意义），同样不渲染。
            if !message.isStreaming, !message.content.isEmpty {
                assistantFooter
            }
        }
    }

    /// 流式输出过程中的"正在生成"动画。
    ///
    /// 使用 SF Symbol `variableColor.iterative.dimInactiveLayers`：
    /// - `iterative`：三个点依次按顺序点亮（不是同时脉冲），节奏感更像"打字"；
    /// - `dimInactiveLayers`：未点亮的点降低透明度而非完全隐藏，避免"消失—出现"
    ///   闪烁；
    /// - `options: .repeating`：持续循环到 view 消失（流式停后 `isStreaming = false`
    ///   触发 view diff，此节点被移除，动画随之停止）。
    /// 紫色与窗口顶部的"AI"按钮 / 头像渐变同色系，强化"这是 AI 在说话"。
    private var streamingIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.purple.opacity(0.85))
                .symbolEffect(
                    .variableColor.iterative.dimInactiveLayers,
                    options: .repeating,
                    isActive: true
                )
            Text("生成中")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 助手气泡底部行：时间戳 + 复制按钮。
    ///
    /// 仅在流式结束、且有内容时由 `assistantBubble` 渲染。本方法内不再做
    /// 状态门控（dong4j 2026-06-04 15:48 调整：原来在这里二次判定 isStreaming
    /// 控制复制按钮显隐，现在整个 footer 都不渲染了，状态判断上提一层即可）。
    private var assistantFooter: some View {
        HStack(spacing: 6) {
            timestampLabel
            CopyFeedbackButton(
                providesContent: { message.content },
                tooltip: "复制此回复 Markdown 到剪贴板"
            ) { didCopy in
                Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(didCopy ? Color.green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
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
