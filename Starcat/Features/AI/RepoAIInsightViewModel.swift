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
//  - 代码上下文只在用户发起生成 / 重新生成后准备；打开 AI 面板只读取摘要缓存，
//    不触发分支解析、ZIP 下载或 context.xml 打包。
//

import Foundation
import Observation

/// Y1（2026-06-13）：AI 摘要生成的阶段状态机。
///
/// 用户体验目标：在 RepoContextPacker / External Search / 等待首 token 的空档里给 UI
/// 有信息量的进度提示，而不是空白旋转 spinner。
///
/// 阶段区分点：
///   - `preparingContext`：代码上下文准备（解析分支 / 下载 ZIP / 打包 XML），可本次跳过。
///   - `fetchingExternalContext`：设置开启 External Search 时，拉取外部网页资料；
///     代码上下文已完成，不可再跳过 XML。
///   - `requestingSummary`：外部材料已结束（或未开启），正在组装 Prompt 并等待 LLM
///     首个正文 token；不能再取消代码上下文。
///   - `streamingSummary`：收到第一个 streaming delta 之后；语义 = LLM 输出阶段。
enum SummaryPhase: Sendable, Equatable {
    case preparingContext
    case fetchingExternalContext
    case requestingSummary
    case streamingSummary
}

/// 代码上下文结束后、流式摘要开始前的可见子步骤。
///
/// 仅当本次生成冻结了「会跑 External Search」时才展示两段 chip；关闭外部搜索时
/// 直接停留在 `requestingSummary` 文案，不渲染本枚举。
enum RequestPrepStep: String, Sendable, Equatable, Hashable {
    /// `ExternalSearchContextProvider.collect` 进行中。
    case externalSearch
    /// 外部搜索已结束（或未开启），等待 LLM 首个正文 token。
    case requestingLLM
}

/// 单次摘要生成期间的代码上下文准备状态。
///
/// 只有设置中启用代码上下文，并且用户发起生成 / 重新生成时才进入非 idle 状态。
/// 面板打开阶段始终保持 `.idle`，避免未经用户生成操作就下载仓库源码。
///
/// 状态转移：
///   - `.idle` → 未生成、代码上下文关闭或本次生成已经离开准备阶段
///   - `.preparing(.resolvingBranch)` → 进入 `RepoAIContextProvider.contextOutcome`
///   - `.preparing(.downloadingArchive)` → 进入 `archiveIfNeeded`（cache 命中分支跳过此步）
///   - `.preparing(.packingContext)` → 进入 `RepoContextPacker.pack`
enum PrepProgress: Sendable, Equatable {
    case idle
    case preparing(step: PrepStep)
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

    /// 本次生成是否会跑 External Search（点击生成瞬间按 repo + 设置冻结）。
    /// UI 用它决定是否展示「获取外部资料 → 准备摘要请求」两段 chip。
    private(set) var usesExternalContextForCurrentGeneration = false

    /// 本次生成的代码上下文准备进度；面板空态不会启动或展示该状态机。
    private(set) var prepProgress: PrepProgress = .idle

    /// 本次摘要生成的请求级控制器；负责跳过当前 provider 工作，但不改全局设置。
    private var currentCodeContextRequest: RepoAICodeContextRequest?

    /// 当前正在生成的仓库 id。虽然 session store 已按 repo 隔离 ViewModel，
    /// 仍在跳过入口校验 id，防止错误调用改写其它仓库的请求。
    private var activeGenerationRepoID: Repo.ID?

    /// 生成世代号：session 重置时递增，丢弃已取消 generate 的迟到写回与进度回调。
    private var generationEpoch: UInt64 = 0

    /// 本 ViewModel 已完成缓存加载的仓库。
    ///
    /// `RepoAIInsightSessionStore` 会按 repo 复用 ViewModel；面板收起、切走再切回时
    /// SwiftUI 会重新触发 `.task`，这里必须把重复 load 收敛成 no-op，否则缓存加载会
    /// 清掉仍在生成中的 streaming / phase 状态。
    private var loadedRepoID: Repo.ID?
    private var loadingRepoID: Repo.ID?

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
        // 每个 session 只绑定一个 repo。重复挂载同一面板时直接复用内存状态，
        // 尤其不能用数据库中的旧摘要覆盖仍在流式生成的新摘要。
        guard loadedRepoID == nil || loadedRepoID == repo.id else {
            assertionFailure("RepoAIInsightViewModel cannot be rebound to another repo")
            return
        }
        guard loadedRepoID != repo.id,
              loadingRepoID != repo.id,
              !isGenerating,
              activeGenerationRepoID != repo.id else { return }

