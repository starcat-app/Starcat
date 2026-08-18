//
//  SemanticIndexBuilder.swift
//  Starcat
//
//  后台慢速预拉 + 全量重建服务（详见 `docs/3-设计/详细设计/26-向量搜索改进.md` § 3.1 / 4.2）。
//
//  模块职责：
//  - 给 Settings UI 的"开始预拉 / 暂停 / 全量重建"按钮提供后端实现；
//  - 顺序处理指定范围内的 repo 列表（默认 starred + 知识库并集）：
//      ① 按需懒补全 README Markdown（`ReadmeAPI.refreshMarkdownIfNeeded`）
//      ② 调用 `SemanticSearchService.refreshIndexIfChanged` 走 diff 判定后重建向量
//  - 严格限速：GitHub README 拉取 ≤ 4500 次/h（设计文档：留 500 buffer 给同步流程）；
//  - 暴露 `@Observable` 进度 / 状态字段，UI 可直接 binding；
//  - 暂停 / 恢复：基于 Task.cancel + 内部 paused 标志的协作式停止。
//
//  关键约束：
//  - **README 串行 + Embedding 批量**：README 拉取受 GitHub rate limit 约束，仍逐个 repo
//    补 Markdown；Embedding 不受这个限速约束，按小批量提交给 `SemanticSearchService`，
//    让 provider 的 batch endpoint 与本地 snapshot 准备都能摊薄开销。
//  - **限速实现**：只有 `refreshMarkdownIfNeeded` 返回 `.updated`（这次真的打了 GitHub）
//    才 sleep `intervalMillis` 毫秒（默认 800ms ≈ 4500/h）。本地已有 Markdown、无 HTML
//    行而跳过、404 / 失败都不睡，避免 2000 仓缓存命中还空转半小时。
//    用 Task.sleep 而非外部计时器，让 cancel 立即生效。
//  - **错误隔离**：单个 repo 失败 → 累加 `failureCount`，继续下一个，不打断整体进度。
//  - **MainActor**：与 SemanticSearchService 一致，避免跨 actor 跳转。
//

import Foundation

/// 预拉 / 全量重建任务的运行状态（UI 用）。
///
/// 状态切换规则：
/// - 初始 / 完全重置后 → `.idle`
/// - 用户点开始 / 全量重建 → `.running`
/// - 用户点暂停 → `.paused`（保留 `processed` / `total`，可由 resume 续跑）
/// - 执行完成且**至少有一条实际重建** → `.completed(processed, total)`
/// - 执行完成且**所有条目都被 diff 跳过**（无任何 embedding API 调用）→
///   `.alreadyUpToDate(total)`，UI 渲染为绿色 ✓ 徽章 + "已是最新（共 N 个仓库）"
///   友好提示。引入这个独立状态而不是复用 `.completed` 的目的，是让 UI 能
///   精确区分"全部跳过"和"实际重建过"两种语义——之前两种都显示"已完成 N / N"
///   灰色小字，用户点了开始预拉后看到 UI 短暂切换却没有明确成功反馈，体感像
///   "闪烁了一下"（dong4j 2026-06-13 反馈）。
/// - 执行中抛错 → `.failed(message)`
enum SemanticIndexBuilderStatus: Equatable, Sendable {
    case idle
    case running
    case paused
    case completed(processed: Int, total: Int)
    /// 全部条目都被 diff 阈值跳过，没有任何实际 embedding API 调用。
    /// UI 渲染为绿色 checkmark.circle.fill + "已是最新（共 N 个仓库）"。
    case alreadyUpToDate(total: Int)
    case failed(message: String)
}

/// 最近一次预拉 / 全量重建的落盘快照。
///
/// `SemanticIndexBuilder.status` 只活在进程里，关设置页或重启后会回到 `.idle`，
/// 设置页必须靠这份记录回答「上次拉取是什么时候、结果如何」。
struct SemanticIndexPrefetchLastRun: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case completed
        case alreadyUpToDate
        case failed
    }

    var finishedAt: Date
    var processed: Int
    var total: Int
    var failures: Int
    var outcome: Outcome
    var failureMessage: String?
}

