//
//  AIChatBubble.swift
//  Starcat
//
//  详情页 AI 助手窗口里的一条聊天气泡（HOM-150）。
//
//  设计动机：
//  - User 与 Assistant 视觉差异化：user 走"右侧 + 紫蓝色填充 + 用户头像"，assistant 走
//    "左侧 + 无背景 + Starcat App Icon"，让用户一眼分辨方向，无需打 label。
//  - 身份标识对齐 RAG 工作台中栏：用户侧 RemoteAvatar，助手侧 NSApp.applicationIconImage。
//  - Assistant 文本走 MarkdownUI 渲染（代码块 / 列表 / 链接），与详情页 AI 摘要
//    一致；user 是纯文本，避免用户复制粘贴的代码片段被错误格式化。
//  - 流式中显示"…"指示，stream 结束就消失。
//
//  关键约束：
//  - 气泡最大宽度限制为 ~76%：避免一条短回复横拉整个窗口。
//  - 使用 `.textSelection(.enabled)` 让用户能复制聊天内容（与 Apple Messages 行为
//    对齐）。
//  - 头像仍占既有 26pt 槽位，避免只换图标时气泡布局跳动。
//

import AppKit
import SwiftUI

/// AI 对话消息头像尺寸：保持既有 26pt 槽位，避免气泡布局因换图标而跳动。
private enum AIChatAvatarMetrics {
    static let size: CGFloat = 26
    /// 与 RAG 工作台同比例圆角（20→5 ⇒ 26→~6.5），App Icon 用圆角矩形更自然。
    static let cornerRadius: CGFloat = 6.5
}

/// 助手侧 Starcat App Icon；完成态 / 流式态共用，避免两处 sparkles 残留分叉。
private struct AIStarcatAssistantAvatar: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: AIChatAvatarMetrics.size, height: AIChatAvatarMetrics.size)
            .clipShape(RoundedRectangle(cornerRadius: AIChatAvatarMetrics.cornerRadius, style: .continuous))
            .padding(.top, 2)
    }
}

struct AIChatBubble: View {

    let message: ChatMessage
    /// 当前登录用户 GitHub 头像 URL；未登录时 RemoteAvatar 走 fallback。
    let userAvatarURL: String?
    let onEditUserMessage: (String) -> Void
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 40)
                userBubble
            }
            .padding(.horizontal, 16)
        case .assistant:
            assistantBubble
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        }
    }

    // MARK: - 子视图

    /// 用户消息气泡：右对齐 + 紫蓝色填充；头像贴在气泡右侧（对齐 RAG 中栏）。
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // 头像只与问题气泡垂直居中，footer 单独铺在气泡下方。
            HStack(alignment: .center, spacing: 8) {
                Text(message.content)
                    .font(interfaceScale.font(.bodyEmphasis))
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

                userAvatar
            }

            userFooter
                // 给右侧头像让出宽度，让操作行贴齐气泡右缘而非头像右缘。
                .padding(.trailing, AIChatAvatarMetrics.size + 8)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var userAvatar: some View {
        RemoteAvatar(
            urlString: userAvatarURL,
            size: AIChatAvatarMetrics.size,
            showBorder: false
        )
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
                    .font(interfaceScale.font(.captionSmall))
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
                    .font(interfaceScale.font(.captionSmall))
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
    /// - 左侧 Starcat App Icon 保留（user / assistant 一眼可区分）；
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
        let reasoning = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                AIChatAssistantHeader(
                    startedAt: message.timestamp,
                    isStreaming: message.isStreaming,
                    completedAt: message.responseCompletedAt
                )
                if reasoning?.isEmpty == false || message.reasoningStartedAt != nil {
                    AIChatReasoningDisclosure(
                        content: reasoning ?? "",
                        isStreaming: message.isStreaming,
                        startedAt: message.reasoningStartedAt,
                        completedAt: message.reasoningCompletedAt
                    )
                }

                if !message.content.isEmpty {
                    // dong4j 2026-06-04 16:05 反馈：助手回复 Markdown 里若有 H1/H2
                    // 会与角色标头 `## 🤖 AI (HH:mm)` 撞同级。`MarkdownHeadingDemoter`
                    // 先扫一遍最高级别，仅当 ≤ H2 时整体平移到 H3 起步（≥ H3 原样
                    // 返回，不浪费 String 拷贝；流式中每个 token 重渲也只是几 KB
                    // markdown，O(n) 扫描完全可接受）。
                    RepoAISummaryMarkdownView(
                        markdown: MarkdownHeadingDemoter.demoteToH3(message.content)
                    )
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
                    .font(interfaceScale.font(.captionSmall))
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
            .font(interfaceScale.font(.captionSmall))
            .foregroundStyle(.secondary)
    }
}

/// 同一条 assistant 消息内的真实模型推理。只接收 provider 已公开的 reasoning stream，
/// 不把正文外的“加载提示”伪装成模型思考；流结束后自动折叠，正文始终保持可见。
private struct AIChatReasoningDisclosure: View {
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

    let content: String
    let isStreaming: Bool
    let startedAt: Date?
    let completedAt: Date?
    let allowsTextSelection: Bool
    @State private var isExpanded: Bool

