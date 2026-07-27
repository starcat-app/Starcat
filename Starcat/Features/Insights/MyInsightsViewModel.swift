//
//  MyInsightsViewModel.swift
//  Starcat
//
//  “我的洞察”主窗口级加载状态。中栏和详情栏必须消费同一个快照，避免各自发起查询后
//  出现数字短暂不一致。
//

import Foundation
import Observation

/// “我的洞察”的可见加载状态。
///
/// 首次失败与刷新失败分开表达：首次失败没有可展示数据；刷新失败则保留旧快照，
/// 让短暂数据库错误不会把已经可用的统计清空。
enum MyInsightsLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case refreshing
    case failed
    case stale
}

/// 协调范围切换、账号数据库切换、Embedding 模型变化和手动刷新。
@MainActor
@Observable
final class MyInsightsViewModel {

    private(set) var snapshot: MyInsightsSnapshot
    private(set) var state: MyInsightsLoadState = .idle

    private let provider: any MyInsightsSnapshotProviding
    private var generation: UInt64 = 0
    private var hasLoadedSnapshot = false

    init(
        provider: any MyInsightsSnapshotProviding,
        initialScope: InsightsScope = .starred
    ) {
        self.provider = provider
        self.snapshot = Self.emptySnapshot(scope: initialScope)
    }

    var hasContent: Bool {
        hasLoadedSnapshot
    }

    var isInitialLoading: Bool {
        state == .idle || state == .loading
    }

    var isRefreshing: Bool {
        state == .refreshing
    }

    var hasInitialError: Bool {
        state == .failed && !hasLoadedSnapshot
    }

    var showsStaleWarning: Bool {
        state == .stale && hasLoadedSnapshot
    }

    /// 加载指定范围。调用方用 scope、数据库 revision 和 Embedding model 组成 task id，
    /// 因此任一输入变化都会进入这里；generation 防止旧查询晚到后覆盖新范围。
    func load(
        scope: InsightsScope,
        embeddingModel: String,
        forceRefresh: Bool = false
    ) async {
        generation &+= 1
        let requestGeneration = generation
        let keepsCurrentSnapshot = hasLoadedSnapshot && snapshot.scope == scope

        if !keepsCurrentSnapshot {
            hasLoadedSnapshot = false
            snapshot = Self.emptySnapshot(scope: scope)
        }
        state = keepsCurrentSnapshot ? .refreshing : .loading

        if forceRefresh {
            await provider.invalidate()
        }

        do {
            let loaded = try await provider.load(
                scope: scope,
                embeddingModel: embeddingModel
            )
            guard requestGeneration == generation else { return }
            snapshot = loaded
            hasLoadedSnapshot = true
            state = .loaded
        } catch is CancellationError {
            // `.task(id:)` 取消旧范围后，新任务会立即接管状态；旧任务不能覆盖新状态。
            return
        } catch {
            guard requestGeneration == generation else { return }
            state = keepsCurrentSnapshot ? .stale : .failed
        }
    }

    func refresh(scope: InsightsScope, embeddingModel: String) async {
        guard state != .loading, state != .refreshing else { return }
        await load(
            scope: scope,
            embeddingModel: embeddingModel,
            forceRefresh: true
        )
    }

    /// 首次查询前提供结构完整但无数值的占位快照；UI 会显示 ProgressView，
    /// 不会把这些零值伪装成真实统计。
    private static func emptySnapshot(scope: InsightsScope) -> MyInsightsSnapshot {
        MyInsightsSnapshot(
            scope: scope,
            generatedAt: .distantPast,
            metrics: [],
            statusItems: [],
            languageItems: [],
            topicItems: [],
            licenseItems: [],
            actionItems: [],
            healthCoverage: InsightsCoverage(completed: 0, total: 0),
            openSSFCoverage: InsightsCoverage(completed: 0, total: 0)
        )
    }
}
