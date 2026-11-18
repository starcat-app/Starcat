//
//  RepoShareTaskStore.swift
//  Starcat
//
//  AI 分享页创建任务的应用会话级状态中心，窗口与 CLI 共用。
//
//  模块职责：
//  - 以 repoID 隔离多个分享任务，防止用户切换仓库后异步结果串仓；
//  - 在网络/AI 工作开始前同步发布进度，让 Sheet 可以立即出现；
//  - Sheet 收起后继续持有 Task，并允许用户切回仓库恢复进度或结果；
//  - 复用 RepoAIInsightService.cachedInsightFast(for:) 的跨语言缓存语义，禁止
//    分享功能另写一套摘要缓存选择规则。
//
//  关键约束：
//  - 每次状态回写同时校验 repoID + taskID。旧任务即使晚到，也不能覆盖重试任务；
//  - 同一仓库只保留一个任务。重复点击只负责重新打开 Sheet，不重复消耗 AI 配额；
//  - 运行中任务只在进程内继续；成功链接由 ShareAPI 单独持久化，不做系统后台调度。
//

import Foundation
import Observation

/// 分享任务依赖的最小操作集合。
///
/// 使用 closure 而不是让状态中心直接依赖整个 AppDependencies：任务状态因此可以独立
/// 单测，同时生产环境仍直接复用现有 AI service 与 ShareAPI，不引入第二套业务实现。
@MainActor
struct RepoShareOperations {
    var cachedShare: @MainActor (Repo) async -> ShareCreateResponse? = { _ in nil }
    let cachedInsight: @MainActor (Repo) async throws -> RepoAIInsight?
    let generateInsight: @MainActor (Repo) async throws -> RepoAIInsight
    let createShare: @MainActor (ShareRepoRequest) async throws -> ShareCreateResponse
}

/// 单个仓库的一次 AI 分享创建任务。
struct RepoShareJob: Identifiable {
    enum State: Equatable {
        case checkingCache
        case generatingSummary
        case creatingLink
        case cancelled
        case success(String)
        case failure(String)

        var isRunning: Bool {
            switch self {
            case .checkingCache, .generatingSummary, .creatingLink:
                return true
            case .cancelled, .success, .failure:
                return false
            }
        }

        var isSuccessful: Bool {
            if case .success = self { return true }
            return false
        }
    }

    /// 任务身份而非 repo 身份；重试会生成新 UUID，用于拒绝旧异步回调。
    let id: UUID
    /// 点击创建时的不可变仓库快照。后续 selectedRepo 变化不会影响请求内容。
    let repo: Repo
    var state: State
}

/// `.sheet(item:)` 的稳定路由值。Sheet 展示哪个任务只由 repoID 决定，不跟随当前选中仓库。
struct RepoSharePresentation: Identifiable {
    let repoID: Int64
    var id: Int64 { repoID }
}

/// 后台任务完成事件。UUID 保证同一仓库多次重试完成时仍会触发 SwiftUI onChange。
struct RepoShareCompletionNotice: Equatable {
    enum Outcome: Equatable {
        case success
        case failure
    }

    let id = UUID()
    let repoID: Int64
    let repoFullName: String
    let outcome: Outcome
}

@MainActor
@Observable
final class RepoShareTaskStore {
    private(set) var jobs: [Int64: RepoShareJob] = [:]
    private(set) var latestCompletion: RepoShareCompletionNotice?

    /// Task 句柄本身不是 UI 状态；忽略 Observation，避免任务字典变化触发无关重绘。
    @ObservationIgnored private var tasks: [Int64: Task<Void, Never>] = [:]
    private let billingAlerts: AIBackgroundBillingAlerts?

    init(billingAlerts: AIBackgroundBillingAlerts? = nil) {
        self.billingAlerts = billingAlerts
    }

    func job(for repoID: Int64) -> RepoShareJob? {
        jobs[repoID]
    }

    func isRunning(repoID: Int64) -> Bool {
        jobs[repoID]?.state.isRunning == true
    }

