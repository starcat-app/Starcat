//
//  GitHubNotificationIssueSummarySession.swift
//  Starcat
//
//  单个 Issue 的进程内总结会话。页面只持有此对象的引用，面板收起或切帖不会
//  中断生成；高频正文留在普通 buffer，仅向独立正文子视图低频发布 Markdown 快照。
//

import Foundation
import Observation

/// 独立于面板生命周期的生成会话；所有读写在 MainActor 串行完成。
@MainActor
@Observable
final class GitHubNotificationIssueSummarySession {
    /// 回调必须是真正的新片段。旧 generateText 的 onDelta 是全文快照，不能接到 append。
    typealias Generator = @MainActor (String, @escaping @MainActor (String) -> Void) async throws -> String

    /// 整文只在终态进入可观察状态，供一次完整 Markdown 排版与文本选择。
    private(set) var completedMarkdown = ""
    private(set) var streamingPresentation: StreamingMarkdownSnapshot?
    private(set) var isGenerating = false
    private(set) var hasContent = false
    private(set) var wasInterrupted = false
    private(set) var errorMessage: String?
    private(set) var needsSettings = false
    private(set) var context: GitHubNotificationIssueSummary.Context?
    /// 最近一次成功总结的时刻；磁盘恢复的会话携带快照时间，供 footer 展示。
    private(set) var generatedAt: Date?

    /// 生成成功后的落盘回调，由 Store 注入真实缓存（测试可置 nil 保持密闭）。
    @ObservationIgnored var persistenceHook: (@MainActor (Source, GitHubNotificationIssueSummary.Context, String, Date) -> Void)?

    @ObservationIgnored private var source: Source?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationID: UUID?
    @ObservationIgnored private var markdownBuffer = GitHubNotificationIssueSummaryMarkdownBuffer()
    @ObservationIgnored private var presentationTask: Task<Void, Never>?

    /// 复制与测试读取完整真源；此字段不随 token 触发 SwiftUI 整文更新。
    var markdown: String { markdownBuffer.text }

    /// 准备上下文也属于已经启动；此时 context 尚未回到主线程，重开面板不能再发一轮。
    var hasStarted: Bool { source != nil }

