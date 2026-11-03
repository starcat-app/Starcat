//
//  GitHubNotificationIssueSummarySessionTests.swift
//  StarcatTests
//
//  锁定面板之外的生成生命周期、增量边界与账号隔离。用可控 continuation 模拟
//  不及时响应取消的 Provider，不依赖真实模型或界面自动化。
//

import Foundation
import Testing
@testable import Starcat

/// 每个测试独立创建 Store / Session，跨 Issue 与取消重试不会共享测试状态。
@Suite("Issue 总结会话")
@MainActor
struct GitHubNotificationIssueSummarySessionTests {
    @Test("启动立即返回准备状态，准备期间停止不会发出模型请求或回写旧上下文")
    func preparationDoesNotBlockStartAndStopInvalidatesIt() async throws {
        let session = GitHubNotificationIssueSummarySession()
        var generatorCalls = 0
        session.start(title: "Issue", payload: payload(), timeline: [], language: "Chinese") { _, _ in
            generatorCalls += 1
            return "不应请求"
        }
        #expect(session.context == nil)
        #expect(session.isGenerating)
        #expect(session.hasStarted)
        session.stop()
        #expect(session.hasStarted)
        #expect(session.wasInterrupted)
        #expect(!session.isGenerating)
        for _ in 0..<20 { await Task.yield() }
        #expect(generatorCalls == 0)
        #expect(session.context == nil)
        // 新一轮成功完成后，上一轮准备任务即使较晚返回，也不得写回它的 context 或启动模型。
        session.start(title: "New issue", payload: payload(excerpt: "New source"), timeline: [], language: "Chinese") { _, _ in
            "新总结"
        }
        await settle { !session.isGenerating }
        #expect(generatorCalls == 0)
        #expect(session.markdown == "新总结")
        #expect(session.context?.text.contains("New source") == true)
    }

    @Test("高频增量保持顺序且 completed 只补齐缺失尾段")
    func incrementalBurstAndCompletedTailRemainExact() async throws {
        let session = GitHubNotificationIssueSummarySession()
        let pieces = (0..<2_000).map { "片段\($0)🙂 " }
        let expected = pieces.joined() + "最终结论。"
        session.start(title: "Issue", payload: payload(), timeline: [], language: "Chinese") { _, onDelta in
            pieces.forEach(onDelta)
            return expected
        }
        await settle { !session.isGenerating }
        #expect(session.markdown == expected)
        #expect(session.completedMarkdown == expected)
        #expect(session.streamingPresentation?.liveTail == expected)
        #expect(session.hasContent)
        #expect(session.errorMessage == nil)
    }

    @Test("同 Issue 复用进行中任务，浏览另一 Issue 不会取消原任务")
    func storeReusesLiveSessionAndKeepsOtherIssueRunning() async throws {
        let store = GitHubNotificationIssueSummaryStore()
        let first = store.session(threadId: "166", scopeRevision: 1, language: "Chinese")
        let probe = GeneratorProbe()
        first.start(title: "Issue", payload: payload(), timeline: [], language: "Chinese", generator: probe.generate)
        await settle { probe.isWaiting }
        probe.emit("前半段")

        let restored = store.session(threadId: "166", scopeRevision: 1, language: "Chinese")
        #expect(restored === first)
        var duplicateCalls = 0
        restored.start(title: "Issue", payload: payload(), timeline: [], language: "Chinese") { _, _ in
            duplicateCalls += 1
            return "duplicate"
        }
        let other = store.session(threadId: "172", scopeRevision: 1, language: "Chinese")
        #expect(other !== first)
        #expect(first.isGenerating)
        #expect(duplicateCalls == 0)
        probe.emit("后半段")
        probe.finish("前半段后半段")
        await settle { !first.isGenerating }
        #expect(store.session(threadId: "166", scopeRevision: 1, language: "Chinese") === first)
        #expect(first.markdown == "前半段后半段")
    }

