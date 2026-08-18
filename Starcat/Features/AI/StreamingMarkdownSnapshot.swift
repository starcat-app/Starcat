//
//  StreamingMarkdownSnapshot.swift
//  Starcat
//
//  AI 对话流式 Markdown 的轻量展示快照。
//
//  流式回答不能在每个 token 到达时把完整字符串重新交给 MarkdownUI。MarkdownUI
//  会重新 parse 全文并重建 block view tree，回答越长，单次更新成本越高。这里把已经
//  越过安全段落边界的前缀冻结为稳定 chunk，只让尚未闭合的尾部以普通 Text 展示。
//  流式结束后仍回到完整 Markdown 渲染，因此最终展示语义不受这个中间态优化影响。
//

import Foundation

/// 把 Provider 的高频文本 delta 合并成低频 UI 快照。
///
/// 完整文本始终保留在 `text`；节流只控制 SwiftUI 可观察状态的发布频率。配置有界展示
/// 时，`flush()` 仍只返回展示窗口，完成与落库路径必须读取 `text`，因此不会丢失内容。
struct StreamingTextPresentationBuffer: Sendable {
    private let throttleInterval: TimeInterval
    private let immediateCharacterCount: Int?
    private let maximumPresentedCharacterCount: Int?
    private var pendingCharacterCount = 0
    private var lastCommitAt: TimeInterval?
    private var presentedText = ""
    private var presentedCharacterCount = 0
    private var didTruncatePresentedText = false

    private(set) var text = ""

    init(
        throttleInterval: TimeInterval = 0.15,
        immediateCharacterCount: Int? = 256,
        maximumPresentedCharacterCount: Int? = nil
    ) {
        self.throttleInterval = max(0, throttleInterval)
        self.immediateCharacterCount = immediateCharacterCount.map { max(1, $0) }
        self.maximumPresentedCharacterCount = maximumPresentedCharacterCount.map { max(1, $0) }
    }

    /// 返回非 nil 表示本次应该把完整快照发布给 UI。首个 delta 立即发布，避免用户
    /// 在模型已经开始推理后仍只看到空白步骤。
    mutating func append(_ delta: String, now: TimeInterval) -> String? {
        guard !delta.isEmpty else { return nil }
        text.append(contentsOf: delta)
        pendingCharacterCount += delta.count
        appendToPresentedText(delta)

        guard lastCommitAt == nil
                || now - (lastCommitAt ?? now) >= throttleInterval
                || shouldCommitForPendingCharacterCount else {
            return nil
        }
        return commit(now: now)
    }

    /// 流结束、失败或取消前补发尚未展示的 delta；已经全部发布时不制造重复刷新。
    mutating func flush(now: TimeInterval) -> String? {
        guard pendingCharacterCount > 0 else { return nil }
        return commit(now: now)
    }

    private mutating func commit(now: TimeInterval) -> String {
        lastCommitAt = now
        pendingCharacterCount = 0
        guard maximumPresentedCharacterCount != nil else { return text }
        return didTruncatePresentedText ? "…\n" + presentedText : presentedText
    }

    private var shouldCommitForPendingCharacterCount: Bool {
        guard let immediateCharacterCount else { return false }
        return pendingCharacterCount >= immediateCharacterCount
    }

    /// RAG 的运行中 Think 只需要最近一小段作为视觉反馈。窗口在 append 时增量维护，
    /// 发布快照时不会再从持续增长的完整字符串尾部反复切片；`text` 仍保留完整内容，
    /// 供完成、取消、失败和落库路径使用。
    private mutating func appendToPresentedText(_ delta: String) {
        guard let maximumPresentedCharacterCount else { return }

        presentedText.append(contentsOf: delta)
        presentedCharacterCount += delta.count
        let overflow = presentedCharacterCount - maximumPresentedCharacterCount
        guard overflow > 0 else { return }

        let removalEnd = presentedText.index(presentedText.startIndex, offsetBy: overflow)
        presentedText.removeSubrange(..<removalEnd)
        presentedCharacterCount -= overflow
        didTruncatePresentedText = true
    }
}

