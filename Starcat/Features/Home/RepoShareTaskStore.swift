//
//  RepoShareTaskStore.swift
//  Starcat
//
//  AI 分享页创建任务的窗口会话级状态中心。
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
//  - “后台继续”只指 Starcat 进程内继续，不做跨进程持久化或系统后台调度。
//

import Foundation
import Observation

/// 分享任务依赖的最小操作集合。
///
/// 使用 closure 而不是让状态中心直接依赖整个 AppDependencies：任务状态因此可以独立
/// 单测，同时生产环境仍直接复用现有 AI service 与 ShareAPI，不引入第二套业务实现。
@MainActor
struct RepoShareOperations {
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

    func job(for repoID: Int64) -> RepoShareJob? {
        jobs[repoID]
    }

    func isRunning(repoID: Int64) -> Bool {
        jobs[repoID]?.state.isRunning == true
    }

    func isSuccessful(repoID: Int64) -> Bool {
        jobs[repoID]?.state.isSuccessful == true
    }

    /// 首次创建。已有运行中、成功或失败结果时都不重复提交，由调用方直接打开现有 Sheet。
    func start(repo: Repo, operations: RepoShareOperations) {
        guard jobs[repo.id] == nil else { return }
        launch(repo: repo, operations: operations)
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
                message = String.l10n("repo.share.error.missingAIConfig")
            case .missingProvider, .invalidJSON:
                message = error.localizedDescription
            }
            finish(repo: repo, taskID: taskID, state: .failure(message), outcome: .failure)
        } catch {
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
