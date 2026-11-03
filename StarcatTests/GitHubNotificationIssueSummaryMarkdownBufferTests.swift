//
//  GitHubNotificationIssueSummaryMarkdownBufferTests.swift
//  StarcatTests
//
//  使用确定时间验证 Issue Markdown 的段落冻结、8Hz 发布边界与终态无损收口，
//  不依赖实际渲染帧率、网络或 sleep，避免测试因机器负载抖动。
//

import Foundation
import Testing
@testable import Starcat

/// 直接检验真实生产 buffer，确保节流不会改变正文真源或 Markdown 围栏边界。
@Suite("Issue 总结 Markdown buffer")
struct GitHubNotificationIssueSummaryMarkdownBufferTests {
    @Test("短段落也在空行冻结，未结束尾部保持 Markdown 原文")
    func shortParagraphFreezesAtSemanticBoundary() {
        var buffer = GitHubNotificationIssueSummaryMarkdownBuffer()
        let snapshot = buffer.append("**核心内容**。\n\n下一段 `code`", now: 0)
        #expect(snapshot?.stableMarkdownChunks == ["**核心内容**。"])
        #expect(snapshot?.liveTail == "下一段 `code`")
        #expect(buffer.text == "**核心内容**。\n\n下一段 `code`")
    }

    @Test("大批次不能绕过 125ms，终态 flush 只补发一次")
    func burstsRespectCadenceAndFlushOnce() {
        var buffer = GitHubNotificationIssueSummaryMarkdownBuffer()
        #expect(buffer.append("首段", now: 0) != nil)
        let burst = String(repeating: "内容", count: 2_000)
        #expect(buffer.append(burst, now: 0.01) == nil)
        #expect(buffer.publishIfDue(now: 0.124) == nil)
        let final = buffer.flush()
        #expect(final?.liveTail == "首段" + burst)
        #expect(final?.revision == 2)
        #expect(buffer.flush() == nil)
        #expect(!buffer.hasPendingChanges)
    }

    @Test("网络暂停也能按时间发布等待中的尾段")
    func pausedNetworkPublishesPendingTail() {
        var buffer = GitHubNotificationIssueSummaryMarkdownBuffer()
        _ = buffer.append("开头", now: 0)
        #expect(buffer.append("**重点**", now: 0.01) == nil)
        let snapshot = buffer.publishIfDue(now: 0.125)
        #expect(snapshot?.liveTail == "开头**重点**")
        #expect(!buffer.hasPendingChanges)
    }

    @Test("一万个细碎片段保持完整且按时间合流")
    func tenThousandDeltasRemainExactAndBatched() {
        var buffer = GitHubNotificationIssueSummaryMarkdownBuffer()
        var commits = 0
        var lastPublished: StreamingMarkdownSnapshot?
        for index in 0..<10_000 {
            if let snapshot = buffer.append("x", now: Double(index) / 1_000) {
                commits += 1
                lastPublished = snapshot
            }
        }
        #expect(buffer.text == String(repeating: "x", count: 10_000))
        #expect(commits <= 81)
        let last = buffer.flush() ?? lastPublished
        #expect(last?.liveTail == buffer.text)
        #expect(buffer.flush() == nil)
    }

    @Test("跨增量代码围栏内的空行不会冻结成独立段落")
    func splitFencePreservesMarkdownStructure() {
        var buffer = GitHubNotificationIssueSummaryMarkdownBuffer()
        _ = buffer.append("前言\n\n```sw", now: 0)
        _ = buffer.append("ift\nlet value = 1\n\n", now: 0.01)
        let insideFence = buffer.flush()
        #expect(insideFence?.stableMarkdownChunks == ["前言"])
        #expect(insideFence?.liveTail == "```swift\nlet value = 1\n\n")
        _ = buffer.append("```\n\n结论", now: 0.02)
        let closedFence = buffer.flush()
        #expect(closedFence?.stableMarkdownChunks == ["前言", "```swift\nlet value = 1\n\n```"])
        #expect(closedFence?.liveTail == "结论")
    }

    @Test("completed 只补尾或修订一次，不重复追加完整正文")
    func finalTextReconciliationNeverDuplicates() {
        var buffer = GitHubNotificationIssueSummaryMarkdownBuffer()
        _ = buffer.append("**原文**", now: 0)
        buffer.reconcileFinalText("**原文**和尾段")
        #expect(buffer.flush()?.liveTail == "**原文**和尾段")
        buffer.reconcileFinalText("**原文**和尾段")
        #expect(buffer.flush() == nil)
        buffer.reconcileFinalText("**修订后的结论**。\n\n下一段")
        let revised = buffer.flush()
        #expect(revised?.stableMarkdownChunks == ["**修订后的结论**。"])
        #expect(revised?.liveTail == "下一段")
        #expect(buffer.text == "**修订后的结论**。\n\n下一段")
    }

    @Test("completed 与尚未发布的片段同时到达时不丢尾、不重复，修订会替换旧片段")
    func finalTextReconcilesPendingDeltas() {
        var buffer = GitHubNotificationIssueSummaryMarkdownBuffer()
        _ = buffer.append("开头", now: 0)
        #expect(buffer.append("**重点**", now: 0.01) == nil)
        buffer.reconcileFinalText("开头**重点**和结论")
        #expect(buffer.flush()?.liveTail == "开头**重点**和结论")
        #expect(buffer.text == "开头**重点**和结论")

        #expect(buffer.append("待替换片段", now: 0.02) == nil)
        buffer.reconcileFinalText("**修订后的结论**。\n\n下一段")
        let corrected = buffer.flush()
        #expect(corrected?.stableMarkdownChunks == ["**修订后的结论**。"])
        #expect(corrected?.liveTail == "下一段")
        #expect(buffer.text == "**修订后的结论**。\n\n下一段")
    }
}
