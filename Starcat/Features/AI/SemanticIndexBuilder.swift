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
                // 首次启动 / rebuildAll：重新查全表
                repos = try await repoRepository.fetchAllStarred()
                total = repos.count
                processed = 0
                failures = 0
                skipped = 0
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
                let didRebuild = await processOne(repo: repo, force: force)
                if !didRebuild {
                    skipped += 1
                }
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
            } else {
                status = .completed(processed: processed, total: total)
            }
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
    ///
    /// **返回值（2026-06-13 dong4j 反馈"开始预拉闪烁"改造）**：
    /// - `true`：实际调用了 embedding API 重建（包括 force=true 路径的正常成功）；
    /// - `false`：被 diff 阈值跳过（无 API 调用）/ 缺 API Key 静默 no-op / 抛错。
    ///
    /// 调用方据此累加 `skipped` 计数，决定完成态用 `.alreadyUpToDate` 还是 `.completed`。
    /// 注意失败 case 也回 `false`——但调用方在调本函数前已经看到 `failures` 增量，
    /// `execute()` 完成时根据 `failures == 0` 兜底，不会把"全失败"误认为"已是最新"。
    private func processOne(repo: Repo, force: Bool) async -> Bool {
        let mdResult = await readmeAPI.refreshMarkdownIfNeeded(for: repo)
        if case .failed(let error) = mdResult {
            AppLog.ai.warning("refreshMarkdownIfNeeded failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // 不直接 failures++：Markdown 失败不影响向量重建（snapshot 走 HTML 兜底）
        }

        // 向量重建：force=true 时调 refreshIndex（强制）；force=false 走 diff 判定
        if force {
            do {
                let rebuilt = try await semanticSearchService.refreshIndex(for: [repo])
                return rebuilt > 0
            } catch {
                failures += 1
                AppLog.ai.warning("rebuild vector failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        } else {
            return await semanticSearchService.refreshIndexIfChanged(for: repo)
        }
    }
}
