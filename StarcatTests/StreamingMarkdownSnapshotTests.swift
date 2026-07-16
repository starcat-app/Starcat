//
//  StreamingMarkdownSnapshotTests.swift
//  StarcatTests
//
//  锁住流式 Markdown 分块边界：稳定前缀可冻结，未闭合代码块和短尾部必须保留
//  为纯文本，避免中间态 Markdown 解析改变仍在增长的结构。
//

import Foundation
import Testing
@testable import Starcat

@Suite("StreamingMarkdownChunker")
struct StreamingMarkdownSnapshotTests {
    @Test("RAG 正文与 Think 分别严格限制为 15Hz 和 10Hz")
    func ragPresentationCadenceUsesStrictTimeLimits() {
        #expect(abs(RAGStreamingPresentationCadence.answerInterval - (1.0 / 15.0)) < 0.000_001)
        #expect(RAGStreamingPresentationCadence.reasoningInterval == 0.1)

        var answerThrottle = StreamingPresentationThrottle(
            minimumInterval: RAGStreamingPresentationCadence.answerInterval
        )
        let firstAnswerCommit = answerThrottle.shouldCommit(now: 0)
        let earlyAnswerCommit = answerThrottle.shouldCommit(now: 0.05)
        let secondAnswerCommit = answerThrottle.shouldCommit(now: 1.0 / 15.0)
        #expect(firstAnswerCommit)
        #expect(!earlyAnswerCommit)
        #expect(secondAnswerCommit)

        var reasoningBuffer = StreamingTextPresentationBuffer(
            throttleInterval: RAGStreamingPresentationCadence.reasoningInterval,
            immediateCharacterCount: nil,
            maximumPresentedCharacterCount: 8_000
        )
        #expect(reasoningBuffer.append("首包", now: 0) == "首包")
        // 较大 delta 也不能绕过 10Hz 上限；时间窗到期后一次完整发布。
        let largeDelta = String(repeating: "x", count: 1_000)
        #expect(reasoningBuffer.append(largeDelta, now: 0.05) == nil)
        #expect(reasoningBuffer.append("尾", now: 0.1) == "首包" + largeDelta + "尾")
        #expect(reasoningBuffer.flush(now: 0.2) == nil)
    }

    @Test("严格节流不会被高频调用或大批次绕过")
    func strictPresentationThrottleCapsCommitFrequency() {
        var throttle = StreamingPresentationThrottle(minimumInterval: 0.125)

        let first = throttle.shouldCommit(now: 0)
        let tooEarly = throttle.shouldCommit(now: 0.05)
        let stillTooEarly = throttle.shouldCommit(now: 0.124)
        let second = throttle.shouldCommit(now: 0.125)
        let secondWindowTooEarly = throttle.shouldCommit(now: 0.20)
        let third = throttle.shouldCommit(now: 0.25)

        #expect(first)
        #expect(!tooEarly)
        #expect(!stillTooEarly)
        #expect(second)
        #expect(!secondWindowTooEarly)
        #expect(third)
    }

    @Test("运行中 Think 只展示尾部窗口但完整内容仍保留")
    func textPresentationBufferBoundsOnlyPresentedText() {
        var buffer = StreamingTextPresentationBuffer(
            throttleInterval: 0.20,
            immediateCharacterCount: nil,
            maximumPresentedCharacterCount: 8
        )

        #expect(buffer.append("12345678", now: 0) == "12345678")
        #expect(buffer.append("90", now: 0.1) == nil)
        #expect(buffer.flush(now: 0.2) == "…\n34567890")
        #expect(buffer.text == "1234567890")
    }

    @Test("高频文本 delta 只低频发布且最终内容完整")
    func textPresentationBufferThrottlesWithoutDroppingContent() {
        var buffer = StreamingTextPresentationBuffer(
            throttleInterval: 0.15,
            immediateCharacterCount: 256
        )
        var presented = ""
        var presentationCount = 0

        for index in 0..<10_000 {
            if let snapshot = buffer.append("x", now: Double(index) / 1_000) {
                presented = snapshot
                presentationCount += 1
            }
        }
        if let finalSnapshot = buffer.flush(now: 10) {
            presented = finalSnapshot
            presentationCount += 1
        }

        #expect(buffer.text == String(repeating: "x", count: 10_000))
        #expect(presented == buffer.text)
        #expect(presentationCount < 100)
    }

