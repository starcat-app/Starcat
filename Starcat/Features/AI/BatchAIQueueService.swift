//
//  BatchAIQueueService.swift
//  Starcat
//
//  HOM-52 批量未分类仓库 AI 整理 - 队列状态机 + UI 可观察对象。
//
//  模块职责：
//  - 维护单一全局批量整理队列（同时只跑一个批次，避免 AI 配额尖刺）。
//  - 串行处理 jobs：取下一个 queued → 调 RepoAIInsightService.generateInsight
//    → 按 Options 落库标签 → 写终态。
//  - 暴露 @Observable 状态供 BatchAIQueuePanel / 入口 Banner 直接绑定。
//
//  关键约束：
//  - **会话内存级**：队列、进度、失败记录不落库。重启 app 即清空。
//    设计理由：(1) 已生成的 AI 摘要存在 ai_summaries 表，重启后再次整理会命中 cache
//    不重复消耗配额；(2) 落库要新增 batch_ai_jobs 表 + 迁移 + Repository，
//    与 dong4j 强调的"最小代码"冲突；(3) 用户预期的"后台继续"指 panel 关闭后仍跑，
//    而非跨进程恢复——若未来真有需求，再独立 V8 迁移即可。
//  - **串行执行**：一次只处理一个 repo。AI provider 多数有速率限制，且串行能让
//    "暂停"语义干净（当前 job 跑完即停）。如需提速，后续可加 concurrency 配置。
//  - **重试不可重试错误甄别**：API Key 缺失 / Provider 缺失这类配置错误**不消耗重试次数**——
//    用户没改配置之前永远不会成功，重试只会让 panel 失败计数误增。
//

import Foundation
import Observation

@MainActor
@Observable
final class BatchAIQueueService {

    // MARK: - 可观察状态（@Observable 自动生成 didSet / willSet 跟踪）

    /// 当前队列中的所有 jobs（含已完成 / 已失败 / 已忽略 / 仍在排队）。
    /// UI 用 ForEach 直接绑定。新批次开始时整个数组被替换（不保留上一轮记录）。
    private(set) var jobs: [BatchAIJob] = []

    /// 本次启动时的执行配置。空表示当前没有进行中的批次。
    private(set) var options: BatchAIQueueOptions?

    /// 是否正在处理（取出 job → 调 AI → 落库 的整个生命周期内为 true）。
    /// 进入暂停态时为 false，但 jobs 仍保留以便用户继续。
    private(set) var isRunning: Bool = false

    /// 是否被用户暂停。`isRunning && !isPaused` 才会拉下一个 job。
    private(set) var isPaused: Bool = false

    /// 当前正在处理的 job repoId（用于 UI 高亮当前行）。
    private(set) var currentJobId: Int64?

    /// 本次批次的开始时刻，用于估算剩余时间（已用时 / 完成数 → 平均耗时）。
    private(set) var startedAt: Date?

    /// 用户主动取消标志位：在 processNext 循环开始处轮询，命中即跳出。
    private var cancelRequested: Bool = false

    // MARK: - 依赖（按 AppDependencies 装配顺序注入）

    private let insightService: RepoAIInsightService
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol
    private let aiSummaryRepository: any AISummaryRepositoryProtocol

    /// 标签应用后通知外部刷新 Sidebar 计数 / 当前列表。
    /// 设计上用闭包而非 NotificationCenter，避免跨模块字符串通知名飘移。
    var onTagsChanged: (() -> Void)?

    init(
        insightService: RepoAIInsightService,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        aiSummaryRepository: any AISummaryRepositoryProtocol
    ) {
        self.insightService = insightService
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
        self.aiSummaryRepository = aiSummaryRepository
    }

    // MARK: - 派生状态（panel UI 用）

    var totalCount: Int { jobs.count }
    var completedCount: Int { jobs.lazy.filter { $0.status == .completed }.count }
    var failedCount: Int { jobs.lazy.filter { $0.status == .failed }.count }
    var ignoredCount: Int { jobs.lazy.filter { $0.status == .ignored }.count }
    var queuedCount: Int { jobs.lazy.filter { $0.status == .queued }.count }
    var finishedCount: Int { completedCount + failedCount + ignoredCount }

    /// 全部 job 都进入终态时认为本次批次结束。
    var isFinished: Bool { !jobs.isEmpty && finishedCount == jobs.count }

    /// 失败列表（按时间倒序），用于 UI 顶部"X 个失败"红色提示与"重试全部"按钮。
    var failedJobs: [BatchAIJob] {
        jobs.filter { $0.status == .failed }
    }