/// 只按时间控制可观察状态的发布频率，不允许较大的网络批次绕过上限。
///
/// 首次更新立即提交；后续更新只有跨过最小间隔才提交。完整流内容由调用方独立累计，
/// 因此节流器只决定“何时刷新 UI”，不会决定“保留哪些数据”。
struct StreamingPresentationThrottle: Sendable {
    private let minimumInterval: TimeInterval
    private var lastCommitAt: TimeInterval?

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func shouldCommit(now: TimeInterval) -> Bool {
        if let lastCommitAt, now - lastCommitAt < minimumInterval {
            return false
        }
        lastCommitAt = now
        return true
    }
}

/// RAG 流式回答的 UI 发布上限。
///
/// 正文的稳定 Markdown chunk 使 15Hz 仍只重算当前尾部。`reasoningInterval` 留给主窗口
/// AI 对话的 Think buffer；知识库 RAG 运行中思考已改走 NSTextView 追加，不再按
/// 该频率发布 `executionSteps`。两者都禁止字符数旁路突破时间上限。
enum RAGStreamingPresentationCadence {
    static let answerInterval: TimeInterval = 1.0 / 15.0
    static let reasoningInterval: TimeInterval = 0.1
}

/// 主窗口 AI 对话中一次 Think 展示提交对应的状态。
///
/// `isStreaming` 只描述 reasoning 阶段：provider 明确结束 reasoning，或首个正文 delta
/// 到达后即变为 `false`，让 UI 自动折叠 Think；整个 assistant 回答仍可继续流式生成。
/// `revision` 专门用于滚动跟随，避免用增长文本作为 SwiftUI `onChange` 输入。
struct StreamingReasoningSnapshot: Equatable, Sendable {
    let text: String
    let isStreaming: Bool
    let startedAt: Date
    let completedAt: Date?
    let revision: Int
}

/// 协调主窗口 AI 对话的 reasoning 展示边界。
///
/// reasoning 期间复用 `StreamingTextPresentationBuffer` 降频；provider 的
/// `reasoningCompleted` 是首选完成边界，首个正文 delta 是兼容未发送该事件的兜底。
/// 两条路径都会强制 flush 并发布完成态；取消、失败或只有 reasoning 没有正文时，再由
/// `finish()` 无损收口。
struct StreamingReasoningPresentationBuffer: Sendable {
    private var textBuffer: StreamingTextPresentationBuffer
    private var reasoningCompleted = false
    private var completionPublished = false
    private var revision = 0
    let startedAt: Date
    private(set) var completedAt: Date?

    var text: String { textBuffer.text }

    init(
        startedAt: Date = .now,
        throttleInterval: TimeInterval = 0.15,
        immediateCharacterCount: Int = 256
    ) {
        self.startedAt = startedAt
        textBuffer = StreamingTextPresentationBuffer(
            throttleInterval: throttleInterval,
            immediateCharacterCount: immediateCharacterCount
        )
    }

    /// 用户发送后立即建立 Think 步骤，不能退回到与 RAG 无关的通用转圈占位。
    mutating func begin() -> StreamingReasoningSnapshot {
        makeSnapshot(text: "", isStreaming: true)
    }

    /// 首个 delta 立即展开 Think；后续只在时间或字符阈值满足时发布完整快照。
    mutating func append(_ delta: String, now: TimeInterval) -> StreamingReasoningSnapshot? {
        guard let presentedText = textBuffer.append(delta, now: now) else { return nil }
        if reasoningCompleted { completionPublished = true }
        return makeSnapshot(text: presentedText, isStreaming: !reasoningCompleted)
    }

    /// 明确的完成事件和首个正文 delta 共用此入口；重复调用不会制造额外 UI 刷新。
    mutating func completeReasoning(now: TimeInterval) -> StreamingReasoningSnapshot? {
        guard !reasoningCompleted else { return nil }
        reasoningCompleted = true
        completedAt = Date(timeIntervalSinceReferenceDate: now)
        return makeCompletionSnapshot(now: now)
    }

    /// 成功、取消或失败退出前补发尚未展示的 reasoning，并确保状态为已完成。
    mutating func finish(now: TimeInterval) -> StreamingReasoningSnapshot? {
        reasoningCompleted = true
        completedAt = completedAt ?? Date(timeIntervalSinceReferenceDate: now)
        return makeCompletionSnapshot(now: now)
    }