    @Test("停止后重试会丢弃旧请求的迟到正文和最终结果")
    func cancelledRequestCannotOverwriteRetry() async throws {
        let session = GitHubNotificationIssueSummarySession()
        let old = GeneratorProbe()
        session.start(title: "Issue", payload: payload(), timeline: [], language: "Chinese", generator: old.generate)
        await settle { old.isWaiting }
        old.emit("旧片段")
        old.emit("尚未发布的尾段")
        session.stop()
        #expect(session.wasInterrupted)
        #expect(session.markdown == "旧片段尚未发布的尾段")
        #expect(session.completedMarkdown == session.markdown)
        #expect(session.streamingPresentation?.liveTail == session.markdown)

        let retry = GeneratorProbe()
        session.start(title: "Issue", payload: payload(), timeline: [], language: "Chinese", generator: retry.generate)
        await settle { retry.isWaiting }
        retry.emit("新片段")
        old.emit("不应追加")
        old.finish("不应覆盖的新结果")
        for _ in 0..<10 { await Task.yield() }
        #expect(session.isGenerating)
        #expect(session.markdown == "新片段")
        retry.finish("新片段与尾段")
        await settle { !session.isGenerating }
        #expect(session.markdown == "新片段与尾段")
        #expect(!session.wasInterrupted)
    }

    @Test("账号作用域变化立即取消并清空旧会话，迟到结果不能恢复缓存")
    func accountScopeResetDiscardsOldText() async throws {
        let store = GitHubNotificationIssueSummaryStore()
        let old = store.session(threadId: "166", scopeRevision: 1, language: "Chinese")
        let probe = GeneratorProbe()
        old.start(title: "Issue", payload: payload(), timeline: [], language: "Chinese", generator: probe.generate)
        await settle { probe.isWaiting }
        probe.emit("旧账号正文")
        store.reset(scopeRevision: 2)
        #expect(!old.isGenerating)
        #expect(old.markdown.isEmpty)
        #expect(!old.hasStarted)
        let fresh = store.session(threadId: "166", scopeRevision: 2, language: "Chinese")
        #expect(fresh !== old)
        probe.emit("旧账号迟到片段")
        probe.finish("旧账号迟到结果")
        for _ in 0..<10 { await Task.yield() }
        #expect(old.markdown.isEmpty)
        #expect(fresh.markdown.isEmpty)
    }

    @Test("失败保留已输出片段，资料变化准确标记为旧来源")
    func failurePreservesPartialTextAndSourceIdentity() async throws {
        let session = GitHubNotificationIssueSummarySession()
        let original = payload()
        session.start(title: "Issue", payload: original, timeline: [], language: "Chinese") { _, onDelta in
            onDelta("尚未结束的正文")
            onDelta("和未发布尾段")
            throw AIClientError.responseTruncated
        }
        await settle { !session.isGenerating }
        #expect(session.markdown == "尚未结束的正文和未发布尾段")
        #expect(session.completedMarkdown == session.markdown)
        #expect(session.streamingPresentation?.liveTail == session.markdown)
        #expect(session.errorMessage != nil)
        #expect(session.matchesSource(title: "Issue", payload: original, timeline: [], language: "Chinese"))
        #expect(!session.matchesSource(title: "Issue", payload: payload(excerpt: "Changed"), timeline: [], language: "Chinese"))
        #expect(!session.matchesSource(title: "Issue", payload: original, timeline: [], language: "English"))
    }

