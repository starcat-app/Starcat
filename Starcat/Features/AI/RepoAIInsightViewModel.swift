//
//  RepoAIInsightViewModel.swift
//  Starcat
//
//  详情页单仓 AI 摘要状态模型。
//
//  模块职责：
//  - 管理 AI 摘要的未生成 / 加载缓存 / 生成中 / 失败状态；
//  - 提供“生成 / 重新生成”动作；
//  - 承接 AI 标签推荐确认流，用户点击后才创建标签并绑定到 repo。
//
//  关键约束：
//  - 只在用户操作时调用 AI，不自动批量生成；
//  - 标签应用是显式动作，AI 结果本身不会直接修改用户数据；
//  - 成功应用标签后通知 HomeViewModel 刷新 Sidebar 计数与当前列表；
//  - W4（2026-06-21）：新增 `prepProgress` / `prepTask` 状态机与
//    `startBackgroundContextPrep(repo:)` 方法。打开 AI 面板时若 DB 里没有
//    cached insight，就立刻起后台 prep（解析分支 → 下载 ZIP → pack context.xml），
//    期间「生成摘要」按钮可点，UI 在按钮上方显示 step chip。`generate(repo:)`
//    等待 prep 完成；用户也可按本次请求跳过，摘要直接使用 metadata + README。
//

import Foundation
import Observation

/// Y1（2026-06-13）：AI 摘要生成的两阶段状态机。
///
/// 用户体验目标：在 RepoContextPacker pipeline 跑的几秒 ~ 十几秒里给 UI 一个有信息量的
/// 进度提示，而不是空白旋转 spinner。
///
/// 两阶段区分点：
///   - `preparingContext`：从 `generate(repo:)` 入口开始，到代码上下文完成或被跳过。
///     语义上只覆盖 makeSource 的代码上下文阶段，可展示精确步骤并允许本次跳过。
///   - `requestingSummary`：代码上下文已经完成或被用户跳过，正在收集其它材料并建立
///     LLM 请求；此时不能再取消代码上下文，避免“按钮点了但 XML 已经注入”的假反馈。
///   - `streamingSummary`：收到第一个 streaming delta 之后切换；语义 = LLM 输出阶段。
enum SummaryPhase: Sendable, Equatable {
    case preparingContext
    case requestingSummary
    case streamingSummary
}

/// W4（2026-06-21）：打开 AI 面板时的「后台准备代码上下文」进度状态。
///
/// 设计动机：原 `load(repo:)` 在入口 await `service.cachedInsight(for:)`，里面会跑
/// `makeSource`（GitHub branches API + 可能 ZIP 下载 + RepoContextPacker.pack），
/// 用户体感是「打开面板后好几秒看到按钮」。把代码上下文准备拆成「后台 prep + 按
/// 钮即时可点」两条路径后：
///   - 按钮不再被前置 IO 阻塞；
///   - prep 进度通过 step 行可视化（解析分支 / 下载项目代码 / 解压并生成上下文）；
///   - 用户在 prep 期间点「生成摘要」会先 await prep 完成再进入 generate，保证 LLM
///     拿到最新 context（避免钱白烧）。
///
/// 状态转移：
///   - `.idle`（未启动 prep） → toggle off / 已有 cached insight / 未切换 repo
///   - `.preparing(.resolvingBranch)` → 进入 `RepoAIContextProvider.contextOutcome`
///   - `.preparing(.downloadingArchive)` → 进入 `archiveIfNeeded`（cache 命中分支跳过此步）
///   - `.preparing(.packingContext)` → 进入 `RepoContextPacker.pack`
///   - `.ready` → prep 成功；generate 路径会复用此结果（cache hit 路径下走内部 makeSource 复用）
///   - `.failed(reason)` → prep 失败（如 ZIP 下载失败 / packer 抛错），按钮仍可点，
///     generate 走降级路径（README-only）+ UI 显示降级 banner
enum PrepProgress: Sendable, Equatable {
    case idle
    case preparing(step: PrepStep)
    case ready
    case failed(reason: ContextDegradationReason)
}

/// W4：prep 步骤枚举。对应 `RepoAIContextProgress`，但限定到 ViewModel 关心的 3 段。
enum PrepStep: String, Sendable, Equatable, Hashable {
    /// 正在解析 default branch 拿 commit SHA（GitHub `/branches/:name`）。
    case resolvingBranch
    /// 正在下载仓库 ZIP（cache 命中时不会进入此步骤）。
    case downloadingArchive
    /// 正在解压并生成 context.xml（`RepoContextPacker.pack`）。
    case packingContext
}

