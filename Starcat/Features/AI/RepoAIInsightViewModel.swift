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
//  - 成功应用标签后通知 HomeViewModel 刷新 Sidebar 计数与当前列表。
//

import Foundation
import Observation

/// Y1（2026-06-13）：AI 摘要生成的两阶段状态机。
///
/// 用户体验目标：在 RepoContextPacker pipeline 跑的几秒 ~ 十几秒里给 UI 一个有信息量的
/// 进度提示，而不是空白旋转 spinner。
///
/// 两阶段区分点：
///   - `preparingContext`：从 `generate(repo:)` 入口开始，直到收到第一个 streaming delta。
///     语义上覆盖：makeSource（含 RepoContextPacker pack）+ LLM 请求建立连接。
///   - `streamingSummary`：收到第一个 streaming delta 之后切换；语义 = LLM 输出阶段。
enum SummaryPhase: Sendable {
    case preparingContext
    case streamingSummary
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
            insight = try await service.cachedInsight(for: repo)
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

    /// 触发生成 AI 摘要（含可选的标签推荐）。
    ///
    /// R-01 §3.2.7 Step 8：`includeTags` 由调用方根据「窗口打开瞬间冻结的 star 状态」决定。
    /// - 已 star（`includeTags == true`，默认）：摘要 + 标签推荐 一同生成
    /// - 未 star（`includeTags == false`）：仅摘要，**不发**标签生成请求
    ///   （未 star 的 repo 没有"绑定标签"语义，强行让 AI 生成无意义且浪费 token）
    func generate(repo: Repo, includeTags: Bool = true) async {
        isGenerating = true
        streamingSummaryText = ""
        // Y1：入口先设 preparingContext，让 UI 在 makeSource（含 RepoContextPacker）期间
        // 显示"准备代码上下文…"文案。首个 streaming delta 到来时再切到 streamingSummary。
        phase = .preparingContext
        defer {
            isGenerating = false
            streamingSummaryText = nil
            phase = nil
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
                includeTags: includeTags
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