/// 语义索引候选范围。
///
/// `all` 是后台预拉的默认值：Starred 和知识库都属于用户主动维护的长期上下文。
/// 后续搜索 UI / MCP 暴露范围参数时也复用这三个语义，避免各入口各自发明一套命名。
enum SemanticIndexScope: String, CaseIterable, Sendable {
    /// 只索引当前 GitHub 已 star 的 repo。
    case starred
    /// 只索引 Starcat 私有知识库 repo，包含未 star 但已入库的 repo。
    case knowledge
    /// 索引 starred 与知识库并集，按 repo id 去重。
    case all

    static func mergeStarredAndKnowledge(starred: [Repo], knowledge: [Repo]) -> [Repo] {
        var seenIDs = Set<Int64>()
        var merged: [Repo] = []
        merged.reserveCapacity(starred.count + knowledge.count)

        for repo in starred + knowledge where seenIDs.insert(repo.id).inserted {
            merged.append(repo)
        }
        return merged
    }

    static func selectCandidates(scope: SemanticIndexScope, starred: [Repo], knowledge: [Repo]) -> [Repo] {
        switch scope {
        case .starred:
            return starred
        case .knowledge:
            return knowledge
        case .all:
            return mergeStarredAndKnowledge(starred: starred, knowledge: knowledge)
        }
    }
}

@MainActor
@Observable
final class SemanticIndexBuilder {

    // MARK: - 可观察状态（UI binding 用）

    /// 当前运行状态。idle → running ⇄ paused → completed / failed。
    private(set) var status: SemanticIndexBuilderStatus = .idle

    /// 已处理的 repo 数（含成功与失败）。
    private(set) var processed: Int = 0

    /// 计划处理的总 repo 数（开始任务时一次性确定）。
    private(set) var total: Int = 0

    /// 失败的 repo 数（单条失败不打断流程，但累加到这里供 UI 显示）。
    private(set) var failures: Int = 0

    /// 被 diff 阈值跳过、没有实际调 embedding API 的 repo 数（2026-06-13 dong4j
    /// 反馈"开始预拉闪烁"改造）。
    ///
    /// 用途：完成时如果 `skipped == total && failures == 0`，说明本次预拉**没干活儿**，
    /// 把状态设为 `.alreadyUpToDate(total)` 而非 `.completed(processed, total)`，
    /// UI 渲染为绿色 ✓ 友好提示而不是灰色"已完成 N / N"。
    ///
    /// 与 `processed` 的关系：`processed` 是"遍历完成的 repo 数"（含跳过 + 重建 + 失败），
    /// `skipped` 仅计"diff 判定不需要重建"那一类。`processed - skipped - failures` =
    /// 实际重建数。
    private(set) var skipped: Int = 0

    // MARK: - 依赖

    private let repoRepository: any RepoRepositoryProtocol
    private let readmeAPI: ReadmeAPI
    private let semanticSearchService: SemanticSearchService
    private let settings: AppSettings
    private let scope: SemanticIndexScope

    /// 单条真正打到 GitHub 的 README 拉取之间的限速间隔（毫秒）。
    /// 默认 800ms ≈ 4500 req/h，留 500 给同步流程；本地命中不走这个间隔。
    private let intervalMillis: Int

    /// Embedding 重建批大小。
    ///
    /// 与 `SemanticSearchService` 默认 batchSize 保持一致：32 足以显著减少逐仓库请求开销，
    /// 又不会把单次 prompt payload 做得过大，适合 OpenAI-compatible provider。
    private let embeddingChunkSize = 32

    private var runningTask: Task<Void, Never>?

    /// 用户主动按了暂停。和 `runningTask?.isCancelled` 联用，让"暂停 → 恢复"能从断点继续，
    /// 而不是 Task cancel 后状态完全重置。
    private var paused: Bool = false

