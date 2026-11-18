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

    @Test("后台分享只将生成摘要阶段的余额失败归到服务商配置")
    func billingAlertFromShareSummary() async {
        let alerts = AIBackgroundBillingAlerts()
        let store = RepoShareTaskStore(billingAlerts: alerts)
        let repo = Repo.makeMinimal(owner: "starcat", name: "share-billing")
        let provider = AIBillingProvider(id: "deepseek-work", kind: .deepSeek, name: "Work")
        let billing = AIClientError.paymentRequired(detail: "HTTP 402", provider: provider)
        let operations = RepoShareOperations(
            cachedInsight: { _ in nil },
            generateInsight: { _ in throw billing },
            createShare: { _ in Issue.record("摘要失败后不应创建链接"); return makeResponse(url: "") }
        )
        store.start(repo: repo, operations: operations)
        #expect(await waitUntil { store.latestCompletion?.outcome == .failure })
        #expect(alerts.alerts.first?.provider == provider)
        #expect(alerts.alerts.first?.reposByKind[.sharing] == [repo.id: repo.fullName])

        store.retry(repoID: repo.id, operations: RepoShareOperations(
            cachedInsight: { _ in makeInsight(oneLiner: "cached") },
            generateInsight: { _ in throw billing },
            createShare: { _ in makeResponse(url: "https://example.org/share") }
        ))
        #expect(await waitUntil { store.isSuccessful(repoID: repo.id) })
        #expect(alerts.alerts.isEmpty)
    }

    @Test("已有链接在摘要检查之前返回，UI 与公共调用共用运行中任务")
    func existingLinkSkipsAIAndPublishing() async throws {
        let store = RepoShareTaskStore()
        let repo = Repo.makeMinimal(owner: "starcat", name: "existing-share")
        var cacheLookup: CheckedContinuation<ShareCreateResponse?, Never>?
        var lookupCount = 0
        let operations = RepoShareOperations(
            cachedShare: { _ in
                lookupCount += 1
                return await withCheckedContinuation { cacheLookup = $0 }
            },
            cachedInsight: { _ in Issue.record("已有分享不应读取摘要"); return nil },
            generateInsight: { _ in Issue.record("已有分享不应生成摘要"); return makeInsight(oneLiner: "") },
            createShare: { _ in Issue.record("已有分享不应重复发布"); return makeResponse(url: "") }
        )
        store.start(repo: repo, operations: operations)
        #expect(await waitUntil { cacheLookup != nil })
        var waiting = false
        let caller = Task {
            waiting = true
            return try await store.createAndWait(repo: repo, operations: operations)
        }
        #expect(await waitUntil { waiting })
        cacheLookup?.resume(returning: makeResponse(url: "https://starcat.ink/s/existing"))
        #expect(try await caller.value == "https://starcat.ink/s/existing")
        #expect(lookupCount == 1)
    }

    @Test("成功任务再次打开会重查持久记录，避免永久保留过期结果")
    func completedJobRechecksLinkRecord() async throws {
        let store = RepoShareTaskStore()
        let repo = Repo.makeMinimal(owner: "starcat", name: "recheck-share")
        var lookups = 0
        let operations = RepoShareOperations(
            cachedShare: { _ in
                lookups += 1
                return makeResponse(url: "https://starcat.ink/s/\(lookups)")
            },
            cachedInsight: { _ in nil },
            generateInsight: { _ in makeInsight(oneLiner: "") },
            createShare: { _ in makeResponse(url: "") }
        )
        #expect(try await store.createAndWait(repo: repo, operations: operations) == "https://starcat.ink/s/1")
        #expect(try await store.createAndWait(repo: repo, operations: operations) == "https://starcat.ink/s/2")
    }

    @Test("公共分享取消等待原生成任务退出，迟到结果不能创建链接")
    func publicCancellationWaitsForUnderlyingTask() async throws {
        let store = RepoShareTaskStore()
        let repo = Repo.makeMinimal(owner: "starcat", name: "cancel-public-share")
        let insight = makeInsight(oneLiner: "late")
        var generation: CheckedContinuation<RepoAIInsight, Never>?
        var finished = false
        var createCount = 0
        let operation = Task {
            defer { finished = true }
            do {
                _ = try await store.createAndWait(repo: repo, operations: RepoShareOperations(
                    cachedInsight: { _ in nil },
                    generateInsight: { _ in await withCheckedContinuation { generation = $0 } },
                    createShare: { _ in
                        createCount += 1
                        return makeResponse(url: "https://starcat.ink/s/late")
                    }
                ))
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let started = await waitUntil { generation != nil }
        #expect(started)
        operation.cancel()
        let cancelled = await waitUntil { isCancelled(store.job(for: repo.id)?.state) }
        #expect(cancelled)
        for _ in 0..<20 { await Task.yield() }
        #expect(!finished)
        generation?.resume(returning: insight)
        #expect(await operation.value)
        #expect(createCount == 0)
    }

    @Test("公共等待接口复用缓存路径并返回真实分享地址")
    func publicWaitUsesOriginalPipeline() async throws {
        let store = RepoShareTaskStore()
        let repo = Repo.makeMinimal(owner: "starcat", name: "public-share")
        let insight = makeInsight(oneLiner: "cached")
        var generated = false
        let url = try await store.createAndWait(repo: repo, operations: RepoShareOperations(
            cachedInsight: { _ in insight },
            generateInsight: { _ in generated = true; return insight },
            createShare: { _ in makeResponse(url: "https://starcat.ink/s/public") }
        ))
        #expect(url == "https://starcat.ink/s/public")
        #expect(!generated)
        #expect(store.isSuccessful(repoID: repo.id))
    }

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