    @Test("流结束只补发尚未发布的尾部")
    func textPresentationBufferFlushesPendingTailOnce() {
        var buffer = StreamingTextPresentationBuffer(
            throttleInterval: 10,
            immediateCharacterCount: 100
        )

        #expect(buffer.append("first", now: 0) == "first")
        #expect(buffer.append(" tail", now: 0.1) == nil)
        #expect(buffer.flush(now: 0.2) == "first tail")
        #expect(buffer.flush(now: 0.3) == nil)
    }

    @Test("Think 首个 delta 展开且正文开始时无损折叠")
    func reasoningPresentationTransitionsAtFirstAnswerDelta() {
        var buffer = StreamingReasoningPresentationBuffer(
            throttleInterval: 10,
            immediateCharacterCount: 100
        )

        let first = buffer.append("先检查", now: 0)
        #expect(first?.text == "先检查")
        #expect(first?.isStreaming == true)
        #expect(buffer.append("知识库证据", now: 0.1) == nil)

        let completed = buffer.completeReasoning(now: 0.2)
        #expect(completed?.text == "先检查知识库证据")
        #expect(completed?.isStreaming == false)
        #expect(buffer.completeReasoning(now: 0.3) == nil)
        #expect(buffer.finish(now: 0.4) == nil)
        #expect(buffer.text == "先检查知识库证据")
    }

    @Test("发送后立即建立 Think 步骤，空 reasoning 也能正常结束")
    func reasoningPresentationShowsInitialStepWithoutReasoningTokens() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 10)
        var buffer = StreamingReasoningPresentationBuffer(startedAt: startedAt)

        let initial = buffer.begin()
        #expect(initial.text.isEmpty)
        #expect(initial.isStreaming)
        #expect(initial.startedAt == startedAt)

        let completed = buffer.completeReasoning(now: 10.6)
        #expect(completed?.text.isEmpty == true)
        #expect(completed?.isStreaming == false)
        #expect(completed?.completedAt == Date(timeIntervalSinceReferenceDate: 10.6))
    }

    @Test("高频长 Think 低频发布且完成态保留全部内容")
    func reasoningPresentationThrottlesWithoutDroppingContent() {
        var buffer = StreamingReasoningPresentationBuffer(
            throttleInterval: 0.15,
            immediateCharacterCount: 256
        )
        var lastSnapshot: StreamingReasoningSnapshot?
        var presentationCount = 0

        for index in 0..<10_000 {
            if let snapshot = buffer.append("x", now: Double(index) / 1_000) {
                lastSnapshot = snapshot
                presentationCount += 1
            }
        }
        if let completed = buffer.completeReasoning(now: 10) {
            lastSnapshot = completed
            presentationCount += 1
        }

        #expect(buffer.text == String(repeating: "x", count: 10_000))
        #expect(lastSnapshot?.text == buffer.text)
        #expect(lastSnapshot?.isStreaming == false)
        #expect(presentationCount < 100)
    }

    @Test("正文开始后的迟到 reasoning 不会重新展开")
    func lateReasoningStaysCollapsedAndFlushesAtFinish() {
        var buffer = StreamingReasoningPresentationBuffer(
            throttleInterval: 10,
            immediateCharacterCount: 100
        )

        let emptyCompletion = buffer.completeReasoning(now: 0)
        #expect(emptyCompletion?.text.isEmpty == true)
        #expect(emptyCompletion?.isStreaming == false)
        let late = buffer.append("迟到", now: 0.1)
        #expect(late?.isStreaming == false)
        #expect(buffer.append("内容", now: 0.2) == nil)

        let completed = buffer.finish(now: 0.3)
        #expect(completed?.text == "迟到内容")
        #expect(completed?.isStreaming == false)
    }

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
