//
//  RepoShareTaskStoreTests.swift
//  StarcatTests
//
//  AI 分享后台任务的仓库隔离与缓存快速路径测试。
//
//  关键约束：
//  - 已有摘要时不得进入生成阶段，避免重复 AI 请求；
//  - 同一仓库重复点击不得重复提交；
//  - 多个仓库任务必须各自保留点击时快照，完成结果不能串仓。
//  - 取消必须让旧任务失效；即使 provider 晚返回，也不能创建链接或覆盖取消态。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Repo share task store")
@MainActor
struct RepoShareTaskStoreTests {

    @Test("已有摘要直接创建链接且同仓重复点击不重复提交")
    func cachedInsightSkipsGenerationAndDeduplicates() async {
        let store = RepoShareTaskStore()
        let repo = Repo.makeMinimal(owner: "starcat", name: "cached-share")
        let insight = makeInsight(oneLiner: "cached")
        var generateCount = 0
        var createCount = 0
        let operations = RepoShareOperations(
            cachedInsight: { _ in insight },
            generateInsight: { _ in
                generateCount += 1
                return insight
            },
            createShare: { _ in
                createCount += 1
                return makeResponse(url: "https://starcat.ink/s/cached")
            }
        )

        store.start(repo: repo, operations: operations)
        store.start(repo: repo, operations: operations)

        let completed = await waitUntil {
            store.isSuccessful(repoID: repo.id)
        }
        #expect(completed)
        #expect(generateCount == 0)
        #expect(createCount == 1)
        #expect(store.job(for: repo.id)?.repo.fullName == repo.fullName)
    }

    @Test("切换仓库后两个任务使用各自快照且结果互不覆盖")
    func jobsRemainIsolatedByRepository() async {
        let store = RepoShareTaskStore()
        var first = Repo.makeMinimal(owner: "starcat", name: "first")
        var second = Repo.makeMinimal(owner: "starcat", name: "second")
        // makeMinimal 的占位 id 固定为 0；测试必须模拟两个真实 GitHub repoID，
        // 否则测到的是同仓去重，而不是切换仓库后的状态隔离。
        first.id = 1
        second.id = 2
        let operations = RepoShareOperations(
            cachedInsight: { _ in nil },
            generateInsight: { repo in
                makeInsight(oneLiner: repo.fullName)
            },
            createShare: { request in
                makeResponse(url: "https://starcat.ink/s/\(request.repo.fullName)")
            }
        )

        store.start(repo: first, operations: operations)
        store.start(repo: second, operations: operations)

        let completed = await waitUntil {
            store.isSuccessful(repoID: first.id) && store.isSuccessful(repoID: second.id)
        }
        #expect(completed)
        #expect(successURL(in: store, repoID: first.id) == "https://starcat.ink/s/starcat/first")
        #expect(successURL(in: store, repoID: second.id) == "https://starcat.ink/s/starcat/second")
        #expect(store.job(for: first.id)?.repo.fullName == "starcat/first")
        #expect(store.job(for: second.id)?.repo.fullName == "starcat/second")
    }

    @Test("取消只停止目标仓库且允许重新创建")
    func cancellationIsIsolatedAndRetryable() async {
        let store = RepoShareTaskStore()
        var first = Repo.makeMinimal(owner: "starcat", name: "cancelled")
        var second = Repo.makeMinimal(owner: "starcat", name: "continues")
        first.id = 11
        second.id = 12
        let insight = makeInsight(oneLiner: "generated")
        var firstGeneration: CheckedContinuation<RepoAIInsight, Never>?
        var createdRepos: [String] = []

        let operations = RepoShareOperations(
            cachedInsight: { _ in nil },
            generateInsight: { repo in
                if repo.id == first.id {
                    return await withCheckedContinuation { continuation in
                        firstGeneration = continuation
                    }
                }
                return insight
            },
            createShare: { request in
                createdRepos.append(request.repo.fullName)
                return makeResponse(url: "https://starcat.ink/s/created")
            }
        )

        store.start(repo: first, operations: operations)
        let firstStarted = await waitUntil { firstGeneration != nil }
        #expect(firstStarted)

        // 第二个仓库可独立完成，取消 first 不能误伤它。
        store.start(repo: second, operations: operations)
        let secondCompleted = await waitUntil { store.isSuccessful(repoID: second.id) }
        #expect(secondCompleted)

        store.cancel(repoID: first.id)
        #expect(isCancelled(store.job(for: first.id)?.state))

        // 模拟不配合 cancellation、仍然晚返回结果的 provider。taskID 已失效且后续
        // checkpoint 会抛 CancellationError，因此 sharing API 不能收到 first 请求。
        firstGeneration?.resume(returning: insight)
        for _ in 0..<20 { await Task.yield() }
        #expect(isCancelled(store.job(for: first.id)?.state))
        #expect(createdRepos == [second.fullName])

        let retryOperations = RepoShareOperations(
            cachedInsight: { _ in insight },
            generateInsight: { _ in insight },
            createShare: { request in
                createdRepos.append(request.repo.fullName)
                return makeResponse(url: "https://starcat.ink/s/retried")
            }
        )
        store.retry(repoID: first.id, operations: retryOperations)

        let retryCompleted = await waitUntil { store.isSuccessful(repoID: first.id) }
        #expect(retryCompleted)
        #expect(createdRepos == [second.fullName, first.fullName])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func successURL(in store: RepoShareTaskStore, repoID: Int64) -> String? {
        guard let job = store.job(for: repoID), case .success(let url) = job.state else { return nil }
        return url
    }

    private func isCancelled(_ state: RepoShareJob.State?) -> Bool {
        guard case .cancelled = state else { return false }
        return true
    }

    private func makeInsight(oneLiner: String) -> RepoAIInsight {
        RepoAIInsight(
            oneLiner: oneLiner,
            summary: "summary",
            summaryMarkdown: nil,
            platforms: [],
            suitableFor: [],
            strengths: [],
            risks: [],
            minimalExample: nil,
            suggestedTags: [],
            model: "test",
            generatedAt: "2026-07-21T00:00:00Z",
            contextMetadata: nil,
            externalContextMarkdown: nil,
            externalContextSources: nil,
            generationContextSettings: nil
        )
    }

    private func makeResponse(url: String) -> ShareCreateResponse {
        ShareCreateResponse(
            shareUrl: url,
            shareId: UUID().uuidString,
            expiresAt: nil,
            createdAt: "2026-07-21T00:00:00Z"
        )
    }
}