    /// 再次打开已有任务或结果时只恢复展示；只有显式重试 / 重新总结才调用本方法。
    /// 同一会话运行中重复调用是 no-op，避免连续点击产生重复付费请求。
    func start(
        title: String,
        payload: ActivityNotificationPayload,
        timeline: [GitHubNotificationIssueTimelineItem],
        language: String,
        generator: @escaping Generator
    ) {
        guard !isGenerating else { return }
        let requestedSource = Source(title: title, payload: payload, timeline: timeline, language: language)
        source = requestedSource
        context = nil
        presentationTask?.cancel()
        presentationTask = nil
        markdownBuffer = GitHubNotificationIssueSummaryMarkdownBuffer()
        streamingPresentation = nil
        completedMarkdown = ""
        hasContent = false
        wasInterrupted = false
        errorMessage = nil
        needsSettings = false
        generatedAt = nil
        isGenerating = true
        let requestID = UUID()
        generationID = requestID
        generationTask = Task { @MainActor in
            do {
                // 长讨论的裁剪、排序与 JSON 编码曾实测占用约 32ms；必须离开 MainActor，
                // 而非仅 yield 后继续在主线程做 CPU 工作，否则开窗动画首帧仍会被阻塞。
                let snapshot = await Self.prepareContext(source: requestedSource)
                guard generationID == requestID, !Task.isCancelled else { return }
                context = snapshot
                let result = try await generator(snapshot.text) { [weak self] delta in
                    guard let self, self.generationID == requestID, !Task.isCancelled else { return }
                    self.appendMarkdown(delta, requestID: requestID)
                    // 只在首个可见片段到达时更新通用状态；正文 revision 的观察止于独立子视图。
                    if !self.hasContent && !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.hasContent = true
                    }
                }
                guard generationID == requestID, !Task.isCancelled else { return }
                markdownBuffer.reconcileFinalText(result)
                flushMarkdownPresentation()
                completedMarkdown = markdownBuffer.text
                hasContent = !markdownBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                isGenerating = false
                generationTask = nil
                generationID = nil
                // 只有成功完成才落盘；中断 / 失败的半截正文不能伪装成「上次总结」。
                if hasContent, let source, let context {
                    let finishedAt = Date()
                    generatedAt = finishedAt
                    persistenceHook?(source, context, markdownBuffer.text, finishedAt)
                }
            } catch {
                guard generationID == requestID, !Task.isCancelled else { return }
                flushMarkdownPresentation()
                completedMarkdown = markdownBuffer.text
                isGenerating = false
                generationTask = nil
                generationID = nil
                let friendly = UserFacingError.map(
                    error,
                    operation: String.l10n("activity.issueSummary.action"),
                    service: "AI",
                    impact: .blocked, summary: .aiUnavailable
                )
                friendly.record(category: "ai", operation: "notification.issue.summary", service: "ai-provider")
                errorMessage = friendly.message
                needsSettings = notificationAIErrorNeedsSettings(error)
            }
        }
    }

    /// 仅接收 / 返回 Sendable 值快照，不读写会话状态或任何 TextKit / SwiftUI 对象。
    /// @concurrent 明确在并发执行器完成纯 CPU 准备，调用者负责恢复后校验请求身份。
    @concurrent
    private static func prepareContext(source: Source) async -> GitHubNotificationIssueSummary.Context {
        GitHubNotificationIssueSummary.makeContext(
            title: source.title,
            payload: source.payload,
            timeline: source.timeline
        )
    }

    /// 只有明确点击停止或账号失效才取消；取消前失效请求身份，晚到片段不能污染重试。
    func stop() {
        generationID = nil
        generationTask?.cancel()
        generationTask = nil
        flushMarkdownPresentation()
        completedMarkdown = markdownBuffer.text
        if isGenerating { wasInterrupted = true }
        isGenerating = false
    }

    /// 比较完整资料快照，而非已经裁剪的 prompt，避免被省略部分更新后仍误显示“最新”。
    func matchesSource(
        title: String,
        payload: ActivityNotificationPayload,
        timeline: [GitHubNotificationIssueTimelineItem],
        language: String
    ) -> Bool {
        source == Source(title: title, payload: payload, timeline: timeline, language: language)
    }

    /// 账号作用域变化后同时清掉旧文字；已挂载的旧面板也不能继续显示前一账号的缓存。
    func discard() {
        stop()
        markdownBuffer = GitHubNotificationIssueSummaryMarkdownBuffer()
        streamingPresentation = nil
        completedMarkdown = ""
        source = nil
        context = nil
        hasContent = false
        wasInterrupted = false
        errorMessage = nil
        needsSettings = false
        generatedAt = nil
    }

    /// 从磁盘快照恢复上次成功总结。只在会话仍为空时生效：用户点开面板瞬间可能
    /// 已触发新一轮生成，晚到的恢复不得覆盖进行中的任务。
    /// context 只回放统计位（评论数 / 事件数 / 截断标记），prompt 全文恢复不了也不需要。
    func restore(from snapshot: IssueSummaryCacheSnapshot) {
        guard source == nil, !isGenerating, !hasContent else { return }
        source = Source(
            title: snapshot.title,
            payload: snapshot.payload,
            timeline: snapshot.timeline,
            language: snapshot.language
        )
        context = GitHubNotificationIssueSummary.Context(
            text: "",
            includedCommentCount: snapshot.contextStats.includedCommentCount,
            availableCommentCount: snapshot.contextStats.availableCommentCount,
            includedEventCount: snapshot.contextStats.includedEventCount,
            availableEventCount: snapshot.contextStats.availableEventCount,
            isTruncated: snapshot.contextStats.isTruncated
        )
        markdownBuffer = GitHubNotificationIssueSummaryMarkdownBuffer()
        markdownBuffer.reconcileFinalText(snapshot.markdown)
        if let restoredSnapshot = markdownBuffer.flush() { streamingPresentation = restoredSnapshot }
        completedMarkdown = markdownBuffer.text
        hasContent = !markdownBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        wasInterrupted = false
        errorMessage = nil
        needsSettings = false
        generatedAt = snapshot.generatedAt
    }

    /// 原始 token 只进入非观察 buffer；大 burst 也不能越过 8Hz 的发布上限。
    private func appendMarkdown(_ delta: String, requestID: UUID) {
        if let snapshot = markdownBuffer.append(delta, now: Date.timeIntervalSinceReferenceDate) {
            streamingPresentation = snapshot
            presentationTask?.cancel()
            presentationTask = nil
        }
        guard markdownBuffer.hasPendingChanges, presentationTask == nil else { return }
        presentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(GitHubNotificationIssueSummaryMarkdownBuffer.presentationInterval))
            guard let self, !Task.isCancelled, self.generationID == requestID else { return }
            self.presentationTask = nil
            if let snapshot = self.markdownBuffer.publishIfDue(now: Date.timeIntervalSinceReferenceDate) {
                self.streamingPresentation = snapshot
            }
        }
    }

    /// 完成、失败、停止统一补齐尾片段并取消延迟任务；晚到定时回调也受请求身份保护。
    private func flushMarkdownPresentation() {
        presentationTask?.cancel()
        presentationTask = nil
        if let snapshot = markdownBuffer.flush() { streamingPresentation = snapshot }
    }

    /// 固定本轮输入来源与输出语言，不随页面当前选择偷偷切换。
    /// internal：持久化 hook 的签名由 Store 注入时引用；磁盘快照按字段平铺存储。
    struct Source: Equatable, Sendable {
        let title: String
        let payload: ActivityNotificationPayload
        let timeline: [GitHubNotificationIssueTimelineItem]
        let language: String
    }
}