    init(
        repoRepository: any RepoRepositoryProtocol,
        readmeAPI: ReadmeAPI,
        semanticSearchService: SemanticSearchService,
        settings: AppSettings,
        scope: SemanticIndexScope = .all,
        intervalMillis: Int = 800
    ) {
        self.repoRepository = repoRepository
        self.readmeAPI = readmeAPI
        self.semanticSearchService = semanticSearchService
        self.settings = settings
        self.scope = scope
        self.intervalMillis = intervalMillis
    }

    // MARK: - Public 操作

    /// 启动预拉（按 diff 判定，已索引且 diff 未超阈值的 repo 会被跳过）。
    /// 已在运行 → 直接 no-op；已暂停 → 走 `resume` 行为。
    func start() {
        if case .running = status {
            return
        }
        if paused {
            resume()
            return
        }
        run(force: false)
    }

    /// 暂停（合作式）：保留 `processed` / `total`，可由 `resume` 续跑。
    func pause() {
        guard case .running = status else { return }
        paused = true
        runningTask?.cancel()
        status = .paused
    }

    /// 从暂停态恢复：清掉 paused 标志，重新启动 task（已处理过的 repo 会被 diff 判定跳过）。
    func resume() {
        guard case .paused = status else { return }
        paused = false
        run(force: false)
    }

    /// 全量重建：忽略 diff 阈值，当前语义索引范围内所有 repo 都重新调一次 embedding API。
    ///
    /// 调用方应已通过 Settings UI 弹出"危险操作"确认对话框（API 配额成本高）。
    /// 与 `start` 共用 task；如果有在跑的 task 会先 cancel。
    func rebuildAll() {
        runningTask?.cancel()
        paused = false
        processed = 0
        failures = 0
        skipped = 0
        total = 0
        run(force: true)
    }

    /// 完全取消并重置状态（设置页关闭 / 用户登出时调用）。
    func cancel() {
        runningTask?.cancel()
        paused = false
        processed = 0
        failures = 0
        skipped = 0
        total = 0
        status = .idle
    }

    // MARK: - Private

    /// 启动一次后台任务。
    ///
    /// **2026-06-13 dong4j 反馈"3 个 star 显示『已完成 6 / 3』"修复**：
    /// `status = .running` 必须在**同步**路径上翻状态，不能放进 async `execute()` 里。
    ///
    /// 为什么：`HomeView` 在登录恢复期间会同周期内从两个 modifier 各调一次 `start()`：
    ///   1. `.task { ... }` body —— HomeView 出现时
    ///   2. `.onChange(of: authSession.state)` —— 认证状态翻 authenticated 时
    /// 它们都在同一 `@MainActor` 同步路径上前后脚执行，旧 Task 的 body 此刻**还没被调度**。
    ///
    /// 旧实现把 `status = .running` 写在 async `execute()` 第一行，意味着：
    /// - Call A 进 `start()`：`status == .idle` → 走 `run()` → enqueue Task A
    /// - Call B 紧随其后：`status` **仍是** `.idle`（Task A 还没跑到设置语句）→ 又走 `run()`
    ///   → enqueue Task B（`runningTask` 引用被覆盖，但 Task A 仍在调度队列里）
    /// - Task A 和 Task B 后续都跑 `execute()`，共享同一个 `processed` 计数器，
    ///   每个 repo 被两条路径各 +1 一次，最终 `processed = 2 × total`
    ///
    /// 直接证据：dong4j 只有 3 个 starred repo，UI 显示「已完成 6 / 3」（`processed = 6, total = 3`）。
    /// `refreshMarkdownIfNeeded` / `refreshIndexIfChanged` 本身有幂等保护（拉过的 README 不会
    /// 重新拉、未变的 snapshot 不会重新调 embedding），所以这是纯**显示侧**的 bug，没有真的
    /// 烧到双倍 API 配额；但用户视觉上严重困惑。
    ///
    /// 修复：把 `status = .running` 移到这里（同步），再 enqueue Task。同周期内后续的
    /// `start()` 调用就能正确走 `if case .running = status { return }` 早退分支，永远
    /// 不会出现双 Task 抢 `processed`。
    private func run(force: Bool) {
        status = .running
        runningTask = Task { @MainActor [weak self] in
            await self?.execute(force: force)
        }
    }

