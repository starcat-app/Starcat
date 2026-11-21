//
//  MyInsightsViewModel.swift
//  Starcat
//
//  「我的洞察」共用的统计加载状态。同份快照在四个统计页间复用。
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

    /// 选择器和账号库可以先于 `.task` 更新，读取时也必须校验这份身份。
    struct Request: Hashable, Sendable {
        let scope: InsightsScope
        let accountID: Int64?
        let databaseRevision: UInt64
        let embeddingModel: String
    }

    private let provider: any MyInsightsSnapshotProviding
    private var result: (request: Request, snapshot: MyInsightsSnapshot)?
    private var activeRequest: Request?
    private var loadState: MyInsightsLoadState = .idle
    private var generation: UInt64 = 0

    init(provider: any MyInsightsSnapshotProviding) {
        self.provider = provider
    }

    func snapshot(for request: Request) -> MyInsightsSnapshot? {
        result?.request == request ? result?.snapshot : nil
    }

    func state(for request: Request) -> MyInsightsLoadState {
        activeRequest == request ? loadState : .idle
    }

    /// 身份未变时保留内容。切换身份后，数字、时间和下钻必须一起等待新快照。
    func load(_ request: Request, forceRefresh: Bool = false) async {
        guard !Task.isCancelled else { return }
        generation &+= 1
        let requestGeneration = generation
        let hadContent = snapshot(for: request) != nil
        activeRequest = request
        if !hadContent { result = nil }
        loadState = hadContent ? .refreshing : .loading

        do {
            if forceRefresh {
                await provider.invalidate()
                try Task.checkCancellation()
                guard requestGeneration == generation else { return }
            }
            let loaded = try await provider.load(
                scope: request.scope,
                embeddingModel: request.embeddingModel
            )
            try Task.checkCancellation()
            guard requestGeneration == generation else { return }
            result = (request, loaded)
            loadState = .loaded
        } catch {
            guard requestGeneration == generation else { return }
            if Task.isCancelled || error is CancellationError {
                loadState = hadContent ? .loaded : .idle
            } else {
                loadState = hadContent ? .stale : .failed
            }
        }
    }

    func refresh(_ request: Request) async {
        guard activeRequest == request, loadState != .loading, loadState != .refreshing else { return }
        await load(request, forceRefresh: true)
    }
}
