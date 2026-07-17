//
//  RAGDebugPayloadPresentationTests.swift
//  StarcatTests
//
//  锁住 Debug 大正文的后台分块契约：正文必须完整、单块有界，空内容和
//  超长单行也不能退化成一次性巨型 Text。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RAG Debug payload presentation")
struct RAGDebugPayloadPresentationTests {
    @Test("多行正文分块后保持逐字完整且单块有界")
    func multilinePayloadRemainsLosslessAndBounded() {
        let payload = (0..<20)
            .map { "line-\($0)-abcdefghij\n" }
            .joined()

        let chunks = RAGDebugPayloadPresentationBuilder.chunks(
            for: payload,
            maximumUTF8Bytes: 48
        )

        #expect(chunks.joined() == payload)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.utf8.count <= 48 })
    }

    @Test("超长单行按 Character 切分且不破坏 Unicode")
    func oversizedUnicodeLineRemainsLosslessAndBounded() {
        let payload = String(repeating: "星🐈", count: 80)

        let chunks = RAGDebugPayloadPresentationBuilder.chunks(
            for: payload,
            maximumUTF8Bytes: 16
        )

        #expect(chunks.joined() == payload)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.utf8.count <= 16 })
    }

    @Test("空正文仍生成一个可挂载块")
    func emptyPayloadStillProducesOneChunk() {
        #expect(
            RAGDebugPayloadPresentationBuilder.chunks(
                for: "",
                maximumUTF8Bytes: 32
            ) == [""]
        )
    }

    @Test("展示快照保留事件顺序和完整正文")
    func presentationPreservesEventOrderAndPayloads() {
        let first = RAGDebugEvent(
            stage: .plannerPrompt,
            elapsedSeconds: 0.1,
            payload: String(repeating: "planner\n", count: 40)
        )
        let second = RAGDebugEvent(
            stage: .plannerResponse,
            elapsedSeconds: 0.2,
            payload: String(repeating: "response\n", count: 40)
        )

        let presentation = RAGDebugPayloadPresentationBuilder.make(
            expansionID: first.id,
            events: [first, second],
            localeIdentifier: "zh-Hans",
            maximumChunkUTF8Bytes: 64
        )

        #expect(presentation.blocks.map(\.eventID) == [first.id, second.id])
        #expect(presentation.block(for: first.id)?.chunks.joined() == first.payload)
        #expect(presentation.block(for: second.id)?.chunks.joined() == second.payload)
        #expect(presentation.localeIdentifier == "zh-Hans")
        if let firstBlock = presentation.block(for: first.id), firstBlock.chunks.count > 1 {
            #expect(!firstBlock.displayText(at: 0).hasSuffix("\n"))
            #expect(firstBlock.chunks[0].hasSuffix("\n"))
        }
    }
}