    private func execute(force: Bool) async {
        // `status = .running` 已在 `run()` 同步设过；这里不再重复设置，
        // 避免抹掉 pause() 在 fetchAllStarred 期间设的 .paused（边界 case：
        // pause() 在 await 期间触发 → Task.isCancelled 命中 → catch 块或下方
        // 提前 return 路径，详见循环里两处 `Task.isCancelled` 兜底）。
        do {
            let repos: [Repo]
            if total == 0 {
                // 首次启动 / rebuildAll：重新查询当前语义索引范围。
                repos = try await fetchRepos(scope: scope)
                total = repos.count
                processed = 0
                failures = 0
                skipped = 0
            } else {
                // 恢复（从断点继续）：跳过 processed 个
                repos = try await fetchRepos(scope: scope)
                // 保护：如果索引范围列表期间发生变化（用户 star/unstar 或改知识库状态），
                // 我们简单按当前列表的 prefix(processed) 当作"已处理"。这不精确但够用——
                // 极端 corner case（resume 后候选增长 X 个）顶多让早期 X 个 repo 多走
                // 一次 diff 判定（diff 未超阈值会立即跳过，不烧 embedding API）。
            }

            let toProcess = Array(repos.dropFirst(processed))
            for chunk in toProcess.chunked(into: embeddingChunkSize) {
                if Task.isCancelled { break }

                var indexCandidates: [Repo] = []
                indexCandidates.reserveCapacity(chunk.count)
                for repo in chunk {
                    if Task.isCancelled { break }
                    let fetchedMarkdown = await refreshMarkdownForIndexing(repo)
                    indexCandidates.append(repo)
                    processed += 1

                    if Task.isCancelled { break }
                    // 限速只保护 GitHub：本地命中 / 跳过不能按仓 sleep。
                    // Task.sleep 可被 cancel 立刻打断；DispatchQueue.asyncAfter 会让暂停卡住。
                    if fetchedMarkdown, intervalMillis > 0 {
                        try? await Task.sleep(for: .milliseconds(intervalMillis))
                    }
                }

                guard !indexCandidates.isEmpty, !Task.isCancelled else { continue }
                await rebuildIndexChunk(indexCandidates, force: force)
            }

            if Task.isCancelled {
                // 区分"用户主动暂停" vs "外部 cancel 重置"。pause() 已经设了 .paused 状态，
                // 这里不要覆盖。cancel() 已经设了 .idle，同理。
                return
            }

            // **2026-06-13 dong4j 反馈"开始预拉闪烁"改造**：
            // 完成时如果所有条目都被 diff 阈值跳过（含 0 starred 这种边界 case），
            // 切到 `.alreadyUpToDate(total)` 让 UI 渲染绿色 ✓ 友好提示，而不是
            // 灰色"已完成 N / N"小字（无明确成功反馈，用户体感像点了个寂寞）。
            //
            // 判定条件 `skipped == processed && failures == 0`：
            //   - `skipped == processed`：所有被遍历的 repo 都没真重建（force=true 路径下
            //     `didRebuild` 永远为 true，所以这条只会在 force=false 路径触发）；
            //   - `failures == 0`：失败案例归到 `.completed` 让用户看到原始进度文字，
            //     避免"全部失败"被误显示成"已是最新"；
            //   - 不卡 `total > 0`：0 starred 也算"已是最新"（理论上 idle 用户场景，
            //     UI 显示"已是最新（共 0 个仓库）"逻辑自洽）。
            //
            // 力量重建（rebuildAll → force=true）走 `.completed` 是符合预期的——
            // 用户明确点了"全量重建"按钮，应该看到"已完成 N / N"反馈而不是"已是最新"。
            if skipped == processed && failures == 0 {
                status = .alreadyUpToDate(total: total)
                persistLastRun(outcome: .alreadyUpToDate)
            } else {
                status = .completed(processed: processed, total: total)
                persistLastRun(outcome: .completed)
            }
        } catch {
            AppLog.ai.error("SemanticIndexBuilder failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(message: error.localizedDescription)
            persistLastRun(outcome: .failed, failureMessage: error.localizedDescription)
            let friendly = UserFacingError.map(
                error,
                operation: "semanticIndex.rebuild",
                service: "Starcat"
            )
            if friendly.shouldRecordDiagnostic {
                DiagnosticLogStore.record(
                    level: .error,
                    visibility: .issue,
                    category: "semantic-index",
                    operation: "semanticIndex.rebuild",
                    message: "Semantic search index rebuild failed because of a local or contract error",
                    underlying: friendly.diagnosticSummary
                )
            }
        }
    }

    /// 预拉结束立刻落盘，设置页下次打开才能读到时间和计数。暂停 / 取消不写。
    private func persistLastRun(outcome: SemanticIndexPrefetchLastRun.Outcome, failureMessage: String? = nil) {
        settings.semanticIndexLastPrefetch = SemanticIndexPrefetchLastRun(
            finishedAt: Date(),
            processed: processed,
            total: total,
            failures: failures,
            outcome: outcome,
            failureMessage: failureMessage
        )
    }

    private func fetchRepos(scope: SemanticIndexScope) async throws -> [Repo] {
        switch scope {
        case .starred:
            let starred = try await repoRepository.fetchAllStarred()
            return SemanticIndexScope.selectCandidates(scope: scope, starred: starred, knowledge: [])
        case .knowledge:
            let knowledge = try await repoRepository.fetchKnowledgeRepos()
            return SemanticIndexScope.selectCandidates(scope: scope, starred: [], knowledge: knowledge)
        case .all:
            let starred = try await repoRepository.fetchAllStarred()
            let knowledge = try await repoRepository.fetchKnowledgeRepos()
            return SemanticIndexScope.selectCandidates(scope: scope, starred: starred, knowledge: knowledge)
        }
    }

    /// 单仓库补全 README Markdown。
    ///
    /// Markdown 失败不计入 `failures`：snapshot 仍可走 HTML / metadata 兜底，embedding
    /// 是否需要重建由后续批量 `SemanticSearchService` 决定。
    /// - Returns: `true` 表示这次向 GitHub 拉取并落库了 Markdown，调用方才需要做 800ms 限速。
    @discardableResult
    private func refreshMarkdownForIndexing(_ repo: Repo) async -> Bool {
        let mdResult = await readmeAPI.refreshMarkdownIfNeeded(for: repo)
        switch mdResult {
        case .updated:
            return true
        case .failed(let error):
            AppLog.ai.warning("refreshMarkdownIfNeeded failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        case .notModified, .notFound:
            return false
        }
    }

    /// 批量重建 / 按 diff 刷新 embedding。
    ///
    /// 这里把 README 限速与 embedding 批处理拆开：前者保护 GitHub rate limit，后者降低
    /// OpenAI-compatible embedding endpoint 的请求次数。`processed` 已在 README 阶段递增，
    /// 本方法只维护 `skipped` 与 `failures`。
    private func rebuildIndexChunk(_ repos: [Repo], force: Bool) async {
        guard !repos.isEmpty else { return }

        if force {
            do {
                _ = try await semanticSearchService.refreshIndex(for: repos)
            } catch {
                failures += repos.count
                AppLog.ai.warning("rebuild vector chunk failed count=\(repos.count, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            let rebuilt = await semanticSearchService.refreshIndexIfChanged(for: repos)
            skipped += max(0, repos.count - rebuilt)
        }
    }
}

private extension Array {
    /// 文件内小工具：按固定大小切 chunk。
    ///
    /// 这里保持 private，避免为了 `SemanticIndexBuilder` 的一个批处理循环扩大成全工程 API。
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
