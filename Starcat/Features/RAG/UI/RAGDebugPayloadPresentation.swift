//
//  RAGDebugPayloadPresentation.swift
//  Starcat
//
//  Debug payload 的后台展示快照。把大字符串整理和分块留在主线程之外，
//  让 Inspector 只按当前视口懒挂载小段文本。
//

import Foundation

/// 一次展开对应的不可变展示快照。`expansionID` 既可以是普通 event ID，
/// 也可以是 Repo Context 合并组的首个 event ID。
struct RAGDebugPayloadPresentation: Equatable, Sendable {
    struct Block: Equatable, Identifiable, Sendable {
        let eventID: UUID
        let chunks: [String]
        let rerankAppliedNotes: [String]

        var id: UUID { eventID }

        /// VStack 本身会在相邻 Text 之间形成新的行边界；非末块若已经以换行结尾，
        /// 展示时去掉这一枚换行，避免块边界把一个换行画成两行。原始 chunks 不变，
        /// 完整性校验和复制仍以逐字原文为准。
        func displayText(at index: Int) -> String {
            let chunk = chunks[index]
            guard index < chunks.index(before: chunks.endIndex),
                  chunk.last == "\n" else { return chunk }
            return String(chunk.dropLast())
        }
    }

    let expansionID: UUID
    let localeIdentifier: String
    let blocks: [Block]

    func block(for eventID: UUID) -> Block? {
        blocks.first { $0.eventID == eventID }
    }
}

/// 纯值构建器，可安全放进 detached task。正文按较小边界切开后，SwiftUI 不再需要
/// 在一次布局事务中处理完整 Prompt / XML / 模型返回。
enum RAGDebugPayloadPresentationBuilder {
    static let defaultMaximumChunkUTF8Bytes = 2 * 1_024

    static func make(
        expansionID: UUID,
        events: [RAGDebugEvent],
        localeIdentifier: String,
        maximumChunkUTF8Bytes: Int = defaultMaximumChunkUTF8Bytes
    ) -> RAGDebugPayloadPresentation {
        let blocks = events.map { event in
            RAGDebugPayloadPresentation.Block(
                eventID: event.id,
                chunks: chunks(
                    for: event.renderedPayload(),
                    maximumUTF8Bytes: maximumChunkUTF8Bytes
                ),
                rerankAppliedNotes: event.rerankPayload?.renderedAppliedNotes() ?? []
            )
        }
        return RAGDebugPayloadPresentation(
            expansionID: expansionID,
            localeIdentifier: localeIdentifier,
            blocks: blocks
        )
    }

    /// 保证所有 chunk 重新拼接后与原文逐字一致。优先在换行处分块；只有单行本身
    /// 超过上限时才按 Character 拆分，避免一个压缩 JSON / XML 行重新制造巨型 Text。
    static func chunks(for text: String, maximumUTF8Bytes: Int) -> [String] {
        precondition(maximumUTF8Bytes > 0)
        guard !text.isEmpty else { return [""] }

        var result: [String] = []
        var current = ""
        var currentUTF8Bytes = 0
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline.map { text.index(after: $0) } ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            let lineUTF8Bytes = line.utf8.count

            if lineUTF8Bytes > maximumUTF8Bytes {
                flush(&current, byteCount: &currentUTF8Bytes, into: &result)
                appendOversizedLine(
                    line,
                    maximumUTF8Bytes: maximumUTF8Bytes,
                    into: &result
                )
            } else if currentUTF8Bytes + lineUTF8Bytes > maximumUTF8Bytes {
                flush(&current, byteCount: &currentUTF8Bytes, into: &result)
                current = String(line)
                currentUTF8Bytes = lineUTF8Bytes
            } else {
                current.append(contentsOf: line)
                currentUTF8Bytes += lineUTF8Bytes
            }

            lineStart = lineEnd
        }

        flush(&current, byteCount: &currentUTF8Bytes, into: &result)
        return result
    }

    private static func appendOversizedLine(
        _ line: Substring,
        maximumUTF8Bytes: Int,
        into result: inout [String]
    ) {
        var chunk = ""
        var chunkUTF8Bytes = 0

        for character in line {
            let characterText = String(character)
            let characterUTF8Bytes = characterText.utf8.count
            if !chunk.isEmpty, chunkUTF8Bytes + characterUTF8Bytes > maximumUTF8Bytes {
                result.append(chunk)
                chunk = ""
                chunkUTF8Bytes = 0
            }
            chunk.append(character)
            chunkUTF8Bytes += characterUTF8Bytes
        }

        if !chunk.isEmpty {
            result.append(chunk)
        }
    }

    private static func flush(
        _ current: inout String,
        byteCount: inout Int,
        into result: inout [String]
    ) {
        guard !current.isEmpty else { return }
        result.append(current)
        current = ""
        byteCount = 0
    }
}
