//
//  DailyRecommendationExplanationTests.swift
//  StarcatTests
//
//  隔离 AI 网络和真实用户目录，验证整批就绪、只读缓存、权益兜底及取消／截止时间。
//

import Foundation
import AppKit
import Testing
@testable import Starcat

@Suite("每日推荐 AI 理由")
@MainActor
struct DailyRecommendationExplanationTests {
    @Test("推荐正文仅链接真实来源，未点名来源保留简洁链接，模型外链被转义")
    func inlineEvidenceLinks() {
        let sources = [
            RecommendationSeed(repoID: 1, fullName: "owner/repo", description: nil, language: nil, reasons: []),
            RecommendationSeed(repoID: 2, fullName: "other/tool", description: nil, language: nil, reasons: [])
        ]
        let markdown = RecommendationEvidenceMarkdown.make(
            text: "试试 owner/repo，与 owner/repository 不同。[外链](https://example.com)", sources: sources
        )
        #expect(markdown.contains("[owner/repo](https://github.com/owner/repo)"))
        #expect(markdown.contains("[other/tool](https://github.com/other/tool)"))
        #expect(!markdown.contains("[owner/repository]"))
        #expect(markdown.contains("\\[外链\\]"))
        #expect(!markdown.contains("基于你"))
        let avatars = RAGMarkdownText.prepareForDisplay(markdown, citations: [])
        #expect(avatars.contains("starcat-rag-avatar://owner"))
        #expect(avatars.contains("starcat-rag-avatar://other"))
    }

