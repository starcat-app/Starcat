//
//  SearchIndexStatus.swift
//  Starcat
//
//  索引卡片的展示状态。任务遍历结束不等于索引成功；
//  两类索引共用视觉语义，但保留各自的执行与统计口径。
//

import Foundation

/// 纯展示投影，方便验证失败数量不会被“已完成”状态掩盖。
enum SearchIndexStatus: Equatable {
    case idle, running, paused, building, completed, upToDate
    case failed, partialFailure, needsUpdate, textReady, noModel

    var titleKey: String {
        switch self {
        case .idle: "settings.searchIndex.layout.status.idle"
        case .running: "settings.searchIndex.layout.status.running"
        case .paused: "toolbar.backgroundTasks.paused"
        case .building: "settings.searchIndex.layout.status.building"
        case .completed: "menubar.status.completed"
        case .upToDate: "settings.searchIndex.layout.status.upToDate"
        case .failed: "menubar.status.failed"
        case .partialFailure: "settings.searchIndex.layout.status.partialFailure"
        case .needsUpdate: "settings.searchIndex.layout.status.needsUpdate"
        case .textReady: "settings.searchIndex.layout.status.textReady"
        case .noModel: "settings.retrieval.index.noModel"
        }
    }

    /// 活任务优先使用实时状态；空闲时还原落盘结果，全部失败应显示失败而非成功。
    static func repository(
        status: SemanticIndexBuilderStatus,
        failures: Int,
        lastRun: SemanticIndexPrefetchLastRun?
    ) -> Self {
        switch status {
        case .running: return .running
        case .paused: return .paused
        case .failed: return .failed
        case .alreadyUpToDate: return .upToDate
        case .completed(_, let total): return completion(failures: failures, total: total)
        case .idle:
            guard let lastRun else { return .idle }
            switch lastRun.outcome {
            case .failed: return .failed
            case .alreadyUpToDate: return .upToDate
            case .completed: return completion(failures: lastRun.failures, total: lastRun.total)
            }
        }
    }

    /// 文本可检索与向量就绪分别表达；无模型时不能把文本覆盖率表述为向量完成率。
    static func knowledge(
        status: RAGIndexingStatus,
        coverage: RAGIndexStatusProjection?,
        hasModel: Bool
    ) -> Self {
        switch status {
        case .failed: return .failed
        case .fetchingReadmes, .building, .embedding: return .building
        case .idle, .completed:
            guard let coverage else { return .idle }
            if coverage.failedChunks > 0 { return .partialFailure }
            if !hasModel { return coverage.readyChunks > 0 ? .textReady : .noModel }
            if coverage.pendingChunks > 0 || coverage.staleChunks > 0 { return .needsUpdate }
            if case .completed = status { return .completed }
            return .idle
        }
    }

    private static func completion(failures: Int, total: Int) -> Self {
        guard failures > 0 else { return .completed }
        return total > 0 && failures >= total ? .failed : .partialFailure
    }
}