@MainActor
@Observable
final class RepoAIInsightViewModel {

    private(set) var insight: RepoAIInsight?
    private(set) var isLoading: Bool = false
    private(set) var isGenerating: Bool = false
    private(set) var errorMessage: String?
    private(set) var tagErrorMessage: String?
    private(set) var streamingSummaryText: String?
    private(set) var appliedTagNames: Set<String> = []
    private(set) var paywallContext: ProPaywallContext?

    /// Y1：摘要生成阶段（仅在 `isGenerating == true` 期间有意义）。
    /// `nil` 表示当前不在生成中。
    private(set) var phase: SummaryPhase?

    /// 本次生成是否由用户主动跳过代码上下文。只用于生成中的即时反馈，不写全局设置。
    private(set) var didSkipCodeContextForCurrentGeneration = false

    /// W4：后台 prep 代码上下文的进度状态。`idle` 表示当前没有 prep 在跑或已 ready。
    /// UI（`emptySummaryState`）根据此状态在按钮上方显示 step chip 行。
    private(set) var prepProgress: PrepProgress = .idle

    /// W4：当前进行中的后台 prep task。仅在 `prepProgress == .preparing(step:)` 期间非 nil。
    /// 用户点「生成摘要」后通过 continuation 等待；主动跳过会立即放行而不阻塞摘要。
    private var prepTask: Task<Void, Never>?

    /// 标识当前后台 prep run，阻止已取消的旧 task 继续通过 progress callback 污染新状态。
    private var prepRunID: UUID?

    /// `generate` 等待后台 prep 的单个 continuation。主动跳过时立即 resume，让摘要主流程
    /// 无需等待 ZIP 解压等同步工作走到下一个 cancellation checkpoint。
    private var prepWaitContinuation: CheckedContinuation<Void, Never>?

    /// 本次摘要生成的请求级控制器。与后台 `prepTask` 分开：
    /// 前者阻止 `makeSource` 取消后重启 provider，后者只负责面板打开后的预热任务。
    private var currentCodeContextRequest: RepoAICodeContextRequest?

    /// Y4：本次摘要生成时代码上下文的降级原因（nil = 成功 或 用户主动关）。
    /// 由 `generate(repo:)` 写入；缓存命中（`load`）路径不写，保持旧摘要 UI 状态干净。
    private(set) var contextDegradationReason: ContextDegradationReason?

    /// Y9.3（2026-06-14）：外部网页上下文（AnySearch）降级原因。
    ///
    /// 与 `contextDegradationReason` 同款生命周期：
    ///   - `generate()` 路径：写入 service 返回的分类原因（含 nil 清零）；
    ///   - `load()` 缓存路径：清零（从缓存读到的 insight 是历史快照，当时的 anysearch
    ///     错误不持久化避免误导用户）。
    private(set) var externalContextDegradationReason: ExternalContextDegradationReason?

    private let service: RepoAIInsightService
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol

    var onTagsChanged: (() -> Void)?

    init(
        service: RepoAIInsightService,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol
    ) {
        self.service = service
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
    }

    func load(repo: Repo) async {
        isLoading = true
        defer { isLoading = false }
        do {
            // W4：换成 fast 路径——只查 DB + JSON decode，**不做** hash 校验。
            // 旧 `cachedInsight(for:)` 内部 await `makeSource`（含 ZIP 下载 / pack），
            // 首屏打开 AI 面板会被前置 IO 阻塞几秒到十几秒，UI 只能显示
            // 「正在读取本地 AI 缓存…」静态文案。
            //
            // hash 校验推迟到 `generate` 路径：用户主动点「重新生成」时 `makeSource`
            // 会照常算 hash 并对比 `record.sourceHash`，发现不一致就走重生成。
            // 这是显式的 tradeoff（启动延迟 vs 数据新鲜度），与 HOM-199 缓存稳定化
            // 设计目标一致。
            let cached = try await service.cachedInsightFast(for: repo)
            insight = cached
            let currentTags = try await repoTagRepository.fetchTags(forRepo: repo.id)
            appliedTagNames = Set(currentTags.map { $0.name.normalizedTagName })
            errorMessage = nil
            tagErrorMessage = nil
            streamingSummaryText = nil
            // Y4：load 路径不携带降级原因；从缓存读到的 insight 已经是历史快照，
            // 当时的降级原因不在数据库里持久化（避免存"过期错误"误导用户）。
            contextDegradationReason = nil
            // Y9.3：anysearch 降级原因同款生命周期，load 路径一并清零。
            externalContextDegradationReason = nil

            // W4：只有当「无 cached insight」时才需要 prep code context——
            // 有 cached insight 的 repo 走「重新生成」按钮时由 `generate` 路径内部
            // 的 `makeSource` 顺带做 context 检查（cache hit 直接复用，免下载）。
            // 顺便：repo 切换时必须 cancel 上一个 prep task，避免「切到新 repo 时旧
            // prep 的 chip 状态机串到新 repo 上」这种串扰。
            if cached == nil {
                startBackgroundContextPrep(repo: repo)
            }
        } catch {
            presentPaywallIfNeeded(error)
            let friendly = UserFacingError.map(
                error,
                operation: String.l10n("diagnostics.operation.loadAIInsight"),
                service: "AI"
            )
            errorMessage = friendly.message
            friendly.record(category: "ai", operation: "insight.load", service: "ai-provider")
        }
    }

