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

struct AIChatBubble: View, Equatable {

    let message: ChatMessage
    let onEditUserMessage: (String) -> Void
    @Environment(\.starcatReduceMotion) private var reduceMotion

    static func == (lhs: AIChatBubble, rhs: AIChatBubble) -> Bool {
        // action 始终路由到同一个窗口输入框，真正决定气泡是否需要重绘的只有消息值。
        lhs.message == rhs.message
    }

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

            userFooter
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// 用户消息操作行：修改、复制、时间戳全部贴齐气泡右边缘。
    /// 修改只回填输入框，由用户确认后再次发送；不直接重发，避免误触产生新请求。
    private var userFooter: some View {
        HStack(spacing: 6) {
            Button {
                onEditUserMessage(message.content)
            } label: {
                // 2026-06-15 13:42 dong4j 反馈把"编辑"图标从 `pencil` 改成 U-turn
                // 箭头 `arrow.uturn.backward`（macOS 系统经典"撤销 / 返回"图标,
                // 与"把历史问题回填到输入框重新编辑"的语义更贴合 —— pencil 更像
                // "原地编辑",U-turn 更像"回到上一步重写"）。
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("ai.assistant.chat.editQuestion.tooltip")

            CopyFeedbackButton(
                providesContent: { message.content },
                tooltip: "ai.assistant.chat.copyQuestion.tooltip"
            ) { didCopy in
                // 2026-06-15 13:12 dong4j 反馈"复制按钮点击后抖动 + 图标太细"：
                // 抖动根因 = `doc.on.doc`（瘦描边）和 `checkmark.circle.fill`（正圆）
                // 的 SF Symbol 内在宽高不一致,切换时 HStack 重新布局让 timestamp
                // 横向位置抖动 → 用固定 frame 锁死容器尺寸杜绝 layout 重排。
                //
                // 13:29 dong4j 反馈"图标大了"：13 → 11。
                // 13:37 dong4j 反馈"还要小"：11 → 9。
                // 13:42 dong4j 确认"太细"原本指的是**左边的编辑按钮 pencil**,不是复制按钮
                //   → 回退 medium weight,恢复 SF Symbol 默认 weight；保留 size 9 / frame 10×10
                //   （字号、防抖 frame 都是用户自己确认过的尺寸,与"太细"无关）。
                Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(didCopy ? Color.green : .secondary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .frame(width: 10, height: 10)
            }

            timestampLabel
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
                        Text("ai.assistant.chat.thinking")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // dong4j 2026-06-04 16:05 反馈：助手回复 Markdown 里若有 H1/H2
                    // 会与角色标头 `## 🤖 AI (HH:mm)` 撞同级。`MarkdownHeadingDemoter`
                    // 先扫一遍最高级别，仅当 ≤ H2 时整体平移到 H3 起步（≥ H3 原样
                    // 返回，不浪费 String 拷贝；流式中每个 token 重渲也只是几 KB
                    // markdown，O(n) 扫描完全可接受）。
                    RepoAISummaryMarkdownView(
                        markdown: MarkdownHeadingDemoter.demoteToH3(message.content)
                    )
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
                    isActive: !reduceMotion
                )
            Text("ai.assistant.chat.generating")
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
                tooltip: "ai.assistant.chat.copyReply.tooltip"
            ) { didCopy in
                // 与 userFooter 复制按钮规格保持一致：size 9 默认 weight / frame 10×10。
                // 详见 userFooter 注释（含 size 13 → 11 → 9 降档 + 13:42 weight 回退的反馈记录）。
                Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(didCopy ? Color.green : .secondary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .frame(width: 10, height: 10)
            }
        }
    }

    private var timestampLabel: some View {
        // 2026-06-14 D-31 follow-up：.tertiary → .secondary。
        // 浅色主题下 .tertiary 时间戳几乎不可读，与 D-31 全局对比度修正对齐。
        Text(message.timestamp, style: .time)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

#Preview("AIChatBubble") {
    VStack(spacing: 12) {
        AIChatBubble(message: ChatMessage(
            role: .user,
            content: "这个项目用什么语言？"
        ), onEditUserMessage: { _ in })
        AIChatBubble(message: ChatMessage(
            role: .assistant,
            content: "这是一段 **Markdown** 示例 — `swift` 代码：\n\n```swift\nlet x = 1\n```\n\n你可以继续追问。",
            isStreaming: false
        ), onEditUserMessage: { _ in })
        AIChatBubble(message: ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true
        ), onEditUserMessage: { _ in })
    }
    .padding(.vertical, 12)
    .frame(width: 720)
}