    init(
        content: String,
        isStreaming: Bool,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        allowsTextSelection: Bool = true
    ) {
        self.content = content
        self.isStreaming = isStreaming
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.allowsTextSelection = allowsTextSelection
        _isExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    // 第二行复用首行头像的 26pt 槽位并居中：图标中心线必须对齐。
                    // 图标标准档为 14pt，满足状态辨识度且不超过首行 26pt App Icon。
                    Image(systemName: isStreaming ? "ellipsis.circle" : "checkmark.circle.fill")
                        .font(interfaceScale.font(size: 14, weight: .semibold))
                        .foregroundStyle(isStreaming ? Color.secondary : Color.green)
                        .symbolEffect(
                            .pulse,
                            options: .repeating,
                            isActive: isStreaming && !reduceMotion
                        )
                        .frame(width: AIChatAvatarMetrics.size, height: AIChatAvatarMetrics.size)
                    Text("ai.assistant.chat.reasoning.title")
                        .font(interfaceScale.font(.body, weight: .medium))
                        .foregroundStyle(.primary)
                    reasoningDuration
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isExpanded, !content.isEmpty {
                Group {
                    if allowsTextSelection {
                        Text(content).textSelection(.enabled)
                    } else {
                        // 流式可变文本不创建 SelectionOverlay，避免长 Think 的每次
                        // 快照都触发 AppKit 选择层和 SwiftUI AttributeGraph 重排。
                        Text(content)
                    }
                }
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 23)
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming { isExpanded = false }
        }
        .onChange(of: content) { _, updatedContent in
            // 发送瞬间先展示空的运行中步骤；首个 Think token 到达后与 RAG 一样展开内容。
            if isStreaming, !updatedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isExpanded = true
            }
        }
    }

    @ViewBuilder
    private var reasoningDuration: some View {
        if let startedAt {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let endedAt = completedAt ?? context.date
                let duration = max(0, endedAt.timeIntervalSince(startedAt))
                Text(String(
                    format: String.l10n("ai.assistant.chat.reasoning.duration.format"),
                    locale: locale,
                    duration
                ))
                .font(interfaceScale.font(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }
}

/// 流式阶段专用的助手气泡。
///
/// 与完成态 `AIChatBubble` 分开，原因是两者的性能约束不同：完成态只解析一次完整
/// Markdown；流式态把已冻结 chunk 各自解析一次，当前增长尾部使用普通 Text。父视图
/// 每次 revision 更新时，已有 chunk 通过 Equatable 跳过 body，避免全文重复 parse。
struct AIStreamingChatBubble: View {
    let snapshot: StreamingMarkdownSnapshot
    let reasoning: StreamingReasoningSnapshot?
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
                AIChatAssistantHeader(startedAt: snapshot.timestamp, isStreaming: true)
                // ViewModel 在发送瞬间就创建 snapshot，因此这里永远是同一个 Think 步骤，
                // 不再退回旧的 ProgressView + “思考中…”占位。
                AIChatReasoningDisclosure(
                    content: reasoning?.text ?? "",
                    isStreaming: reasoning?.isStreaming ?? true,
                    startedAt: reasoning?.startedAt,
                    completedAt: reasoning?.completedAt,
                    allowsTextSelection: false
                )

                if !snapshot.isEmpty {
                    ForEach(snapshot.stableMarkdownChunks.indices, id: \.self) { index in
                        StableStreamingMarkdownChunk(markdown: snapshot.stableMarkdownChunks[index])
                            .equatable()
                    }

                    if !snapshot.liveTail.isEmpty {
                        // 尾部结构仍可能被下一个 token 改写（代码围栏、列表、强调等），
                        // 中间态用纯文本换取稳定帧率；完成后整条消息恢复完整 Markdown。
                        Text(snapshot.liveTail)
                            .font(interfaceScale.font(.bodyEmphasis))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.horizontal, 16)
    }
}

/// 所有助手回复固定以此行开头；头像只属于第一行，不能把 Think 与正文压到头像右侧。
private struct AIChatAssistantHeader: View {
    let startedAt: Date
    let isStreaming: Bool
    var completedAt: Date?
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            AIStarcatAssistantAvatar()
            Text("Starcat")
                .font(interfaceScale.font(.body, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(isStreaming ? "ai.assistant.chat.processing" : "ai.assistant.chat.processed")
                .font(interfaceScale.font(.caption, weight: .medium))
                .foregroundStyle(.secondary)
            processingDuration
        }
    }

    @ViewBuilder
    private var processingDuration: some View {
        // 旧历史记录没有完成时间，但它们已不在流式回复；此时不能继续以当前时间累加耗时。
        if isStreaming || completedAt != nil {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let endedAt = completedAt ?? context.date
                let duration = max(0, endedAt.timeIntervalSince(startedAt))
                Text(String(
                    format: String.l10n("ai.assistant.chat.reasoning.duration.format"),
                    locale: locale,
                    duration
                ))
                .font(interfaceScale.font(.caption, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }
}

/// 已冻结 chunk 的输入一旦生成便不再变化，Equatable 可以阻止父流式气泡更新时重复解析。
private struct StableStreamingMarkdownChunk: View, Equatable {
    let markdown: String

    var body: some View {
        RepoAISummaryMarkdownView(markdown: MarkdownHeadingDemoter.demoteToH3(markdown))
    }
}

#Preview("AIChatBubble") {
    VStack(spacing: 12) {
        AIChatBubble(
            message: ChatMessage(
                role: .user,
                content: "这个项目用什么语言？"
            ),
            userAvatarURL: nil,
            onEditUserMessage: { _ in }
        )
        AIChatBubble(
            message: ChatMessage(
                role: .assistant,
                content: "这是一段 **Markdown** 示例 — `swift` 代码：\n\n```swift\nlet x = 1\n```\n\n你可以继续追问。",
                isStreaming: false
            ),
            userAvatarURL: nil,
            onEditUserMessage: { _ in }
        )
        AIChatBubble(
            message: ChatMessage(
                role: .assistant,
                content: "",
                isStreaming: true
            ),
            userAvatarURL: nil,
            onEditUserMessage: { _ in }
        )
    }
    .padding(.vertical, 12)
    .frame(width: 720)
}