    /// W4：在后台启动「准备代码上下文」pipeline，进度通过 `prepProgress` 暴露给 UI。
    ///
    /// 设计要点：
    ///   - **不阻塞 UI**：本方法立刻返回，pipeline 在 detached task 里跑，按钮在
    ///     `prepProgress == .preparing(step:)` 期间保持可点；
    ///   - **重新进入前 cancel 上一个 task**：repo 切换 / VM 重建场景下防止串扰；
    ///   - **失败也保留按钮可点**：`.failed(reason)` 让 UI 显示降级 banner，但
    ///     `generate(repo:)` 路径仍可触发（走 README-only 降级生成）。
    ///   - **`toggle off` 时 provider 不存在**：`service.prepareContextForGeneration`
    ///     会立刻返回 `.featureDisabled`，prep 状态停留在 `.idle`，按钮秒到。
    private func startBackgroundContextPrep(repo: Repo) {
        // 防御：repo 切换时上一个 prep task 还没完，先 cancel 避免 chip 状态串到新 repo。
        prepTask?.cancel()
        resumePrepWaiter()
        let runID = UUID()
        prepRunID = runID
        prepProgress = .preparing(step: .resolvingBranch)
        let service = self.service

        // detached：避免继承 ViewModel 的 cancellation（ViewModel 自身没有 cancel，
        // 但 task 用 [weak self] 即可在 self 释放时让闭包内的 self 变 nil 自然退出）。
        let task = Task { [weak self] in
            let outcome: RepoAIContextOutcome
            do {
                outcome = try await service.prepareContextForGeneration(for: repo) { step in
                    // onProgress 回调本身已被 provider 强制 `@MainActor`，直接同步
                    // 改 prepProgress 即可。但因为外层 Task 没有强制 MainActor，这里
                    // 通过 MainActor.run 包一层保险（@Observable 必须主线程写）。
                    MainActor.assumeIsolated {
                        guard let self, self.prepRunID == runID else { return }
                        self.prepProgress = .preparing(step: Self.mapStep(step))
                    }
                }
            } catch is CancellationError {
                // 用户主动停止 / repo 切换 cancel 都不应降级成失败态；调用方已经把
                // prepProgress 收回 idle，旧 task 直接退出，避免异步回写污染新 UI。
                await MainActor.run {
                    self?.resumePrepWaiter()
                }
                return
            } catch {
                outcome = .degraded(.networkUnavailable)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.prepRunID == runID else { return }
                switch outcome {
                case .success:
                    // prep 完成。generate 路径会在 cache 命中分支里直接复用本地 xml，
                    // 不再重跑 prep pipeline。
                    self.prepProgress = .ready
                case .featureDisabled:
                    // 用户关了 toggle（或 provider 没注入）——prep 没启动。
                    // chip 行淡出，按钮照常可点，generate 走 README-only 路径。
                    self.prepProgress = .idle
                case .degraded(let reason):
                    self.prepProgress = .failed(reason: reason)
                    AppLog.ai.warning(
                        "[RepoAIInsightViewModel] background prep degraded for \(repo.fullName, privacy: .public): \(String(describing: reason), privacy: .public)"
                    )
                }
                self.prepRunID = nil
                self.prepTask = nil
                self.resumePrepWaiter()
            }
        }
        prepTask = task
    }