    func isSuccessful(repoID: Int64) -> Bool {
        jobs[repoID]?.state.isSuccessful == true
    }

    /// 公共任务等待同一状态机真实完成；保留缓存回退、取消与防止迟到响应创建链接的约束。
    func createAndWait(repo: Repo, operations: RepoShareOperations) async throws -> String {
        start(repo: repo, operations: operations)
        let task = tasks[repo.id]
        let taskID = jobs[repo.id]?.id
        return try await withTaskCancellationHandler {
            // cancelled 是即时 UI 反馈，不能作为底层已退出的证明；切库屏障必须等待原 Task。
            await task?.value
            try Task.checkCancellation()
            guard jobs[repo.id]?.id == taskID else { throw CancellationError() }
            switch jobs[repo.id]?.state {
            case .success(let url): return url
            case .failure(let message): throw StarcatPublicCapabilityError(code: "SHARE_FAILED", message: message)
            case .cancelled: throw CancellationError()
            default: throw StarcatPublicCapabilityError(code: "SHARE_FAILED", message: "The share operation did not produce a result.")
            }
        } onCancel: {
            task?.cancel()
            Task { @MainActor in
                if self.jobs[repo.id]?.id == taskID { self.cancel(repoID: repo.id) }
            }
        }
    }

    /// 运行中直接恢复；成功结果再次打开时重查持久记录，允许过期链接重新创建。
    func start(repo: Repo, operations: RepoShareOperations) {
        guard jobs[repo.id] == nil || jobs[repo.id]?.state.isSuccessful == true else { return }
        launch(repo: repo, operations: operations)
    }

    /// AI 摘要属于账号数据库；切号前必须取消并等待，公开分享链接记录继续保留。
    func resetForAccountChange() async {
        let pending = Array(tasks.values)
        for repoID in Array(tasks.keys) { cancel(repoID: repoID) }
        for task in pending { await task.value }
        jobs.removeAll()
        latestCompletion = nil
    }

    /// 失败或用户取消后允许重新创建；运行中与成功态保持单任务语义。
    func retry(repoID: Int64, operations: RepoShareOperations) {
        guard let job = jobs[repoID] else { return }
        switch job.state {
        case .cancelled, .failure:
            launch(repo: job.repo, operations: operations)
        case .checkingCache, .generatingSummary, .creatingLink, .success:
            return
        }
    }

    /// 取消指定仓库当前正在执行的分享任务。
    ///
    /// 除了调用 `Task.cancel()`，还要立即替换 taskID。第三方 provider 如果没有及时响应
    /// cancellation，旧任务即使稍后返回，也会因为身份不匹配而无法创建链接或覆盖取消态。
    func cancel(repoID: Int64) {
        guard let job = jobs[repoID], job.state.isRunning else { return }
        let task = tasks.removeValue(forKey: repoID)
        jobs[repoID] = RepoShareJob(id: UUID(), repo: job.repo, state: .cancelled)
        task?.cancel()
    }

    private func launch(repo: Repo, operations: RepoShareOperations) {
        let taskID = UUID()
        jobs[repo.id] = RepoShareJob(id: taskID, repo: repo, state: .checkingCache)

        // 先写入 checkingCache，再创建 Task：SwiftUI 下一帧就能展示 Sheet，不会等待任何 IO。
        tasks[repo.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(repo: repo, taskID: taskID, operations: operations)
        }
    }