    @Test("推荐依据的头像和文字共用项目链接，离线占位与窄栏换行均保留")
    func evidenceAttachmentsAndWrapping() throws {
        let sources = [
            RecommendationSeed(repoID: 1, fullName: "Usagi-org/ai-goofish-monitor", description: nil, language: nil, reasons: []),
            RecommendationSeed(repoID: 2, fullName: "ultraworkers/claw-code", description: nil, language: nil, reasons: [])
        ]
        let markdown = RecommendationEvidenceMarkdown.make(
            text: "参考 Usagi-org/ai-goofish-monitor，也适合自动推送。", sources: sources
        )
        let content = RecommendationEvidenceText.attributedContent(markdown: markdown, avatars: [:], fontSize: 15)
        var attachmentCount = 0
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            attachmentCount += 1
            #expect(attachment.image != nil)
            #expect(content.attribute(.link, at: range.location, effectiveRange: nil) is URL)
        }
        #expect(attachmentCount == 2)
        for source in sources {
            let range = (content.string as NSString).range(of: source.fullName)
            try #require(range.location != NSNotFound)
            #expect(content.attribute(.link, at: range.location, effectiveRange: nil) as? URL
                == GitHubURLs.repo(fullName: source.fullName))
        }
        #expect(content.attribute(.link, at: 0, effectiveRange: nil) == nil)

        // 使用 TextKit 实际测高，验证附件参与行内排版，长项目名不会把详情撑出水平边界。
        func height(width: CGFloat) -> CGFloat {
            let storage = NSTextStorage(attributedString: content)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            return layout.usedRect(for: container).height
        }
        #expect(height(width: 200) > height(width: 900))
    }

    @Test("非 Pro 或无实际来源不调用 LLM，也不读取 Pro 缓存")
    func requiresProAndEvidence() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationExplanationStore(root: root)
        var calls = 0
        let generate: @MainActor (DailyRecommendationExplanationInput) async throws -> String = { _ in
            calls += 1
            return "A reason."
        }
        await store.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "en", isPro: false, generate: generate)
        var noSources = item()
        noSources.matchedSeeds = nil
        await store.prepareBatch(items: [noSources], accountID: 1, revision: 1, locale: "en", isPro: true, generate: generate)
        #expect(calls == 0)
        await store.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true, generate: generate)
        #expect(calls == 1)
        #expect(store.text(for: item(), locale: "en", isPro: false) == nil)
    }

    @Test("重开复用磁盘缓存，账号、语言和证据变化各自重新生成")
    func cacheDimensions() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        let generate: @MainActor (DailyRecommendationExplanationInput) async throws -> String = { _ in
            calls += 1
            return "Reason \(calls)"
        }
        let original = DailyRecommendationExplanationStore(root: root)
        await original.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true, generate: generate)
        let restored = DailyRecommendationExplanationStore(root: root)
        await restored.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true, generate: generate)
        #expect(calls == 1)
        #expect(restored.text(for: item(), locale: "en", isPro: true) == "Reason 1")
        await restored.prepareBatch(items: [item()], accountID: 2, revision: 2, locale: "en", isPro: true, generate: generate)
        await restored.prepareBatch(items: [item()], accountID: 2, revision: 2, locale: "ja", isPro: true, generate: generate)
        var changed = item()
        changed.matchedSeeds = []
        changed.matchedSeeds = [RecommendationSeed(repoID: 9, fullName: "owner/other", description: nil,
                                                   language: nil, reasons: ["costar"])]
        await restored.prepareBatch(items: [changed], accountID: 2, revision: 2, locale: "ja", isPro: true, generate: generate)
        #expect(calls == 4)
    }

    @Test("切账号后忽略迟到的 AI 响应")
    func ignoresLateResult() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationExplanationStore(root: root)
        var continuation: CheckedContinuation<String, Never>?
        let task = Task {
            await store.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true) { _ in
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        store.activate(accountID: 2, revision: 2)
        continuation?.resume(returning: "Late reason")
        await task.value
        #expect(store.explanations.isEmpty)
    }

    @Test("多个窗口共享生成任务，失败后允许重新尝试")
    func coalescesAndRecovers() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationExplanationStore(root: root)
        var calls = 0
        var continuation: CheckedContinuation<String, Never>?
        let generator: @MainActor (DailyRecommendationExplanationInput) async throws -> String = { _ in
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        let first = Task { await store.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "en",
                                              isPro: true, generate: generator) }
        while continuation == nil { await Task.yield() }
        let second = Task { await store.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "en",
                                               isPro: true, generate: generator) }
        await Task.yield()
        continuation?.resume(returning: "Shared")
        await first.value
        await second.value
        #expect(calls == 1)
        await store.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "ja", isPro: true) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(store.text(for: item(), locale: "ja", isPro: true) == nil)
        await store.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "ja", isPro: true,
                                 retryFailed: true) { _ in "Recovered" }
        #expect(store.text(for: item(), locale: "ja", isPro: true) == "Recovered")
    }

    @Test("Prompt 只包含当前项目与真实来源，并通过现有链路记录用量")
    func groundedPrompt() throws {
        let request = try RepoAIInsightService.makeRecommendationReasonRequest(
            input: DailyRecommendationExplanationInput(item()), model: "configured-model",
            parameters: .defaults(for: .chat), outputLanguage: "zh-Hans"
        )
        let input = try JSONDecoder().decode(DailyRecommendationExplanationInput.self, from: Data(request.userPrompt.utf8))
        #expect(input.sources.map(\.repoID) == [1])
        #expect(request.systemPrompt.contains("zh-Hans"))
        #expect(request.systemPrompt.contains("Do not invent"))
        #expect(request.systemPrompt.contains("not a fixed template"))
        #expect(request.systemPrompt.contains("Do not force a difference"))
        #expect(request.usageContext?.phase == "recommendation_reason")
        #expect(request.model == "configured-model")
        let other = try RepoAIInsightService.makeRecommendationReasonRequest(
            input: DailyRecommendationExplanationInput(item(11)), model: "configured-model",
            parameters: .defaults(for: .chat), outputLanguage: "zh-Hans"
        )
        #expect(request.systemPrompt != other.systemPrompt)
    }

    @Test("整批保存完成才返回，生成并发最多三个")
    func batchWaitsForPersistedReasons() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationExplanationStore(root: root)
        let items = (10...13).map { item(Int64($0)) }
        var waiting: [Int64: CheckedContinuation<String, Never>] = [:]
        var completed = false
        let preparation = Task {
            await store.prepareBatch(items: items, accountID: 1, revision: 1, locale: "en", isPro: true) { input in
                await withCheckedContinuation { waiting[input.repoID] = $0 }
            }
            completed = true
        }
        while waiting.count < 3 { await Task.yield() }
        #expect(!completed)
        #expect(waiting[13] == nil)
        waiting.removeValue(forKey: 10)?.resume(returning: "Reason 10")
        while waiting[13] == nil { await Task.yield() }
        #expect(!completed)
        for (id, continuation) in waiting { continuation.resume(returning: "Reason \(id)") }
        await preparation.value
        #expect(completed)
        // 用新 Store 只读磁盘，证明返回时结果确实已保存，而不只是发布了内存文本。
        let detail = DailyRecommendationExplanationStore(root: root)
        await detail.loadSaved(items: items, accountID: 1, revision: 1, locale: "en", isPro: true)
        #expect(items.allSatisfy { detail.text(for: $0, locale: "en", isPro: true) == "Reason \($0.repoID)" })
    }

    @Test("历史只读已保存理由，缺失或损坏缓存保持基础依据")
    func historyReadsSavedResultsOnly() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generated = DailyRecommendationExplanationStore(root: root)
        await generated.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true) { _ in "Saved" }
        let key = try DailyRecommendationExplanationInput(item()).cacheKey(locale: "en")
        let detail = DailyRecommendationExplanationStore(root: root)
        await detail.loadSaved(items: [item(), item(11)], accountID: 1, revision: 1, locale: "en", isPro: true)
        #expect(detail.text(for: item(), locale: "en", isPro: true) == "Saved")
        #expect(detail.text(for: item(11), locale: "en", isPro: true) == nil)
        try Data("broken".utf8).write(to: root.appendingPathComponent("1/\(key).json"))
        let restarted = DailyRecommendationExplanationStore(root: root)
        await restarted.loadSaved(items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true)
        #expect(restarted.explanations.isEmpty)
    }

    @Test("配置错误不调用 LLM，已有缓存仍可离线读取")
    func invalidConfigurationFallsBack() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationExplanationStore(root: root)
        var calls = 0
        await store.prepareBatch(
            items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true,
            checkConfiguration: { throw URLError(.userAuthenticationRequired) }
        ) { _ in calls += 1; return "Unexpected" }
        #expect(calls == 0)
        #expect(store.explanations.isEmpty)
        await store.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true,
                                 retryFailed: true) { _ in "Saved" }
        let restored = DailyRecommendationExplanationStore(root: root)
        var configurationChecks = 0
        await restored.prepareBatch(
            items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true,
            checkConfiguration: { configurationChecks += 1; throw URLError(.userAuthenticationRequired) }
        ) { _ in calls += 1; return "Unexpected" }
        #expect(configurationChecks == 0)
        #expect(calls == 0)
        #expect(restored.text(for: item(), locale: "en", isPro: true) == "Saved")
    }

    @Test("部分项目失败或返回空文本不影响整批完成")
    func partialFailuresKeepSuccessfulReasons() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationExplanationStore(root: root)
        var calls: [Int64] = []
        await store.prepareBatch(items: (10...13).map { item(Int64($0)) },
                                 accountID: 1, revision: 1, locale: "en", isPro: true) { input in
            calls.append(input.repoID)
            if input.repoID == 11 { throw URLError(.notConnectedToInternet) }
            return input.repoID == 12 ? "  \n" : "Reason \(input.repoID)"
        }
        #expect(Set(calls) == [10, 11, 12, 13])
        #expect(store.text(for: item(), locale: "en", isPro: true) == "Reason 10")
        #expect(store.text(for: item(11), locale: "en", isPro: true) == nil)
        #expect(store.text(for: item(12), locale: "en", isPro: true) == nil)
        #expect(store.text(for: item(13), locale: "en", isPro: true) == "Reason 13")
    }

    @Test("理由写盘失败时不发布未保存结果")
    func persistenceFailureUsesBasicReason() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocked directory".utf8).write(to: root)
        let store = DailyRecommendationExplanationStore(root: root)
        var calls = 0
        await store.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true) { _ in
            calls += 1
            return "Cannot save"
        }
        #expect(calls == 1)
        #expect(store.explanations.isEmpty)
    }

    @Test("整批超时不等待忽略取消的模型，不启动排队项目、不保存迟到响应")
    func timeoutReleasesPresentation() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationExplanationStore(root: root)
        var waiting: [CheckedContinuation<String, Never>] = []
        var calls = 0
        var finished = 0
        let start = ContinuousClock.now
        await store.prepareBatch(items: (10...19).map { item(Int64($0)) },
                                 accountID: 1, revision: 1, locale: "en", isPro: true,
                                 timeout: .milliseconds(80)) { _ in
            calls += 1
            defer { finished += 1 }
            return await withCheckedContinuation { waiting.append($0) }
        }
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(calls == 3)
        #expect(store.explanations.isEmpty)
        for continuation in waiting { continuation.resume(returning: "Too late") }
        while finished < calls { await Task.yield() }
        let restored = DailyRecommendationExplanationStore(root: root)
        await restored.loadSaved(items: (10...19).map { item(Int64($0)) },
                                 accountID: 1, revision: 1, locale: "en", isPro: true)
        #expect(restored.explanations.isEmpty)
    }

    @Test("取消批次立即结束等待且不保存迟到响应")
    func cancelledBatchDoesNotPublish() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationExplanationStore(root: root)
        var continuation: CheckedContinuation<String, Never>?
        var finished = false
        let preparation = Task {
            await store.prepareBatch(items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true) { _ in
                defer { finished = true }
                return await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        preparation.cancel()
        await preparation.value
        continuation?.resume(returning: "Cancelled")
        while !finished { await Task.yield() }
        #expect(store.explanations.isEmpty)
        let restored = DailyRecommendationExplanationStore(root: root)
        await restored.loadSaved(items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true)
        #expect(restored.explanations.isEmpty)
    }

    @Test("失败冷却期间重开不再请求，主动重试只补缺少的理由")
    func failedReasonsHaveCooldownAndExplicitRetry() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationExplanationStore(root: root)
        let now = ContinuousClock.now
        var calls: [Int64] = []
        let generate: @MainActor @Sendable (DailyRecommendationExplanationInput) async throws -> String = { input in
            calls.append(input.repoID)
            if input.repoID == 11 { throw URLError(.userAuthenticationRequired) }
            return "Saved"
        }
        await store.prepareBatch(items: [item(), item(11)], accountID: 1, revision: 1, locale: "en", isPro: true,
                                 now: now, generate: generate)
        #expect(store.canRetry(for: item(11), locale: "en", isPro: true))
        for _ in 0..<3 {
            await store.prepareBatch(items: [item(), item(11)], accountID: 1, revision: 1, locale: "en", isPro: true,
                                     now: now.advanced(by: .seconds(60)), generate: generate)
        }
        #expect(calls.sorted() == [10, 11])
        await store.prepareBatch(items: [item(), item(11)], accountID: 1, revision: 1, locale: "en", isPro: true,
                                 retryFailed: true, now: now.advanced(by: .seconds(61))) { input in
            calls.append(input.repoID)
            return "Recovered"
        }
        #expect(calls.sorted() == [10, 11, 11])
        #expect(!store.canRetry(for: item(11), locale: "en", isPro: true))
    }

    @Test("冷却到期允许自动补试，配置失败同样冷却")
    func cooldownExpiresAndIncludesConfigurationFailure() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationExplanationStore(root: root)
        let now = ContinuousClock.now
        var checks = 0
        var calls = 0
        for elapsed in [0, 60, 301] {
            await store.prepareBatch(
                items: [item()], accountID: 1, revision: 1, locale: "en", isPro: true,
                now: now.advanced(by: .seconds(elapsed)),
                checkConfiguration: { checks += 1; throw URLError(.userAuthenticationRequired) }
            ) { _ in calls += 1; return "Unexpected" }
        }
        #expect(checks == 2)
        #expect(calls == 0)
        #expect(!store.canRetry(for: item(), locale: "en", isPro: false))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recommendation-reason-\(UUID())")
    }

    private func item(_ id: Int64 = 10) -> RepoRecommendationItem {
        RepoRecommendationItem(repoID: id, fullName: "owner/result\(id)", description: "A code editor",
                               language: "Swift", stars: 1, forks: 0, archived: false, score: 1,
                               source: "starcat_trained", reasons: ["costar"],
                               matchedSeeds: [RecommendationSeed(repoID: 1, fullName: "owner/source",
                                                                  description: "Editor tools", language: "Swift",
                                                                  reasons: ["costar"])])
    }
}
