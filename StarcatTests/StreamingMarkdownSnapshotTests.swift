//
//  StreamingMarkdownSnapshotTests.swift
//  StarcatTests
//
//  锁住流式 Markdown 分块边界：稳定前缀可冻结，未闭合代码块和短尾部必须保留
//  为纯文本，避免中间态 Markdown 解析改变仍在增长的结构。
//

import Testing
@testable import Starcat

@Suite("StreamingMarkdownChunker")
struct StreamingMarkdownSnapshotTests {
    @Test("短回答全部保留在 live tail")
    func shortAnswerStaysInTail() {
        let result = StreamingMarkdownChunker.split("hello **world**", preferredChunkLength: 20)

        #expect(result.chunks.isEmpty)
        #expect(result.tail == "hello **world**")
    }

    @Test("达到阈值后只在空行冻结稳定前缀")
    func freezesAtBlankLine() {
        let input = "first paragraph long enough\n\nsecond paragraph"
        let result = StreamingMarkdownChunker.split(input, preferredChunkLength: 10)

        #expect(result.chunks == ["first paragraph long enough"])
        #expect(result.tail == "second paragraph")
    }

    @Test("未闭合 fenced code block 不被冻结")
    func openFenceStaysInTail() {
        let input = "```swift\nlet value = 1\n\nstill code"
        let result = StreamingMarkdownChunker.split(input, preferredChunkLength: 5)

        #expect(result.chunks.isEmpty)
        #expect(result.tail == input)
    }

    @Test("代码围栏闭合后的空行允许冻结")
    func closedFenceCanFreeze() {
        let input = "```swift\nlet value = 1\n```\n\nnext"
        let result = StreamingMarkdownChunker.split(input, preferredChunkLength: 5)

        #expect(result.chunks == ["```swift\nlet value = 1\n```"])
        #expect(result.tail == "next")
    }

    @Test("多个稳定 chunk 的边界随追加内容保持不变")
    func chunkBoundariesRemainStable() {
        let first = StreamingMarkdownChunker.split("section one content\n\nsection two", preferredChunkLength: 8)
        let second = StreamingMarkdownChunker.split(
            "section one content\n\nsection two content\n\nsection three",
            preferredChunkLength: 8
        )

        #expect(first.chunks.first == second.chunks.first)
        #expect(second.chunks == ["section one content", "section two content"])
        #expect(second.tail == "section three")
    }

    @Test("delta 在行和围栏中间切开时结果与一次性输入一致")
    func incrementalDeltasMatchSingleInput() {
        let input = "intro paragraph\n\n```swift\nlet value = 1\n```\n\nending"
        var assembler = StreamingMarkdownAssembler(preferredChunkLength: 8)
        assembler.append("intro para")
        assembler.append("graph\n\n```sw")
        assembler.append("ift\nlet value = 1\n`")
        assembler.append("``\n\nending")
        let single = StreamingMarkdownChunker.split(input, preferredChunkLength: 8)

        #expect(assembler.stableMarkdownChunks == single.chunks)
        #expect(assembler.liveTail == single.tail)
    }
}
