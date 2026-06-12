//
//  SemanticIndexBuilder.swift
//  Starcat
//
//  后台慢速预拉 + 全量重建服务（详见 `docs/详细设计/26-向量搜索改进.md` § 3.1 / 4.2）。
//
//  模块职责：
//  - 给 Settings UI 的"开始预拉 / 暂停 / 全量重建"按钮提供后端实现；
//  - 顺序处理 starred repo 列表：
//      ① 按需懒补全 README Markdown（`ReadmeAPI.refreshMarkdownIfNeeded`）
//      ② 调用 `SemanticSearchService.refreshIndexIfChanged` 走 diff 判定后重建向量
//  - 严格限速：GitHub README 拉取 ≤ 4500 次/h（设计文档：留 500 buffer 给同步流程）；
//  - 暴露 `@Observable` 进度 / 状态字段，UI 可直接 binding；
//  - 暂停 / 恢复：基于 Task.cancel + 内部 paused 标志的协作式停止。
//
//  关键约束：
//  - **单 Task 串行**：双队列概念上独立（README 拉取 + Embedding 调用），但 Embedding
//    流程已经在 `SemanticSearchService.ensureIndexed` 内部 batch 化（默认 batchSize=32），
//    所以这里实际上是"逐个 repo 串行：补 Markdown → 调一次 refreshIndexIfChanged"。
//    保留"双队列"设计文档语义，等后续 Embedding 也需要独立限速时再拆。
//  - **限速实现**：拉一次 README sleep `intervalMillis` 毫秒（默认 800ms ≈ 4500/h）。
//    用 Task.sleep 而非外部计时器，让 cancel 立即生效。
//  - **错误隔离**：单个 repo 失败 → 累加 `failureCount`，继续下一个，不打断整体进度。
//  - **MainActor**：与 SemanticSearchService 一致，避免跨 actor 跳转。
//

import Foundation

/// 预拉 / 全量重建任务的运行状态（UI 用）。
enum SemanticIndexBuilderStatus: Equatable, Sendable {
    case idle
    case running
    case paused
    case completed(processed: Int, total: Int)
    case failed(message: String)
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

    // MARK: - 依赖

    private let repoRepository: any RepoRepositoryProtocol
    private let readmeAPI: ReadmeAPI
    private let semanticSearchService: SemanticSearchService

    /// 单条 README 拉取之间的限速间隔（毫秒）。
    /// 默认 800ms ≈ 4500 req/h，留 500 给同步流程，详见模块注释。
    private let intervalMillis: Int

    private var runningTask: Task<Void, Never>?

    /// 用户主动按了暂停。和 `runningTask?.isCancelled` 联用，让"暂停 → 恢复"能从断点继续，
    /// 而不是 Task cancel 后状态完全重置。
    private var paused: Bool = false

    init(
        repoRepository: any RepoRepositoryProtocol,
        readmeAPI: ReadmeAPI,
        semanticSearchService: SemanticSearchService,
        intervalMillis: Int = 800
    ) {
        self.repoRepository = repoRepository
        self.readmeAPI = readmeAPI
        self.semanticSearchService = semanticSearchService
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

    /// 全量重建：忽略 diff 阈值，所有 starred repo 都重新调一次 embedding API。
    ///
    /// 调用方应已通过 Settings UI 弹出"危险操作"确认对话框（API 配额成本高）。
    /// 与 `start` 共用 task；如果有在跑的 task 会先 cancel。
    func rebuildAll() {
        runningTask?.cancel()
        paused = false
        processed = 0
        failures = 0
        total = 0
        run(force: true)
    }

    /// 完全取消并重置状态（设置页关闭 / 用户登出时调用）。
    func cancel() {
        runningTask?.cancel()
        paused = false
        processed = 0
        failures = 0
        total = 0
        status = .idle
    }

    // MARK: - Private

    private func run(force: Bool) {
        runningTask = Task { @MainActor [weak self] in
            await self?.execute(force: force)
        }
    }

    private func execute(force: Bool) async {
        status = .running
        do {
            let repos: [Repo]
            if total == 0 {
                // 首次启动 / rebuildAll：重新查全表
                repos = try await repoRepository.fetchAllStarred()
                total = repos.count
                processed = 0
                failures = 0
            } else {
                // 恢复（从断点继续）：跳过 processed 个
                repos = try await repoRepository.fetchAllStarred()
                // 保护：如果 starred 列表期间发生变化（用户新 star / unstar），
                // 我们简单按当前列表的 prefix(processed) 当作"已处理"。这不精确但够用——
                // 极端 corner case（resume 后 starred 增长 X 个）顶多让早期 X 个 repo 多走
                // 一次 diff 判定（diff 未超阈值会立即跳过，不烧 embedding API）。
            }

            let toProcess = Array(repos.dropFirst(processed))
            for repo in toProcess {
                if Task.isCancelled { break }
                await processOne(repo: repo, force: force)
                processed += 1

                if Task.isCancelled { break }
                // 限速：单条 README 拉取后 sleep。注意此处用 Task.sleep（cancel 时立刻抛错），
                // 不能用 DispatchQueue.asyncAfter，否则 pause 时进度会卡住等定时器结束。
                if intervalMillis > 0 {
                    try? await Task.sleep(for: .milliseconds(intervalMillis))
                }
            }

            if Task.isCancelled {
                // 区分"用户主动暂停" vs "外部 cancel 重置"。pause() 已经设了 .paused 状态，
                // 这里不要覆盖。cancel() 已经设了 .idle，同理。
                return
            }
            status = .completed(processed: processed, total: total)
        } catch {
            AppLog.ai.error("SemanticIndexBuilder failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(message: error.localizedDescription)
        }
    }

    /// 单条 repo 的处理：
    /// 1. 拉 readme markdown（仅在 `readmes.content` 为 nil 时真发请求）
    /// 2. 调 `refreshIndexIfChanged` / `refreshIndex` 让 SemanticSearchService 处理向量
    ///
    /// 失败时只累加 `failures`，不抛出。
    private func processOne(repo: Repo, force: Bool) async {
        let mdResult = await readmeAPI.refreshMarkdownIfNeeded(for: repo)
        if case .failed(let error) = mdResult {
            AppLog.ai.warning("refreshMarkdownIfNeeded failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // 不直接 failures++：Markdown 失败不影响向量重建（snapshot 走 HTML 兜底）
        }

        // 向量重建：force=true 时调 refreshIndex（强制）；force=false 走 diff 判定
        if force {
            do {
                try await semanticSearchService.refreshIndex(for: [repo])
            } catch {
                failures += 1
                AppLog.ai.warning("rebuild vector failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            await semanticSearchService.refreshIndexIfChanged(for: repo)
        }
    }
}