        // `cachedInsightFast` / `fetchTags` 期间用户可能已经点了生成；
        // 用 epoch 门控写回，避免 TOCTOU 把 streaming 状态冲掉。
        let loadEpoch = generationEpoch
        loadingRepoID = repo.id
        isLoading = true
        defer {
            if loadingRepoID == repo.id {
                loadingRepoID = nil
                isLoading = false
            }
        }
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
            guard canApplyIdleLoad(for: repo.id, loadEpoch: loadEpoch) else { return }
            let currentTags = try await repoTagRepository.fetchTags(forRepo: repo.id)
            guard canApplyIdleLoad(for: repo.id, loadEpoch: loadEpoch) else { return }

            insight = cached
            appliedTagNames = Set(currentTags.map { $0.name.normalizedTagName })
            errorMessage = nil
            tagErrorMessage = nil
            streamingSummaryText = nil
            // Y4：load 路径不携带降级原因；从缓存读到的 insight 已经是历史快照，
            // 当时的降级原因不在数据库里持久化（避免存"过期错误"误导用户）。
            contextDegradationReason = nil
            // Y9.3：anysearch 降级原因同款生命周期，load 路径一并清零。
            externalContextDegradationReason = nil

            // 打开面板只读摘要与标签缓存。代码上下文必须等用户发起生成后再准备，
            // 避免“只是查看空面板”也产生网络下载和本地 XML。
            prepProgress = .idle
            loadedRepoID = repo.id
        } catch {
            guard canApplyIdleLoad(for: repo.id, loadEpoch: loadEpoch) else { return }
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

    /// load 写回前的二次校验：生成已开始或 session 被重置时丢弃迟到缓存结果。
    private func canApplyIdleLoad(for repoID: Repo.ID, loadEpoch: UInt64) -> Bool {
        generationEpoch == loadEpoch
            && !isGenerating
            && activeGenerationRepoID != repoID
            && (loadedRepoID == nil || loadedRepoID == repoID)
    }

    /// 用户在摘要生成中的“准备代码上下文”行点击停止。
    ///
    /// 这不是取消摘要：只取消当前 provider 子任务，并把本次 request 标记为跳过。
    /// `makeSource` 随后以空 `{codeContext}` 继续组装 metadata + README 等现有上下文；
    /// 下一次生成会创建全新的 request，因此自动恢复正常代码上下文策略。
    ///
    /// 关键约束：`repo` 必须是当前这一次 `generate` 绑定的仓库；换仓后旧面板上的
    /// 跳过按钮即使还在视图树里，也不能改写新仓库的生成状态。
    func skipCodeContextForCurrentGeneration(repo: Repo) {
        guard isGenerating,
              phase == .preparingContext,
              activeGenerationRepoID == repo.id else { return }

        didSkipCodeContextForCurrentGeneration = true
        currentCodeContextRequest?.skip()
        prepProgress = .idle
        // 跳过 XML 后仍可能继续 External Search；保持与 onContextResolved 一致的阶段语义。
        phase = usesExternalContextForCurrentGeneration
            ? .fetchingExternalContext
            : .requestingSummary
        service.cleanupTemporaryContextPreparation(for: repo)
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

    /// 立刻刷新当前真实步骤；缓存命中不会伪造下载或打包事件。
    private func publishPrepStep(_ step: PrepStep) {
        prepProgress = .preparing(step: step)
    }

    /// 触发生成 AI 摘要（含可选的标签推荐）。
    ///
    /// R-01 §3.2.7 Step 8：`includeTags` 由调用方根据「窗口打开瞬间冻结的 star 状态」决定。
    /// - 已 star（`includeTags == true`，默认）：摘要 + 标签推荐 一同生成
    /// - 未 star（`includeTags == false`）：仅摘要，**不发**标签生成请求
    ///   （未 star 的 repo 没有"绑定标签"语义，强行让 AI 生成无意义且浪费 token）
    func generate(repo: Repo, includeTags: Bool = true) async {
        // 重新点「生成摘要」时立刻藏掉上次失败条，避免与「正在准备…」叠显。
        errorMessage = nil
        tagErrorMessage = nil

        // 配置校验必须在 isGenerating / 代码上下文准备之前：
        // 没有可用 AI 服务时，不应进入「解析分支 / 下载 ZIP / 生成 XML」。
        do {
            try service.ensureGenerationClientsReady(
                includeSummary: true,
                includeTags: includeTags
            )
        } catch {
            presentPaywallIfNeeded(error)
            presentGenerateFailure(error)
            return
        }

        let codeContextRequest = RepoAICodeContextRequest()
        let usesCodeContext = service.isCodeContextEnabled
        // 把点击瞬间的开关状态冻结到本次请求：生成过程中即使用户在设置里打开开关，
        // 本次也不会突然开始下载 / 外部搜索；下一次生成再使用新设置。
        let usesExternalContext = service.isExternalContextAllowed(for: repo)
        if !usesCodeContext {
            codeContextRequest.skip()
        }

        // 作废任何残留的旧世代（例如上一仓未完成生成），再绑定本次 repo。
        generationEpoch &+= 1
        let runEpoch = generationEpoch
        activeGenerationRepoID = repo.id
        currentCodeContextRequest = codeContextRequest
        didSkipCodeContextForCurrentGeneration = false
        usesExternalContextForCurrentGeneration = usesExternalContext
        isGenerating = true
        streamingSummaryText = ""
        // 标签 hints、README 等本地材料会先读取；真正收到 provider 进度事件后再切到
        // `.preparingContext`，避免在尚未解析分支时提前展示“解析分支”假状态。
        // External Search 同理：等 `onExternalContextProgress(.started)` / `onContextResolved`
        // 再进入 `.fetchingExternalContext`，不要在 ZIP/XML 阶段误标成外搜。
        phase = .requestingSummary
        prepProgress = .idle
        defer {
            // 只有当前世代结束时才清 UI 生成态；被换仓作废的旧 generate 收尾不得清掉新生成。
            if generationEpoch == runEpoch {
                isGenerating = false
                streamingSummaryText = nil
                phase = nil
                currentCodeContextRequest = nil
                prepProgress = .idle
                usesExternalContextForCurrentGeneration = false
                didSkipCodeContextForCurrentGeneration = false
                activeGenerationRepoID = nil
            }
        }

        do {
            // 2026-06-14 dong4j 反馈：单仓路径之前漏传 hints，AI 不知道用户已有标签库 →
            // 容易生成「向量搜索 / Vector Search / 向量检索」这种同义不同名标签。
            // 与批量 AI 整理路径走同一份 `RepoAIInsightService.makeTagHints` 工厂，
            // 信号源单一：repo 自身标签（强信号）+ 字符预算内的全库复用词表，见 helper 注释。
            // includeTags == false 时不构造 hints，节省两次 DB 查询。
            let hints: AITagHints = includeTags
                ? await RepoAIInsightService.makeTagHints(
                    for: repo,
                    repoTagRepository: repoTagRepository,
                    tagRepository: tagRepository
                )
                : .empty
            guard generationEpoch == runEpoch else { return }

            let result = try await service.generateInsight(
                for: repo,
                existingTagHints: hints,
                includeTags: includeTags,
                codeContextRequest: codeContextRequest,
                onContextProgress: { [weak self] progress in
                    guard let self,
                          self.generationEpoch == runEpoch,
                          usesCodeContext,
                          !codeContextRequest.isSkipped else { return }
                    self.phase = .preparingContext
                    self.publishPrepStep(Self.mapStep(progress))
                },
                onContextResolved: { [weak self] in
                    guard let self, self.generationEpoch == runEpoch else { return }
                    self.prepProgress = .idle
                    // 代码上下文结束后：有外部搜索则先进入该阶段，否则直接准备 LLM 请求。
                    self.phase = usesExternalContext
                        ? .fetchingExternalContext
                        : .requestingSummary
                },
                onExternalContextProgress: { [weak self] progress in
                    guard let self,
                          self.generationEpoch == runEpoch,
                          usesExternalContext else { return }
                    switch progress {
                    case .started:
                        self.phase = .fetchingExternalContext
                    case .finished:
                        self.phase = .requestingSummary
                    }
                }
            ) { [weak self] partial in
                guard let self, self.generationEpoch == runEpoch else { return }
                self.streamingSummaryText = partial
                // 第一次 delta 时切阶段——之后所有 delta 都已经是 streamingSummary，
                // 不需要 if 判等比较（赋值同款值开销可忽略）。
                self.phase = .streamingSummary
            }
            guard generationEpoch == runEpoch else { return }

            insight = result.insight
            tagErrorMessage = result.tagErrorMessage
            // Y4：透传降级原因到 UI banner。
            contextDegradationReason = result.contextDegradationReason
            // Y9.3：透传 anysearch 降级原因到 UI banner。
            externalContextDegradationReason = result.externalContextDegradationReason
            errorMessage = nil
        } catch {
            guard generationEpoch == runEpoch else { return }
            presentPaywallIfNeeded(error)
            presentGenerateFailure(error)
        }
    }

    /// App 级 session store 清理（例如切换登录用户）时作废本仓运行态。
    ///
    /// 先递增 epoch 再取消 Task，可保证取消错误与迟到的 streaming 回调都被丢弃；
    /// `RepoAICodeContextRequest.skip()` 只终止当前代码上下文子任务，不改全局设置。
    func invalidateForSessionStoreReset() {
        generationEpoch &+= 1
        currentCodeContextRequest?.skip()
        currentCodeContextRequest = nil
        activeGenerationRepoID = nil
        isGenerating = false
        streamingSummaryText = nil
        phase = nil
        prepProgress = .idle
        usesExternalContextForCurrentGeneration = false
        didSkipCodeContextForCurrentGeneration = false
        loadedRepoID = nil
        loadingRepoID = nil
        isLoading = false
    }

    /// 把摘要生成失败分成两类用户文案：
    /// 1. 本地尚未配置 AI 服务（`RepoAIInsightError` / 明确的配置类 `AIClientError`）；
    /// 2. 已发起真实 AI 请求后失败（网络、鉴权、模型/URL 错误等），给出可行动建议。
    private func presentGenerateFailure(_ error: Error) {
        let friendly = UserFacingError.map(
            error,
            operation: String.l10n("diagnostics.operation.generateAIInsight"),
            service: "AI"
        )
        errorMessage = Self.userVisibleGenerateFailureMessage(for: error)
        friendly.record(category: "ai", operation: "insight.generate", service: "ai-provider")
    }

    private static func userVisibleGenerateFailureMessage(for error: Error) -> String {
        if let insightError = error as? RepoAIInsightError {
            return insightError.localizedDescription
        }
        if let aiError = error as? AIClientError {
            switch aiError {
            case .missingAPIKey, .invalidBaseURL:
                return aiError.localizedDescription
            case .emptyResponse, .responseTruncated, .modelListRequestFailed:
                return String(
                    format: String.l10n("ai.assistant.summary.error.requestFailedFormat"),
                    aiError.localizedDescription
                )
            }
        }
        let detail = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return String.l10n("ai.assistant.summary.error.requestFailed")
        }
        return String(
            format: String.l10n("ai.assistant.summary.error.requestFailedFormat"),
            detail
        )
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
    /// 只有详情页的人工确认路径允许新建；批量 AI 整理只复用已有标签。新建时继续走
    /// `TagAutoVisual` 的 FNV-1a 算法，保证同名标签稳定落到同一 (颜色, 图标)。
    /// 详细约束见 `TagAutoVisual` 注释。
    private func findOrCreateTag(named name: String) async throws -> Tag {
        if let existing = try await tagRepository.findByName(name) {
            return existing
        }
        // SQLite `name` 唯一约束默认区分大小写；AI 即使只改了大小写 / 空格 / 连字符，
        // 精确查询也会 miss 并创建重复项。手动确认新建前先做一次 AI 专用宽松匹配，
        // 仅当词表里确实没有等价形式时才继续创建。
        let key = AITagSuggestionPolicy.canonicalKey(name)
        let allTags = try await tagRepository.fetchAll()
        if let existing = allTags.first(where: {
            AITagSuggestionPolicy.canonicalKey($0.name) == key
        }) {
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

/// 单仓 AI 摘要的 App 级会话表。
///
/// 为什么放在依赖容器而不是 SwiftUI View：
/// - 内联浮层会随 repo 切换和折叠而销毁；View 持有 Task 会让进度与流式文本一起丢失；
/// - 每个 repo 独占一个 ViewModel 与 Task，天然隔离「跳过本次」、阶段和错误状态；
/// - Task 由本 Store 持有，因此 A、B 可以并发生成，切回任一仓都能恢复实时状态。
///
/// 这是进程内会话，不做磁盘恢复。App 退出后只有成功写入数据库的最终摘要会保留。
///
/// 空闲会话（无 running task）受 LRU 上限约束，避免「看过的仓」永久钉在内存里；
/// 正在生成的会话永不淘汰，直到任务结束或用户切换账号。
@MainActor
@Observable
final class RepoAIInsightSessionStore {
    private struct RunningTask {
        let id: UUID
        let repo: Repo
        let task: Task<Void, Never>
        var wasBackgrounded: Bool
    }

    private struct FinishedTask {
        let repo: Repo
        let state: RepoAISummaryBackgroundTask.State
    }

    /// 生产默认空闲会话上限；测试可注入更小值验证淘汰。
    static let defaultMaxIdleSessionCount = 24
    /// 后台摘要完成/失败后保留一小段时间，给用户确认结果并支持点击返回。
    static let finishedTaskRetention: Duration = .seconds(5)

    private let service: RepoAIInsightService
    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol
    private let maxIdleSessionCount: Int
    private var viewModels: [Repo.ID: RepoAIInsightViewModel] = [:]
    private var runningTasks: [Repo.ID: RunningTask] = [:]
    private var finishedTasks: [Repo.ID: FinishedTask] = [:]
    private var finishedExpiryTasks: [Repo.ID: Task<Void, Never>] = [:]
    /// 同一 repo 可能同时开着内联面板和独立窗口，因此不能只存 Bool。
    private var visiblePanelCounts: [Repo.ID: Int] = [:]
    /// 最近访问的空闲/活跃 repo，队尾最新；淘汰只扫无 running task 的前缀。
    private var lruOrder: [Repo.ID] = []

    init(
        service: RepoAIInsightService,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        maxIdleSessionCount: Int = RepoAIInsightSessionStore.defaultMaxIdleSessionCount
    ) {
        self.service = service
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
        self.maxIdleSessionCount = max(1, maxIdleSessionCount)
    }

    /// 同一 repo 始终返回同一 ViewModel；不同 repo 的运行态互不共享。
    func viewModel(for repoID: Repo.ID) -> RepoAIInsightViewModel {
        if let existing = viewModels[repoID] {
            touch(repoID)
            return existing
        }
        let viewModel = RepoAIInsightViewModel(
            service: service,
            tagRepository: tagRepository,
            repoTagRepository: repoTagRepository
        )
        viewModels[repoID] = viewModel
        touch(repoID)
        evictIdleSessionsIfNeeded()
        return viewModel
    }

    /// 启动由 Store 托管的生成 Task。
    ///
    /// 不把 Task 交给 Button / `.task` 生命周期持有，避免视图切换时 SwiftUI 取消工作。
    /// 每仓同一时间只允许一个生成；其它仓库不受影响，可以并行执行。
    func startGeneration(for repo: Repo, includeTags: Bool) {
        guard runningTasks[repo.id] == nil else { return }

        finishedExpiryTasks[repo.id]?.cancel()
        finishedExpiryTasks[repo.id] = nil
        finishedTasks[repo.id] = nil
        let viewModel = viewModel(for: repo.id)
        let taskID = UUID()
        let task = Task { [weak self, viewModel] in
            await viewModel.generate(repo: repo, includeTags: includeTags)
            self?.finishGeneration(for: repo.id, taskID: taskID)
        }
        runningTasks[repo.id] = RunningTask(
            id: taskID,
            repo: repo,
            task: task,
            wasBackgrounded: visiblePanelCounts[repo.id, default: 0] == 0
        )
        touch(repo.id)
    }

    /// 摘要面板挂载/卸载时维护引用计数；任务只在所有面板都不可见时进入 Sidebar。
    func panelDidAppear(for repoID: Repo.ID) {
        visiblePanelCounts[repoID, default: 0] += 1
    }

    func panelDidDisappear(for repoID: Repo.ID) {
        let next = max(0, visiblePanelCounts[repoID, default: 0] - 1)
        if next == 0 {
            visiblePanelCounts[repoID] = nil
            if var running = runningTasks[repoID] {
                running.wasBackgrounded = true
                runningTasks[repoID] = running
            }
        } else {
            visiblePanelCounts[repoID] = next
        }
    }

    /// Sidebar 只展示面板不可见的运行任务，以及曾进入后台的短暂完成态。
    var backgroundTasks: [RepoAISummaryBackgroundTask] {
        let running = runningTasks.values.compactMap { entry -> RepoAISummaryBackgroundTask? in
            guard visiblePanelCounts[entry.repo.id, default: 0] == 0 else { return nil }
            let phase = viewModels[entry.repo.id]?.phase
            return RepoAISummaryBackgroundTask(repo: entry.repo, state: .running(phase))
        }
        let finished = finishedTasks.values.compactMap { entry -> RepoAISummaryBackgroundTask? in
            guard visiblePanelCounts[entry.repo.id, default: 0] == 0 else { return nil }
            return RepoAISummaryBackgroundTask(repo: entry.repo, state: entry.state)
        }
        return (running + finished).sorted { lhs, rhs in
            if lhs.state.sortPriority != rhs.state.sortPriority {
                return lhs.state.sortPriority < rhs.state.sortPriority
            }
            return lhs.repo.fullName.localizedCaseInsensitiveCompare(rhs.repo.fullName) == .orderedAscending
        }
    }

    /// 登录用户变化时清空所有进程内状态，防止旧账号摘要状态显示到新账号。
    ///
    /// 必须等待取消真正完成后再允许依赖容器切换数据库；只发出 `cancel()` 就返回，
    /// 迟到的摘要持久化可能落进新用户数据库，造成跨账号数据污染。
    func removeAll() async {
        let tasks = runningTasks.values.map(\.task)
        runningTasks.removeAll()
        viewModels.values.forEach { $0.invalidateForSessionStoreReset() }
        viewModels.removeAll()
        finishedTasks.removeAll()
        finishedExpiryTasks.values.forEach { $0.cancel() }
        finishedExpiryTasks.removeAll()
        visiblePanelCounts.removeAll()
        lruOrder.removeAll()
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    /// 测试与诊断用：当前进程内会话数（含正在生成的仓）。
    var retainedSessionCount: Int { viewModels.count }

    private func finishGeneration(for repoID: Repo.ID, taskID: UUID) {
        guard let running = runningTasks[repoID], running.id == taskID else { return }
        runningTasks[repoID] = nil
        if running.wasBackgrounded {
            let state: RepoAISummaryBackgroundTask.State =
                viewModels[repoID]?.errorMessage == nil ? .completed : .failed
            finishedTasks[repoID] = FinishedTask(repo: running.repo, state: state)
            scheduleFinishedTaskExpiry(for: repoID)
        }
        // 任务结束后才允许按空闲上限淘汰；生成中的仓必须始终可切回。
        evictIdleSessionsIfNeeded()
    }

    private func scheduleFinishedTaskExpiry(for repoID: Repo.ID) {
        finishedExpiryTasks[repoID]?.cancel()
        finishedExpiryTasks[repoID] = Task { [weak self] in
            try? await Task.sleep(for: Self.finishedTaskRetention)
            guard !Task.isCancelled else { return }
            self?.finishedTasks[repoID] = nil
            self?.finishedExpiryTasks[repoID] = nil
        }
    }

    private func touch(_ repoID: Repo.ID) {
        if let index = lruOrder.firstIndex(of: repoID) {
            lruOrder.remove(at: index)
        }
        lruOrder.append(repoID)
    }

    /// 只驱逐「无 running task」的最旧会话；正在生成的仓始终保留。
    private func evictIdleSessionsIfNeeded() {
        var idleCount = viewModels.keys.reduce(into: 0) { count, repoID in
            if runningTasks[repoID] == nil { count += 1 }
        }
        guard idleCount > maxIdleSessionCount else { return }

        var index = 0
        while idleCount > maxIdleSessionCount, index < lruOrder.count {
            let candidate = lruOrder[index]
            if runningTasks[candidate] == nil, viewModels[candidate] != nil {
                viewModels[candidate] = nil
                lruOrder.remove(at: index)
                idleCount -= 1
                continue
            }
            index += 1
        }
    }
}

/// Sidebar 使用的单仓摘要后台任务只读快照。
struct RepoAISummaryBackgroundTask: Identifiable {
    enum State: Equatable {
        case running(SummaryPhase?)
        case completed
        case failed

        fileprivate var sortPriority: Int {
            switch self {
            case .running: 0
            case .failed: 1
            case .completed: 2
            }
        }
    }

    var id: Repo.ID { repo.id }
    let repo: Repo
    let state: State
}

private extension String {
    var normalizedTagName: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
