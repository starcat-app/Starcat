//
//  RepoAIChatViewModel.swift
//  Starcat
//
//  详情页 AI 助手窗口（HOM-150）里的"对话"段状态模型。
//
//  模块职责：
//  - 维护一组按时间顺序排列的 `ChatMessage`（用户 / 助手两类）；
//  - 把"用户发送 → 流式接收助手回答"的过程映射成可观察的 SwiftUI 状态；
//  - 与"AI 摘要"完全解耦：本 VM **不**承载摘要 / 标签推荐，那块仍由
//    `RepoAIInsightViewModel` 独立负责，避免重新生成摘要时把对话清空。
//
//  关键约束：
//  - 流式响应通过 `RepoAIInsightService.chatStream` 拉取增量；本 VM 在助手消息上
//    原地累积 partial content，让 UI 一帧一帧重绘出"打字机效果"。
//  - 发送中若收到第二次 send 请求要被拦截（`isSending` 守门），避免并发 stream
//    把回答串成两段错乱的内容。
//  - 历史只存在内存（@State 维度），关闭窗口即丢失；HOM-150 验收里这是有意为之，
//    避免第一版引入新表 / 迁移 / CloudKit 同步带来的复杂度。
//

import Foundation
import Observation

/// 详情页 AI 助手窗口里的一条聊天消息。
///
/// 同时承载"已完成"和"流式累积中"两种状态：
/// - 用户发送：构造一次后 `content` 不再变化；
/// - 助手回答：先以空 content 插入 messages 末尾，随后按 stream chunk 不断改写。
struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable, Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    /// 正文。助手消息在流式过程中会被不断改写。
    var content: String
    let timestamp: Date
    /// 流式生成是否还在进行。完成后置 false，UI 据此显示"光标 / 打字中"指示。
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
    }
}

@MainActor
@Observable
final class RepoAIChatViewModel {

    // MARK: - 可观察状态

    /// 完整对话记录。顺序：第一条最早，最后一条最新。
    private(set) var messages: [ChatMessage] = []

    /// 是否正在发送（含等待首个 token + 流式中）。
    private(set) var isSending: Bool = false

    /// 最近一次错误（非 nil 时 UI 渲染错误条）。
    private(set) var errorMessage: String?

    /// 输入框文本。@Observable 双向绑定 SwiftUI `TextField`。
    var inputText: String = ""

    // MARK: - 依赖

    private let service: RepoAIInsightService

    init(service: RepoAIInsightService) {
        self.service = service
    }

    // MARK: - 动作

    /// 发送当前 `inputText` 给 AI；流式累积助手回答。
    ///
    /// 流程：
    /// 1. 守门：去空白 + 拦截并发发送 → 直接 return；
    /// 2. 立刻把"用户消息"插到 messages 末尾，UI 一帧内就看见自己的话；
    /// 3. 插一条空的"助手消息"占位并 `isStreaming = true`；
    /// 4. 调 `service.chatStream` 拉增量，onDelta 回调里原地写助手消息的 content；
    /// 5. 流式结束（无论成功 / 失败）都翻 `isStreaming = false`，错误时把 errorMessage
    ///    赋值并把助手消息置为简短错误提示（不要让"思考中…"的占位永远卡在 UI 上）。
    ///
    /// 历史构造：剔除当前轮的 user / assistant 占位，剩下的就是要喂给模型的多轮上下文。
    func sendMessage(repo: Repo) async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }

        let userMessage = ChatMessage(role: .user, content: trimmed)
        let assistantPlaceholder = ChatMessage(role: .assistant, content: "", isStreaming: true)

        // 用历史（不含本轮新加的两条）拼 history。`sendMessage` 之前的 messages
        // 序列里只可能存在"已完成"消息（isStreaming = false），可以安全转换。
        let history = messages.map { message in
            AIChatMessage(
                role: message.role == .user ? .user : .assistant,
                content: message.content
            )
        }

        messages.append(userMessage)
        let assistantIndex = messages.count
        messages.append(assistantPlaceholder)

        inputText = ""
        isSending = true
        errorMessage = nil

        defer { isSending = false }

        do {
            let final = try await service.chatStream(
                for: repo,
                history: history,
                userMessage: trimmed
            ) { [weak self] partial in
                guard let self else { return }
                // chunk 回调可能在任意 stream tick 触发，但 @MainActor 已保证主线程。
                // 用 index 改写而不是替换整条消息，让 SwiftUI diff 只重绘 content。
                if self.messages.indices.contains(assistantIndex) {
                    self.messages[assistantIndex].content = partial
                }
            }

            if messages.indices.contains(assistantIndex) {
                messages[assistantIndex].content = final
                messages[assistantIndex].isStreaming = false
            }
        } catch {
            errorMessage = error.localizedDescription
            if messages.indices.contains(assistantIndex) {
                // 不留空占位（避免 UI 上看到一条"灰色光标但无文字"的助手消息）。
                let prefix = messages[assistantIndex].content
                messages[assistantIndex].content = prefix.isEmpty
                    ? "（生成失败：\(error.localizedDescription)）"
                    : prefix
                messages[assistantIndex].isStreaming = false
            }
        }
    }

    /// 显式清空错误条。
    func dismissError() {
        errorMessage = nil
    }

    /// 显式清空对话历史。
    ///
    /// 当前 UI 没有暴露入口，但保留方法供未来"重置对话"按钮 / 重启窗口时调用。
    func resetConversation() {
        guard !isSending else { return }
        messages.removeAll()
        errorMessage = nil
    }
}