    /// 用户显式停止后台代码上下文准备。
    ///
    /// 交互语义：停止后进度 chip 直接隐藏；只清理当前下载留下的 `.tmp`，不删除已经
    /// 完整落盘的共享 ZIP / context 缓存，避免下一次生成失去可复用产物。
    func cancelContextPreparation(repo: Repo) {
        prepTask?.cancel()
        prepTask = nil
        prepRunID = nil
        prepProgress = .idle
        resumePrepWaiter()
        service.cleanupTemporaryContextPreparation(for: repo)
    }

    /// 用户在摘要生成中的“准备代码上下文”行点击停止。
    ///
    /// 这不是取消摘要：只取消当前 provider 子任务，并把本次 request 标记为跳过。
    /// `makeSource` 随后以空 `{codeContext}` 继续组装 metadata + README 等现有上下文；
    /// 下一次生成会创建全新的 request，因此自动恢复正常代码上下文策略。
    func skipCodeContextForCurrentGeneration(repo: Repo) {
        guard isGenerating, phase == .preparingContext else { return }

        didSkipCodeContextForCurrentGeneration = true
        currentCodeContextRequest?.skip()
        prepTask?.cancel()
        prepTask = nil
        prepRunID = nil
        prepProgress = .idle
        phase = .requestingSummary
        resumePrepWaiter()
        service.cleanupTemporaryContextPreparation(for: repo)
    }

    /// 等待后台 prep 完成；用户主动跳过时由 `resumePrepWaiter()` 立即放行。
    ///
    /// 不能直接 `await prepTask.value`：ZIPFoundation 的某些同步区段只能在步骤边界响应
    /// cancellation，UI 虽已显示“已跳过”，摘要却会继续等待，造成状态与真实执行脱节。
    private func waitForBackgroundPrepUnlessSkipped(
        request: RepoAICodeContextRequest
    ) async {
        guard case .preparing = prepProgress, !request.isSkipped else { return }
        await withCheckedContinuation { continuation in
            guard case .preparing = prepProgress, !request.isSkipped else {
                continuation.resume()
                return
            }
            prepWaitContinuation = continuation
        }
    }

    private func resumePrepWaiter() {
        prepWaitContinuation?.resume()
        prepWaitContinuation = nil
    }

    /// W4：把 provider 给的 `RepoAIContextProgress` 映射成 ViewModel 自己的 `PrepStep`。
    /// 抽取成纯函数便于测试 + 强制 exhaustive switch（漏 case 编译失败）。
    private static func mapStep(_ progress: RepoAIContextProgress) -> PrepStep {
        switch progress {
        case .resolvingBranch: return .resolvingBranch
        // 单仓 AI 面板保持原有三段视觉模型；缓存核对仍归入“解析项目”阶段，
        // 知识库 RAG 时间线则会单独展示这条更细粒度事件。
        case .checkingCache: return .resolvingBranch
        case .downloadingArchive: return .downloadingArchive
        case .packingContext: return .packingContext
        }
    }

