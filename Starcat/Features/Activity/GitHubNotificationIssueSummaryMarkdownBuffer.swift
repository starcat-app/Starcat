//
//  GitHubNotificationIssueSummaryMarkdownBuffer.swift
//  Starcat
//
//  Issue 总结的增量 Markdown 真源与展示节流。完整文本不进入 Observation，
//  已完成段落交给共享 assembler 冻结；只有当前尾部在低频快照中变化。
//

import Foundation

/// 纯值缓冲器，允许测试用确定时间验证 8Hz 边界，不依赖机器速度或实际 sleep。
struct GitHubNotificationIssueSummaryMarkdownBuffer {
    /// 遵守开发前问题清单 4.6 的正文上限；字符数或网络大批次都不能绕过该间隔。
    static let presentationInterval: TimeInterval = 0.125

    private let messageID = UUID()
    private let timestamp = Date()
    private var assembler = StreamingMarkdownAssembler(preferredChunkLength: 1)
    private var throttle = StreamingPresentationThrottle(
        minimumInterval: GitHubNotificationIssueSummaryMarkdownBuffer.presentationInterval
    )
    private var revision = 0
    /// 在发布时才喂给 assembler，避免细碎 token 反复扫描尚未换行的整段尾部。
    private var pendingMarkdown = ""
    private(set) var text = ""
    private(set) var hasPendingChanges = false

    /// 真增量始终保留；短总结也按完整段落冻结，不等待通用对话的 700 字符门槛。
    mutating func append(_ delta: String, now: TimeInterval) -> StreamingMarkdownSnapshot? {
        guard !delta.isEmpty else { return nil }
        text.append(contentsOf: delta)
        pendingMarkdown.append(contentsOf: delta)
        hasPendingChanges = true
        return publishIfDue(now: now)
    }

    /// 网络暂时停流时由单一延迟任务补发尾部，仍受相同时间闸门约束。
    mutating func publishIfDue(now: TimeInterval) -> StreamingMarkdownSnapshot? {
        guard hasPendingChanges, throttle.shouldCommit(now: now) else { return nil }
        return flush()
    }

    /// 终态必须无损收口，即使最后片段尚未跨过时间窗；已经发布过则不重复刷新。
    mutating func flush() -> StreamingMarkdownSnapshot? {
        guard hasPendingChanges else { return nil }
        assembler.append(pendingMarkdown)
        pendingMarkdown.removeAll(keepingCapacity: true)
        hasPendingChanges = false
        revision += 1
        return StreamingMarkdownSnapshot(
            messageID: messageID,
            timestamp: timestamp,
            stableMarkdownChunks: assembler.stableMarkdownChunks,
            liveTail: assembler.liveTail,
            revision: revision
        )
    }

    /// Provider 的 completed 可能补齐或修订正文；最终仅对齐一次，不能再次追加全文。
    mutating func reconcileFinalText(_ result: String) {
        guard result != text, result != text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if result.hasPrefix(text) {
            // 先前尚未发布的 delta 也在 pending 中；只补 completed 新增的后缀，不能丢尾或重复。
            pendingMarkdown.append(contentsOf: result.dropFirst(text.count))
        } else {
            assembler = StreamingMarkdownAssembler(preferredChunkLength: 1)
            pendingMarkdown = result
        }
        text = result
        hasPendingChanges = true
    }
}
