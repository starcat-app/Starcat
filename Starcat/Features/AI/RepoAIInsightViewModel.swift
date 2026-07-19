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

            // 打开面板只读摘要与标签缓存。代码上下文必须等用户发起生成后再准备，
            // 避免“只是查看空面板”也产生网络下载和本地 XML。
            prepProgress = .idle
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

    /// 用户在摘要生成中的“准备代码上下文”行点击停止。
    ///
    /// 这不是取消摘要：只取消当前 provider 子任务，并把本次 request 标记为跳过。
    /// `makeSource` 随后以空 `{codeContext}` 继续组装 metadata + README 等现有上下文；
    /// 下一次生成会创建全新的 request，因此自动恢复正常代码上下文策略。
    func skipCodeContextForCurrentGeneration(repo: Repo) {
        guard isGenerating, phase == .preparingContext else { return }

        didSkipCodeContextForCurrentGeneration = true
        currentCodeContextRequest?.skip()
        prepProgress = .idle
        phase = .requestingSummary
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
            isGenerating = false
            streamingSummaryText = nil
            phase = nil
            currentCodeContextRequest = nil
            prepProgress = .idle
            usesExternalContextForCurrentGeneration = false
        }

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
                    guard usesCodeContext,
                          let self,
                          !codeContextRequest.isSkipped else { return }
                    self.phase = .preparingContext
                    self.publishPrepStep(Self.mapStep(progress))
                },
                onContextResolved: { [weak self] in
                    guard let self else { return }
                    self.prepProgress = .idle
                    // 代码上下文结束后：有外部搜索则先进入该阶段，否则直接准备 LLM 请求。
                    self.phase = usesExternalContext
                        ? .fetchingExternalContext
                        : .requestingSummary
                },
                onExternalContextProgress: { [weak self] progress in
                    guard let self, usesExternalContext else { return }
                    switch progress {
                    case .started:
                        self.phase = .fetchingExternalContext
                    case .finished:
                        self.phase = .requestingSummary
                    }
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
            presentGenerateFailure(error)
        }
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