    /// 估算剩余时间（秒）。
    ///
    /// 公式：已用时 / 完成数 × 剩余数。仅当 finishedCount >= 1 才有意义，
    /// 否则返回 nil。AI 调用耗时方差大，UI 端展示用模糊措辞"约 N 分钟"。
    var estimatedTimeRemaining: TimeInterval? {
        guard let startedAt, finishedCount > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        let avgPerJob = elapsed / Double(finishedCount)
        let remaining = totalCount - finishedCount
        guard remaining > 0 else { return 0 }
        return avgPerJob * Double(remaining)
    }

    // MARK: - 公共 API

    /// 启动一批新的整理任务。
    ///
    /// 行为：清掉上一批次的 jobs（即使是已完成的）→ 把传入 repos 全部入队 → 启动循环。
    /// 如果当前正在跑且未结束，会被拒绝（调用方应先 cancel）。
    func start(repos: [Repo], options: BatchAIQueueOptions) {
        guard !isRunning else {
            AppLog.ai.warning("[batch-ai] start() ignored: already running")
            return
        }
        guard options.isValidForStart, !repos.isEmpty else {
            AppLog.ai.warning("[batch-ai] start() ignored: invalid options or empty repo list")
            return
        }
        self.options = options
        self.jobs = repos.map { BatchAIJob(repoId: $0.id, repoFullName: $0.fullName) }
        self.repoCache = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        self.isPaused = false
        self.isRunning = true
        self.cancelRequested = false
        self.startedAt = Date()
        self.currentJobId = nil
        AppLog.ai.notice("[batch-ai] start: count=\(repos.count, privacy: .public), autoApplyTags=\(options.autoApplyTags, privacy: .public), threshold=\(options.confidenceThreshold, privacy: .public)")
        Task { await runLoop() }
    }