    private mutating func makeCompletionSnapshot(
        now: TimeInterval
    ) -> StreamingReasoningSnapshot? {
        // 即使已发布过完成态，也要先尝试 flush：极少数 Provider 可能在正文开始后
        // 继续送 reasoning delta，不能因此丢掉最后一小段。
        if let presentedText = textBuffer.flush(now: now) {
            completionPublished = true
            return makeSnapshot(text: presentedText, isStreaming: false)
        }
        guard !completionPublished else { return nil }
        completionPublished = true
        return makeSnapshot(text: textBuffer.text, isStreaming: false)
    }

    private mutating func makeSnapshot(
        text: String,
        isStreaming: Bool
    ) -> StreamingReasoningSnapshot {
        revision += 1
        return StreamingReasoningSnapshot(
            text: text,
            isStreaming: isStreaming,
            startedAt: startedAt,
            completedAt: isStreaming ? nil : completedAt,
            revision: revision
        )
    }
}

/// 一次流式 UI 提交对应的展示数据。
struct StreamingMarkdownSnapshot: Equatable, Sendable {
    let messageID: UUID
    let timestamp: Date
    let stableMarkdownChunks: [String]
    let liveTail: String
    let revision: Int

    var isEmpty: Bool {
        stableMarkdownChunks.isEmpty && liveTail.isEmpty
    }
}

/// 按稳定段落边界冻结 Markdown 前缀，避免完整文档在流式期间反复解析。
enum StreamingMarkdownChunker {
    /// chunk 不能太小，否则会制造大量 Markdown view；也不能太大，否则尾部纯文本区
    /// 会停留太久。约 700 字符通常能覆盖一个完整小节，同时把解析节点数控制在低位。
    static let preferredChunkLength = 700

    static func split(_ markdown: String, preferredChunkLength: Int = preferredChunkLength) -> (
        chunks: [String],
        tail: String
    ) {
        var assembler = StreamingMarkdownAssembler(preferredChunkLength: preferredChunkLength)
        assembler.append(markdown)
        return (assembler.stableMarkdownChunks, assembler.liveTail)
    }

    fileprivate static func openingFenceMarker(_ line: Substring) -> Character? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3, let first = trimmed.first,
              first == "`" || first == "~" else {
            return nil
        }
        return trimmed.prefix(while: { $0 == first }).count >= 3 ? first : nil
    }

    fileprivate static func isFenceLine(_ line: Substring, marker: Character) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3 else { return false }
        return trimmed.prefix(while: { $0 == marker }).count >= 3
    }
}

/// 真正用于生产流式链路的增量 assembler。
///
/// 它只扫描新收到的 delta；已经冻结的 chunk 不会因为后续 token 到达而重新切分或
/// 复制。`StreamingMarkdownChunker.split` 只是测试和一次性调用的便利包装。
struct StreamingMarkdownAssembler: Sendable {
    private let preferredChunkLength: Int
    private(set) var stableMarkdownChunks: [String] = []
    private var currentChunk = ""
    private var pendingLine = ""
    private var fence: Character?

    init(preferredChunkLength: Int = StreamingMarkdownChunker.preferredChunkLength) {
        self.preferredChunkLength = preferredChunkLength
    }

    var liveTail: String {
        currentChunk + pendingLine
    }

    mutating func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        pendingLine += delta

        while let newline = pendingLine.firstIndex(of: "\n") {
            let line = pendingLine[..<newline]
            processCompletedLine(line)
            pendingLine.removeSubrange(...newline)
        }
    }

    private mutating func processCompletedLine(_ line: Substring) {
        currentChunk += line
        currentChunk.append("\n")

        if let marker = fence {
            if StreamingMarkdownChunker.isFenceLine(line, marker: marker) {
                fence = nil
            }
        } else if let marker = StreamingMarkdownChunker.openingFenceMarker(line) {
            fence = marker
        }

        // 只在 fenced code block 外的空行冻结前缀。未来 token 不可能再改变空行
        // 之前的段落结构；代码围栏内的空行则必须保留在同一个 chunk 中。
        if fence == nil,
           line.allSatisfy({ $0 == " " || $0 == "\t" }),
           currentChunk.count >= preferredChunkLength {
            let chunk = currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                stableMarkdownChunks.append(chunk)
            }
            currentChunk.removeAll(keepingCapacity: true)
        }
    }
}