    /// 触发生成 AI 摘要（含可选的标签推荐）。
    ///
    /// R-01 §3.2.7 Step 8：`includeTags` 由调用方根据「窗口打开瞬间冻结的 star 状态」决定。
    /// - 已 star（`includeTags == true`，默认）：摘要 + 标签推荐 一同生成
    /// - 未 star（`includeTags == false`）：仅摘要，**不发**标签生成请求
    ///   （未 star 的 repo 没有"绑定标签"语义，强行让 AI 生成无意义且浪费 token）
    func generate(repo: Repo, includeTags: Bool = true) async {
        let codeContextRequest = RepoAICodeContextRequest()
        currentCodeContextRequest = codeContextRequest
        didSkipCodeContextForCurrentGeneration = false
        isGenerating = true
        streamingSummaryText = ""
        phase = .preparingContext
        defer {
            isGenerating = false
            streamingSummaryText = nil
            phase = nil
            prepTask = nil
            currentCodeContextRequest = nil
        }

        // W4：如果后台 prep 还在跑（用户秒点「生成摘要」），先等 prep 完成再进入
        // generate 主流程——LLM 必须拿到最新 context，不能在 ZIP 下载到一半时就发
        // 请求。现在 `isGenerating` / phase 已在 await 前写入，因此正文会展示真实 step，
        // 用户也可以在等待期间点击“跳过代码上下文并继续生成”。
        await waitForBackgroundPrepUnlessSkipped(request: codeContextRequest)

        do {
            // 2026-06-14 dong4j 反馈：单仓路径之前漏传 hints，AI 不知道用户已有标签库 →
            // 容易生成「向量搜索 / Vector Search / 向量检索」这种同义不同名标签。
            // 与批量 AI 整理路径走同一份 `RepoAIInsightService.makeTagHints` 工厂，
            // 信号源单一：repo 自身标签（强信号）+ 全库高频前 30（弱信号），见 helper 注释。
            // includeTags == false 时不构造 hints，节省两次 DB 查询。
            let hints: AITagHints = includeTags
                ? await RepoAIInsightService.makeTagHints(
                    for: repo,
                    repoTagRepository: repoTagRepository,
                    tagRepository: tagRepository
                )
                : .empty
            let result = try await service.generateInsight(
                for: repo,
                existingTagHints: hints,
                includeTags: includeTags,
                codeContextRequest: codeContextRequest,
                onContextProgress: { [weak self] progress in
                    guard let self, !codeContextRequest.isSkipped else { return }
                    self.prepProgress = .preparing(step: Self.mapStep(progress))
                },
                onContextResolved: { [weak self] in
                    guard let self else { return }
                    self.phase = .requestingSummary
                }
            ) { [weak self] partial in
                self?.streamingSummaryText = partial
                // 第一次 delta 时切阶段——之后所有 delta 都已经是 streamingSummary，
                // 不需要 if 判等比较（赋值同款值开销可忽略）。
                self?.phase = .streamingSummary
            }
            insight = result.insight
            tagErrorMessage = result.tagErrorMessage
            // Y4：透传降级原因到 UI banner。
            contextDegradationReason = result.contextDegradationReason
            // Y9.3：透传 anysearch 降级原因到 UI banner。
            externalContextDegradationReason = result.externalContextDegradationReason
            errorMessage = nil
        } catch {
            presentPaywallIfNeeded(error)
            let friendly = UserFacingError.map(
                error,
                operation: String.l10n("diagnostics.operation.generateAIInsight"),
                service: "AI"
            )
            errorMessage = friendly.message
            friendly.record(category: "ai", operation: "insight.generate", service: "ai-provider")
        }
    }

    func applyTag(_ suggestion: AITagSuggestion, repo: Repo) async {
        let tagName = suggestion.name.normalizedTagName
        guard !tagName.isEmpty, !appliedTagNames.contains(tagName) else { return }
        do {
            let tag = try await findOrCreateTag(named: tagName)
            try await repoTagRepository.addTag(repoId: repo.id, tagId: tag.id)
            appliedTagNames.insert(tagName)
            onTagsChanged?()
            errorMessage = nil
        } catch {
            presentPaywallIfNeeded(error)
            let friendly = UserFacingError.map(
                error,
                operation: String.l10n("diagnostics.operation.applyAITag"),
                service: "Starcat"
            )
            errorMessage = friendly.message
            friendly.record(category: "ai", operation: "tag.apply", service: "local-database")
        }
    }

    func applyAllTags(repo: Repo) async {
        guard let insight else { return }
        for suggestion in insight.suggestedTags {
            await applyTag(suggestion, repo: repo)
        }
    }

    /// 找到同名标签直接复用；否则按 `TagAutoVisual` 共享算法挑色 + 挑图标后落库。
    ///
    /// 视觉与「批量 AI 整理」（`BatchAIQueueService`）走同一份 FNV-1a 算法，确保
    /// AI 推荐路径上自动建出来的标签风格统一，且同名标签每次新建落到同一 (颜色, 图标)。
    /// 详细约束见 `TagAutoVisual` 注释。
    private func findOrCreateTag(named name: String) async throws -> Tag {
        if let existing = try await tagRepository.findByName(name) {
            return existing
        }
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let visual = TagAutoVisual.pick(for: name)
        let tag = Tag(
            id: UUID().uuidString,
            name: name,
            color: visual.colorHex,
            icon: visual.iconName,
            sortOrder: 0,
            isPreset: false,
            parentId: nil,
            createdAt: now,
            updatedAt: now
        )
        try await tagRepository.create(tag)
        return tag
    }

    func dismissPaywall() {
        paywallContext = nil
    }

    private func presentPaywallIfNeeded(_ error: Error) {
        guard let gateError = error as? EntitlementGateError else { return }
        paywallContext = ProPaywallContext(feature: gateError.feature, message: gateError.localizedDescription)
    }
}

private extension String {
    var normalizedTagName: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
