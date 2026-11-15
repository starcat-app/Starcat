//
//  DailyRecommendationExplanationTests.swift
//  StarcatTests
//
//  隔离 AI 网络和真实用户目录，验证权益、缓存维度、跨窗口合并与账号取消。
//

import Foundation
import Testing
@testable import Starcat

@Suite("每日推荐 AI 理由")
@MainActor
struct DailyRecommendationExplanationTests {
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
        await store.prepare(item: item(), accountID: 1, revision: 1, locale: "en", isPro: false, generate: generate)
        var noSources = item()
        noSources.matchedSeeds = nil
        await store.prepare(item: noSources, accountID: 1, revision: 1, locale: "en", isPro: true, generate: generate)
        #expect(calls == 0)
        await store.prepare(item: item(), accountID: 1, revision: 1, locale: "en", isPro: true, generate: generate)
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
        await original.prepare(item: item(), accountID: 1, revision: 1, locale: "en", isPro: true, generate: generate)
        let restored = DailyRecommendationExplanationStore(root: root)
        await restored.prepare(item: item(), accountID: 1, revision: 1, locale: "en", isPro: true, generate: generate)
        #expect(calls == 1)
        #expect(restored.text(for: item(), locale: "en", isPro: true) == "Reason 1")
        await restored.prepare(item: item(), accountID: 2, revision: 2, locale: "en", isPro: true, generate: generate)
        await restored.prepare(item: item(), accountID: 2, revision: 2, locale: "ja", isPro: true, generate: generate)
        var changed = item()
        changed.matchedSeeds = []
        changed.matchedSeeds = [RecommendationSeed(repoID: 9, fullName: "owner/other", description: nil,
                                                   language: nil, reasons: ["costar"])]
        await restored.prepare(item: changed, accountID: 2, revision: 2, locale: "ja", isPro: true, generate: generate)
        #expect(calls == 4)
    }

    @Test("切账号后忽略迟到的 AI 响应")
    func ignoresLateResult() async {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DailyRecommendationExplanationStore(root: root)
        var continuation: CheckedContinuation<String, Never>?
        let task = Task {
            await store.prepare(item: item(), accountID: 1, revision: 1, locale: "en", isPro: true) { _ in
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
        let first = Task { await store.prepare(item: item(), accountID: 1, revision: 1, locale: "en",
                                              isPro: true, generate: generator) }
        while continuation == nil { await Task.yield() }
        let second = Task { await store.prepare(item: item(), accountID: 1, revision: 1, locale: "en",
                                               isPro: true, generate: generator) }
        await Task.yield()
        continuation?.resume(returning: "Shared")
        await first.value
        await second.value
        #expect(calls == 1)
        await store.prepare(item: item(), accountID: 1, revision: 1, locale: "ja", isPro: true) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(store.text(for: item(), locale: "ja", isPro: true) == nil)
        await store.prepare(item: item(), accountID: 1, revision: 1, locale: "ja", isPro: true) { _ in "Recovered" }
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
        #expect(request.usageContext?.phase == "recommendation_reason")
        #expect(request.model == "configured-model")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recommendation-reason-\(UUID())")
    }

    private func item() -> RepoRecommendationItem {
        RepoRecommendationItem(repoID: 10, fullName: "owner/result", description: "A code editor",
                               language: "Swift", stars: 1, forks: 0, archived: false, score: 1,
                               source: "starcat_trained", reasons: ["costar"],
                               matchedSeeds: [RecommendationSeed(repoID: 1, fullName: "owner/source",
                                                                  description: "Editor tools", language: "Swift",
                                                                  reasons: ["costar"])])
    }
}