    @Test("成功总结经注入缓存落盘，失败与中断不落盘")
    func successfulGenerationPersistsButFailuresDoNot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-issue-summary-hook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHubNotificationIssueSummaryStore(persistenceCache: DiskIssueSummaryCache(rootOverride: root))
        let session = store.session(threadId: "166", scopeRevision: 1, language: "Chinese")
        session.start(title: "Issue", payload: payload(), timeline: [], language: "Chinese") { _, _ in
            "落盘的总结"
        }
        await settle { !session.isGenerating }
        #expect(session.generatedAt != nil)
        let snapshot = try #require(
            DiskIssueSummaryCache(rootOverride: root).load(payload: payload(), language: "Chinese")
        )
        #expect(snapshot.markdown == "落盘的总结")
        // ISO8601 落盘是秒级精度，与内存里的完成时刻允许小于 1 秒的编码误差。
        #expect(abs(snapshot.generatedAt.timeIntervalSince(session.generatedAt ?? .distantPast)) < 1)
        #expect(snapshot.title == "Issue")

        // 失败不落盘。
        let failed = store.session(threadId: "404", scopeRevision: 1, language: "Chinese")
        failed.start(title: "Issue", payload: payload(), timeline: [], language: "Chinese") { _, _ in
            throw AIClientError.responseTruncated
        }
        await settle { !failed.isGenerating }

        // 中断不落盘。
        let interrupted = store.session(threadId: "405", scopeRevision: 1, language: "Chinese")
        let probe = GeneratorProbe()
        interrupted.start(title: "Issue", payload: payload(), timeline: [], language: "Chinese", generator: probe.generate)
        await settle { probe.isWaiting }
        probe.emit("半截")
        interrupted.stop()
        #expect(interrupted.wasInterrupted)

        // 同一 cache key 下只有成功那次的正文；失败 / 中断都不能伪装成「上次总结」。
        let reloaded = DiskIssueSummaryCache(rootOverride: root)
        #expect(reloaded.load(payload: payload(), language: "Chinese")?.markdown == "落盘的总结")
    }

    @Test("restore 回放磁盘快照；已有内容或生成中时晚到快照让位")
    func restoreReplaysSnapshotAndYieldsToLiveSession() async throws {
        let session = GitHubNotificationIssueSummarySession()
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        session.restore(from: snapshot(markdown: "缓存恢复的总结", generatedAt: generatedAt))
        #expect(session.markdown == "缓存恢复的总结")
        #expect(session.completedMarkdown == "缓存恢复的总结")
        #expect(session.hasContent)
        #expect(!session.isGenerating)
        #expect(session.generatedAt == generatedAt)
        #expect(session.context?.includedCommentCount == 4)
        #expect(session.context?.isTruncated == false)
        #expect(session.errorMessage == nil)
        #expect(session.matchesSource(title: "Issue", payload: payload(), timeline: [], language: "Chinese"))

        // 已有内容（含恢复结果）时，晚到的另一份快照不得覆盖。
        session.restore(from: snapshot(markdown: "另一份", generatedAt: generatedAt.addingTimeInterval(60)))
        #expect(session.markdown == "缓存恢复的总结")

        // 生成进行中时晚到的快照不得覆盖，也不得打断任务。
        let generating = GitHubNotificationIssueSummarySession()
        let probe = GeneratorProbe()
        generating.start(title: "Issue", payload: payload(), timeline: [], language: "Chinese", generator: probe.generate)
        await settle { probe.isWaiting }
        generating.restore(from: snapshot(markdown: "晚到的缓存", generatedAt: generatedAt))
        #expect(generating.isGenerating)
        #expect(generating.generatedAt == nil)
        probe.finish("生成结果")
        await settle { !generating.isGenerating }
        #expect(generating.markdown == "生成结果")
        #expect(generating.generatedAt != nil)
    }

    /// 上下文准备在并发执行器运行，等待用短 deadline 而非固定 yield 次数，避免机器调度差异。
    private func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition())
    }

    private func payload(excerpt: String = "Opening post") -> ActivityNotificationPayload {
        ActivityNotificationPayload(
            threadId: "166", reason: "mention", chip: .mention, subjectType: "Issue", subjectNumber: 166,
            repositoryFullName: "starcat-app/Starcat", actorLogin: "reader", authorLogin: "author",
            authorCreatedAt: nil, excerpt: excerpt, comments: [], people: []
        )
    }

    private func snapshot(markdown: String, generatedAt: Date) -> IssueSummaryCacheSnapshot {
        IssueSummaryCacheSnapshot(
            formatVersion: IssueSummaryCacheSnapshot.currentFormatVersion,
            owner: "starcat-app",
            repo: "Starcat",
            number: 166,
            language: "Chinese",
            generatedAt: generatedAt,
            markdown: markdown,
            title: "Issue",
            payload: payload(),
            timeline: [],
            contextStats: .init(
                includedCommentCount: 4,
                availableCommentCount: 6,
                includedEventCount: 2,
                availableEventCount: 2,
                isTruncated: false
            )
        )
    }
}

/// 故意不响应 Task 取消，覆盖第三方 Provider 在取消后继续回调的真实边界。
@MainActor
private final class GeneratorProbe {
    private var onDelta: (@MainActor (String) -> Void)?
    private var continuation: CheckedContinuation<String, Error>?

    var isWaiting: Bool { continuation != nil }

    func generate(context: String, onDelta: @escaping @MainActor (String) -> Void) async throws -> String {
        self.onDelta = onDelta
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func emit(_ delta: String) { onDelta?(delta) }

    func finish(_ result: String) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
