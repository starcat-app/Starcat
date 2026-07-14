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
/// 完整文本始终保留在 `text`；节流只控制 SwiftUI 可观察状态的发布频率，结束时调用
/// `flush()` 即可补上最后一小段。因此性能保护不会截断 Think，也不会改变最终落库内容。
struct StreamingTextPresentationBuffer: Sendable {
    private let throttleInterval: TimeInterval
    private let immediateCharacterCount: Int
    private var pendingCharacterCount = 0
    private var lastCommitAt: TimeInterval?

    private(set) var text = ""

    init(throttleInterval: TimeInterval = 0.15, immediateCharacterCount: Int = 256) {
        self.throttleInterval = max(0, throttleInterval)
        self.immediateCharacterCount = max(1, immediateCharacterCount)
    }

    /// 返回非 nil 表示本次应该把完整快照发布给 UI。首个 delta 立即发布，避免用户
    /// 在模型已经开始推理后仍只看到空白步骤。
    mutating func append(_ delta: String, now: TimeInterval) -> String? {
        guard !delta.isEmpty else { return nil }
        text.append(contentsOf: delta)
        pendingCharacterCount += delta.count

        guard lastCommitAt == nil
                || now - (lastCommitAt ?? now) >= throttleInterval
                || pendingCharacterCount >= immediateCharacterCount else {
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
        return text
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