    /// 暂停。当前 job 跑完即停；不杀进行中的 AI 调用（强中断会触发 partial 状态难处理）。
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        AppLog.ai.notice("[batch-ai] paused")
    }

    /// 继续。
    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        AppLog.ai.notice("[batch-ai] resumed")
        Task { await runLoop() }
    }

    /// 取消整批。
    ///
    /// 用户反馈（HOM-52 2026-06-06 17:26 dong4j）：原版本只设标志位，
    /// AI 调用可能要 5-10 秒，用户看不到任何视觉反馈以为"按钮没效果"。
    ///
    /// 改进后的行为：
    /// 1. **立即清空所有 queued jobs** —— 列表长度立刻下降，给用户可见反馈。
    /// 2. **设置 cancelRequested 标志**，runLoop 在当前 await 完成后立刻 break。
    /// 3. **派生 isCancelling 状态**供 UI 显示"正在终止..."提示，按钮 disable。
    /// 4. **当前 in-flight 的 AI 调用不强制中断**：OpenAIClient 没有 cancel 通道，
    ///    且强中断后的 partial response 处理代价大；当前 job 跑完即丢弃结果。
    /// 5. **runLoop 退出时**把残留 processing 状态的 job 标记为 failed("用户取消")，
    ///    避免 UI 上留下"永远在 processing"的孤儿行。
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        isPaused = false
        // 立即清空所有未开始的 job，给用户立即可见的反馈。
        // 已完成 / 已忽略 / 已失败 / processing 的 job 保留，不破坏历史记录。
        let removed = jobs.filter { $0.status == .queued }.count
        jobs.removeAll { $0.status == .queued }
        AppLog.ai.notice("[batch-ai] cancel requested, cleared \(removed, privacy: .public) queued jobs")
    }

    /// UI 派生：true 时显示"正在终止当前 AI 调用..."提示。
    /// 触发后 runLoop 仍在等 in-flight job 跑完（最多几十秒），需要给用户解释。
    var isCancelling: Bool { cancelRequested && isRunning }

    /// 重置：清空全部 jobs / options / 进度。
    /// 调用方场景：用户点 panel 的"关闭"按钮且已 finished，或新开一批整理前。
    func reset() {
        guard !isRunning else { return }
        jobs = []
        options = nil
        startedAt = nil
        currentJobId = nil
        cancelRequested = false
    }

    /// 重试单个失败的 job。
    /// - 把 attempts 归零、status 重置为 queued。
    /// - 如果当前循环不在跑（已 finished），重新启动循环。
    func retry(jobId: Int64) {
        guard let idx = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }
        guard jobs[idx].status == .failed else { return }
        jobs[idx].status = .queued
        jobs[idx].attempts = 0
        jobs[idx].errorMessage = nil
        jobs[idx].finishedAt = nil
        if !isRunning {
            isRunning = true
            isPaused = false
            cancelRequested = false
            Task { await runLoop() }
        }
    }

    /// 重试全部失败。批量版本，避免 UI 端循环触发 N 次 runLoop。
    func retryAllFailed() {
        var touched = false
        for idx in jobs.indices where jobs[idx].status == .failed {
            jobs[idx].status = .queued
            jobs[idx].attempts = 0
            jobs[idx].errorMessage = nil
            jobs[idx].finishedAt = nil
            touched = true
        }
        if touched, !isRunning {
            isRunning = true
            isPaused = false
            cancelRequested = false
            Task { await runLoop() }
        }
    }

    // MARK: - 主循环

    /// 串行拉取 queued 的 job 处理，直到全部进入终态、被暂停或被取消。
    ///
    /// 注意：方法本身是 async；start / resume / retry 都 fire-and-forget 调用一次，
    /// 不重入（循环开始时若已无 queued 直接退出）。多次触发只会再 enter 一次循环但
    /// 立刻退出，不会产生并发。
    private func runLoop() async {
        guard let options else { return }

        while true {
            if cancelRequested {
                // 取消：把所有 queued 标 failed("用户取消")？不——保留 queued 状态，
                // 让用户能在终止后继续。取消只意味着退出循环。
                break
            }
            if isPaused { break }
            guard let nextIdx = jobs.firstIndex(where: { $0.status == .queued }) else {
                break
            }

            currentJobId = jobs[nextIdx].repoId
            jobs[nextIdx].status = .processing
            jobs[nextIdx].attempts += 1
            let jobSnapshot = jobs[nextIdx]

            do {
                let result = try await processSingle(jobId: jobSnapshot.repoId, options: options)
                // 用户在 AI 调用期间点了取消 → 丢弃结果，循环顶部下一轮会 break。
                if cancelRequested { break }
                await applyResult(jobId: jobSnapshot.repoId, result: result, options: options)
            } catch {
                if cancelRequested { break }
                handleFailure(jobId: jobSnapshot.repoId, error: error, options: options)
            }

            currentJobId = nil

            // 每完成一个 job 就让出主线程，让 UI 渲染 panel 进度
            await Task.yield()
        }

        // 循环退出：若全部终态则关掉 isRunning；否则保留状态等用户 resume / cancel。
        if isFinished || cancelRequested || jobs.allSatisfy({ $0.status != .queued }) {
            // 用户取消时，把可能停在 .processing 的孤儿 job 收尾，避免 UI 留"永远转圈"行。
            if cancelRequested {
                let now = Date()
                let reason = String(localized: "batchAI.panel.cancelledByUser")
                for idx in jobs.indices where jobs[idx].status == .processing {
                    jobs[idx].status = .failed
                    jobs[idx].errorMessage = reason
                    jobs[idx].finishedAt = now
                }
            }
            isRunning = false
            currentJobId = nil
            if isFinished {
                AppLog.ai.notice("[batch-ai] finished: completed=\(self.completedCount, privacy: .public), ignored=\(self.ignoredCount, privacy: .public), failed=\(self.failedCount, privacy: .public)")
            }
        }
    }

    // MARK: - 单 job 处理

    /// 处理单个 repo 的执行结果（成功路径携带的产出）。
    private struct JobOutcome {
        var insight: RepoAIInsightGeneration
        var repo: Repo
        var existingTagHints: [String]
    }

    /// 调 RepoAIInsightService 拉取摘要 / 标签建议；本方法**不写库**，
    /// 决策（写哪些标签 / 标 ignored）放在 applyResult 里。
    private func processSingle(jobId: Int64, options: BatchAIQueueOptions) async throws -> JobOutcome {
        // 通过 insightService 拿不到原 Repo，HomeView 进入 batch 前已经把 repos 传给 start()，
        // jobs 里只存了 repoId + fullName。这里我们需要 Repo（generateInsight 要 description / topics）。
        // 折中方案：再从 RepoTagRepository 借用全表标签做 hints（已有 fetchAll API），
        // 而 Repo 本身改由调用方 enqueue 时打包好——但为了不污染 BatchAIJob 字段过宽，
        // 这里改成 enqueue 时同时持有 [Repo]。
        guard let repo = repoCache[jobId] else {
            throw RepoAIInsightError.invalidJSON  // 复用现有 error 类型；不应发生
        }

        // 拉一次"现有标签 + 计数"作为 prompt 提示。
        // 只有 includeTags 时才有意义；避免无谓查询。
        let hints: [String]
        if options.actions.contains(.tags) {
            let allTags = (try? await tagRepository.fetchAll()) ?? []
            // 按 sortOrder 已经倒序，前 50 个最常用的足够引导 AI 复用。
            hints = allTags.prefix(50).map(\.name)
        } else {
            hints = []
        }

        let insight = try await insightService.generateInsight(
            for: repo,
            existingTagHints: hints,
            includeSummary: options.actions.contains(.summary),
            includeTags: options.actions.contains(.tags)
        )
        return JobOutcome(insight: insight, repo: repo, existingTagHints: hints)
    }

    /// 把 processSingle 的产出按 Options 落库 + 写 job 终态。
    ///
    /// async 而非 fire-and-forget：主循环必须等"落库 + 写终态"全部完成，
    /// 否则下一轮 currentJobId 切换时，前一个 job 仍停在 .processing，UI 出现"两个 processing"假象。
    private func applyResult(jobId: Int64, result: JobOutcome, options: BatchAIQueueOptions) async {
        guard let idx = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }

        let suggestions = result.insight.insight.suggestedTags
        let didSummary = options.actions.contains(.summary)
        let didTags = options.actions.contains(.tags)

        // 标签子分支：
        // - 没勾选标签 → 直接 completed（summary 已写）。
        // - 勾选 + autoApply=true → 按置信度阈值过滤后落库；全部低于阈值 → ignored；否则 completed。
        // - 勾选 + autoApply=false → 标签建议留在 ai_summaries 缓存里，由用户后续在详情页"AI 标签确认"流应用。
        //   这种情况 status = completed（任务本身没失败，只是不自动写库）。
        if didTags, options.autoApplyTags {
            let belowThreshold = suggestions.filter { $0.confidence < options.confidenceThreshold }
            let aboveThreshold = suggestions.filter { $0.confidence >= options.confidenceThreshold }

            if aboveThreshold.isEmpty, !suggestions.isEmpty {
                jobs[idx].status = .ignored
                jobs[idx].ignoredTagsBelowThreshold = belowThreshold.map { ($0.name, $0.confidence) }
                jobs[idx].didGenerateSummary = didSummary
                jobs[idx].finishedAt = Date()
                return
            }

            let appliedNames = await applyTagsToRepo(repoId: jobId, suggestions: aboveThreshold)
            guard let idx2 = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }
            jobs[idx2].appliedTagNames = appliedNames
            jobs[idx2].ignoredTagsBelowThreshold = belowThreshold.map { ($0.name, $0.confidence) }
            jobs[idx2].didGenerateSummary = didSummary
            jobs[idx2].finishedAt = Date()
            jobs[idx2].status = .completed
            if !appliedNames.isEmpty {
                onTagsChanged?()
            }
        } else {
            jobs[idx].didGenerateSummary = didSummary
            jobs[idx].finishedAt = Date()
            jobs[idx].status = .completed
        }
    }

    /// 把通过阈值过滤的建议落库为 repo_tags 关联。
    /// 重复使用 RepoAIInsightViewModel 的 findOrCreate 模式：先按 name 查找，
    /// 不存在则新建一个最小 Tag（无颜色、默认图标）。
    private func applyTagsToRepo(repoId: Int64, suggestions: [AITagSuggestion]) async -> [String] {
        var applied: [String] = []
        for suggestion in suggestions {
            let normalized = suggestion.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard !normalized.isEmpty else { continue }
            do {
                let tag = try await findOrCreateTag(named: normalized)
                try await repoTagRepository.addTag(repoId: repoId, tagId: tag.id)
                applied.append(normalized)
            } catch {
                AppLog.ai.error("[batch-ai] apply tag failed: repo=\(repoId, privacy: .public), tag=\(normalized, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return applied
    }

    private func findOrCreateTag(named name: String) async throws -> Tag {
        if let existing = try await tagRepository.findByName(name) {
            return existing
        }
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let tag = Tag(
            id: UUID().uuidString,
            name: name,
            color: nil,
            icon: "tag",
            sortOrder: 0,
            isPreset: false,
            parentId: nil,
            createdAt: now,
            updatedAt: now
        )
        try await tagRepository.create(tag)
        return tag
    }

    /// 处理单个 job 的失败：分流"重试" vs "终态失败"。
    private func handleFailure(jobId: Int64, error: Error, options: BatchAIQueueOptions) {
        guard let idx = jobs.firstIndex(where: { $0.repoId == jobId }) else { return }

        let message = error.localizedDescription
        AppLog.ai.error("[batch-ai] job failed: repo=\(jobId, privacy: .public), attempt=\(self.jobs[idx].attempts, privacy: .public), error=\(message, privacy: .public)")

        if isPermanentError(error) || jobs[idx].attempts >= options.maxRetries {
            jobs[idx].status = .failed
            jobs[idx].errorMessage = message
            jobs[idx].finishedAt = Date()
        } else {
            // 可重试：回退到 queued，主循环下一轮会重新拉取（重试次数已在 processNext 入口 +1）。
            jobs[idx].status = .queued
        }
    }

    /// 不可重试错误判别：用户没改配置之前永远会失败的那一类。
    private func isPermanentError(_ error: Error) -> Bool {
        if let insight = error as? RepoAIInsightError {
            switch insight {
            case .missingAPIKey, .missingProvider:
                return true
            case .invalidJSON:
                return false
            }
        }
        return false
    }

    // MARK: - Repo 缓存（避免每次 processSingle 都查库）

    /// repoId → Repo 的会话内缓存。由 start() 时填充。
    private var repoCache: [Int64: Repo] = [:]
}