    private func execute(repo: Repo, taskID: UUID, operations: RepoShareOperations) async {
        defer {
            // 只有当前任务可以清理自己的句柄；晚到的旧任务不能清掉重试任务。
            if jobs[repo.id]?.id == taskID {
                tasks[repo.id] = nil
            }
        }

        do {
            if let existing = await operations.cachedShare(repo) {
                try Task.checkCancellation()
                finish(repo: repo, taskID: taskID, state: .success(existing.shareUrl), outcome: .success)
                return
            }
            let insight: RepoAIInsight
            if let cached = try await operations.cachedInsight(repo) {
                try Task.checkCancellation()
                insight = cached
            } else {
                guard update(repoID: repo.id, taskID: taskID, state: .generatingSummary) else { return }
                insight = try await operations.generateInsight(repo)
                try Task.checkCancellation()
            }

            guard update(repoID: repo.id, taskID: taskID, state: .creatingLink) else { return }
            try Task.checkCancellation()
            let response = try await operations.createShare(Self.makeRequest(repo: repo, insight: insight))
            try Task.checkCancellation()
            finish(repo: repo, taskID: taskID, state: .success(response.shareUrl), outcome: .success)
        } catch is CancellationError {
            // 用户按钮已先发布 cancelled 并替换 taskID；这个 update 只兜底处理其它取消来源。
            _ = update(repoID: repo.id, taskID: taskID, state: .cancelled)
        } catch let error as RepoAIInsightError {
            let message: String
            switch error {
            case .missingAPIKey:
                message = String.l10n("repo.share.error.missingAIConfig.modelsSettings")
            case .missingProvider, .invalidJSON:
                message = error.localizedDescription
            }
            finish(repo: repo, taskID: taskID, state: .failure(message), outcome: .failure)
        } catch {
            if jobs[repo.id]?.id == taskID, case .generatingSummary = jobs[repo.id]?.state {
                billingAlerts?.record(error, kind: .sharing, repo: repo)
            }
            finish(repo: repo, taskID: taskID, state: .failure(error.localizedDescription), outcome: .failure)
        }
    }

    @discardableResult
    private func update(repoID: Int64, taskID: UUID, state: RepoShareJob.State) -> Bool {
        guard var job = jobs[repoID], job.id == taskID else { return false }
        job.state = state
        jobs[repoID] = job
        return true
    }

    private func finish(
        repo: Repo,
        taskID: UUID,
        state: RepoShareJob.State,
        outcome: RepoShareCompletionNotice.Outcome
    ) {
        guard update(repoID: repo.id, taskID: taskID, state: state) else { return }
        if outcome == .success { billingAlerts?.resolve(kind: .sharing, repoID: repo.id) }
        latestCompletion = RepoShareCompletionNotice(
            repoID: repo.id,
            repoFullName: repo.fullName,
            outcome: outcome
        )
    }

    /// 将 Repo + 已有 Insight 投影为 sharing-api 契约。请求使用点击时的 repo 快照，
    /// 因此用户切换列表选择不会改变正在执行任务的 owner/name 或统计字段。
    private static func makeRequest(repo: Repo, insight: RepoAIInsight) -> ShareRepoRequest {
        let repoDTO = ShareRepoDTO(
            fullName: repo.fullName,
            description: repo.description,
            language: repo.language,
            starsCount: repo.starsCount,
            forksCount: repo.forksCount,
            // 真实 Watch；勿用 watchersCount（stars list 里常与 stars 同值）。
            subscribersCount: repo.subscribersCount ?? 0,
            topics: repo.topicsArray,
            homepage: repo.homepage,
            url: repo.htmlUrl
        )
        let tags = insight.suggestedTags.map {
            ShareTagDTO(name: $0.name, confidence: $0.confidence)
        }
        let summaryDTO = ShareAISummaryDTO(
            oneLiner: insight.oneLiner,
            summary: insight.summary,
            platforms: insight.platforms,
            suitableFor: insight.suitableFor,
            strengths: insight.strengths,
            risks: insight.risks,
            suggestedTags: tags
        )
        return ShareRepoRequest(repo: repoDTO, aiSummary: summaryDTO)
    }
}

extension AppDependencies {
    /// UI 和公共接口从同一处装配分享用例，避免缓存/生成选择与 API 版本逐渐分叉。
    func makeRepoShareOperations() -> RepoShareOperations {
        RepoShareOperations(
            cachedShare: { await self.shareAPI.cachedRepoShare(fullName: $0.fullName) },
            cachedInsight: { try await self.repoAIInsightService.cachedInsightFast(for: $0) },
            generateInsight: { (try await self.repoAIInsightService.generateInsight(for: $0)).insight },
            createShare: { try await self.shareAPI.shareRepo(request: $0) }
        )
    }
}
