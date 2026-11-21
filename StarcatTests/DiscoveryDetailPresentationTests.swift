//
//  DiscoveryDetailPresentationTests.swift
//  StarcatTests
//
//  验证推荐详情先展示快照，资料请求的等待、失败和过期回包均不能清空 Hero。
//

import Foundation
import Testing
@testable import Starcat

/// 使用可控的挂起请求验证真实展示状态，无网络、计时等待或 WebKit 依赖。
@Suite("Discovery detail presentation")
@MainActor
struct DiscoveryDetailPresentationTests {
    @Test("慢资料请求期间立即保留当前 Hero，缺失计数和日期不是伪造零值")
    func snapshotRemainsVisibleWhileMetadataIsPending() async throws {
        let model = DiscoveryDetailPresentation()
        let registry = StarredRegistry()
        let item = recommendation(1)
        model.present(item: item, requiresCompleteMetadata: true, registry: registry)
        let requestID = try #require(model.metadataRequestID)
        let gate = MetadataGate()
        let task = Task {
            await model.resolveMetadata(requestID: requestID, registry: registry) {
                try await gate.resolve()
            }
        }
        await gate.waitForRequest()
        #expect(model.repo?.id == item.repoID)
        #expect(model.repo?.description == item.description)
        #expect(model.repo?.language == "Swift")
        #expect(model.repo?.starsCount == 12)
        #expect(model.repo?.forksCount == 3)
        #expect(model.repo?.subscribersCount == nil)
        #expect(model.repo?.openIssuesCount == nil)
        #expect(model.repo?.createdAt == nil)
        #expect(model.repo?.updatedAt == nil)
        #expect(!model.metadataFailed)

        var complete = item.toEphemeralRepo(isStarred: false)
        complete.subscribersCount = 7
        complete.createdAt = "2026-01-01T00:00:00Z"
        complete.updatedAt = "2026-11-17T00:00:00Z"
        gate.finish(.success(complete))
        await task.value
        #expect(model.repo == complete)
    }

    @Test("资料失败保留 Hero，局部重试保留快照，真实零值可以正常补齐")
    func failureAndRetryKeepSnapshot() async throws {
        let model = DiscoveryDetailPresentation()
        let registry = StarredRegistry()
        let item = recommendation(2)
        model.present(item: item, requiresCompleteMetadata: true, registry: registry)
        let requestID = try #require(model.metadataRequestID)
        let snapshot = model.repo
        await model.resolveMetadata(requestID: requestID, registry: registry) {
            throw URLError(.notConnectedToInternet)
        }
        #expect(model.repo == snapshot)
        #expect(model.metadataFailed)

        model.retryMetadata()
        let retryID = try #require(model.metadataRequestID)
        #expect(retryID != requestID)
        #expect(model.repo == snapshot)
        #expect(!model.metadataFailed)
        var complete = item.toEphemeralRepo(isStarred: false)
        complete.subscribersCount = 0
        await model.resolveMetadata(requestID: retryID, registry: registry) {
            complete
        }
        #expect(model.repo?.subscribersCount == 0)
        #expect(!model.metadataFailed)
    }

    @Test("A → B → C 和 A → B → A 都不能发布旧请求的成功或失败")
    func staleResponsesCannotReplaceCurrentSelection() async throws {
        for (finalID, fails) in [(Int64(3), false), (Int64(1), false), (Int64(1), true)] {
            let model = DiscoveryDetailPresentation()
            let registry = StarredRegistry()
            let first = recommendation(1)
            model.present(item: first, requiresCompleteMetadata: true, registry: registry)
            let requestID = try #require(model.metadataRequestID)
            let gate = MetadataGate()
            let task = Task {
                await model.resolveMetadata(requestID: requestID, registry: registry) {
                    try await gate.resolve()
                }
            }
            await gate.waitForRequest()
            model.present(item: recommendation(2), requiresCompleteMetadata: true, registry: registry)
            model.present(item: recommendation(finalID), requiresCompleteMetadata: true, registry: registry)
            let snapshot = model.repo
            var stale = first.toEphemeralRepo(isStarred: false)
            stale.subscribersCount = 99
            gate.finish(fails ? .failure(URLError(.timedOut)) : .success(stale))
            await task.value
            #expect(model.repo == snapshot)
            #expect(!model.metadataFailed)
        }
    }

    @Test("取消不报错，同仓刷新保留已补齐字段，普通探索保留已有计数")
    func cancellationAndRefreshPreserveCurrentContent() async throws {
        let model = DiscoveryDetailPresentation()
        let registry = StarredRegistry()
        let item = recommendation(4)
        model.present(item: item, requiresCompleteMetadata: true, registry: registry)
        let requestID = try #require(model.metadataRequestID)
        let gate = MetadataGate()
        let task = Task {
            await model.resolveMetadata(requestID: requestID, registry: registry) {
                try await gate.resolve()
            }
        }
        await gate.waitForRequest()
        task.cancel()
        var complete = item.toEphemeralRepo(isStarred: false)
        complete.subscribersCount = 8
        gate.finish(.success(complete))
        await task.value
        #expect(model.repo?.subscribersCount == nil)
        #expect(!model.metadataFailed)

        model.retryMetadata()
        let retryID = try #require(model.metadataRequestID)
        await model.resolveMetadata(requestID: retryID, registry: registry) { complete }
        model.present(item: item, requiresCompleteMetadata: true, registry: registry)
        #expect(model.repo?.subscribersCount == 8)
        model.present(item: item, requiresCompleteMetadata: false, registry: registry)
        #expect(model.metadataRequestID == nil)
        #expect(model.repo?.subscribersCount == nil)
    }

    /// 复用每日推荐的真实 DTO 适配路径，避免测试与未知字段约定各维护一套。
    private func recommendation(_ repoID: Int64) -> DiscoveryRepoDTO {
        RepoRecommendationItem(
            repoID: repoID, fullName: "owner/repo\(repoID)", description: "Snapshot",
            language: "Swift", stars: 12, forks: 3, archived: false,
            score: 0.5, source: "starcat_trained", reasons: []
        ).historyDiscoveryItem
    }
}

/// 明确握手后才释放结果，覆盖不响应取消的旧回包，不靠 sleep 猜测任务是否已开始。
@MainActor
private final class MetadataGate {
    private var resultContinuation: CheckedContinuation<Repo, any Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func resolve() async throws -> Repo {
        try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitForRequest() async {
        guard resultContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func finish(_ result: Result<Repo, any Error>) {
        resultContinuation?.resume(with: result)
        resultContinuation = nil
    }
}
