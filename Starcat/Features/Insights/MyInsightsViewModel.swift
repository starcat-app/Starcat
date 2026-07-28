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
    ///
    /// 已有可展示快照时（含切换「全部收藏 / 知识库」）：保留旧内容、走 `.refreshing`，
    /// 由右上角 SyncIconButton 转圈表达加载；成功后再原地替换，避免内容区
    /// ProgressView 把布局高度抽空造成抖动。仅真正首次进入才用 `.loading`。
    func load(
        scope: InsightsScope,
        embeddingModel: String,
        forceRefresh: Bool = false
    ) async {
        generation &+= 1
        let requestGeneration = generation
        let hadContent = hasLoadedSnapshot
        let previousScope = snapshot.scope

        state = hadContent ? .refreshing : .loading

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
            if hadContent && previousScope == scope {
                // 同范围刷新失败：保留旧快照，标 stale。
                state = .stale
            } else if hadContent {
                // 切换范围失败：不能继续展示旧范围数字（口径已与 Picker 不一致）。
                hasLoadedSnapshot = false
                snapshot = Self.emptySnapshot(scope: scope)
                state = .failed
            } else {
                state = .failed
            }
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

    /// 真正首次进入、尚无任何快照时的占位；此时 UI 才显示内容区 ProgressView。
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
            openSSFCoverage: InsightsCoverage(completed: 0, total: 0),
            assetSummary: InsightsAssetSummary(
                dormantCount: 0,
                archivedCount: 0,
                unavailableCount: 0
            ),
            priorityRepositories: [],
            rhythmPoints: []
        )
    }
}
