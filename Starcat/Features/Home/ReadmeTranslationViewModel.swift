//
//  ReadmeTranslationViewModel.swift
//  Starcat
//
//  README 翻译视图模型（HOM-68）。
//
//  模块职责：
//  - 承载详情页"翻译 README"按钮的全部 UI 状态：当前显示原文还是译文、
//    是否正在翻译、缓存翻译于何时、出错信息是什么。
//  - 与 `ReadmeViewModel` 完全解耦——README 原文的 SWR 状态机仍由后者负责，
//    本 VM 只关心"在原文之上叠加一层翻译"。
//  - 切换 repo / 切换目标语言时自动重置到展示原文 + 拉取该语言的本地缓存。
//
//  关键约束：
//  - `@MainActor`：所有状态写入都在主线程，与 ReadmeViewModel 对齐。
//  - 单一 in-flight 翻译任务：用户连点"翻译"按钮时取消上一个再发新的，
//    避免两份 onDelta 流并发写 streamingHtml 互相覆盖。
//  - 翻译失败 → 状态切回 `.showingOriginal` + 写 `errorMessage`，
//    UI 端按 HOM-68「翻译失败时保留原 README 展示」原则继续渲染原文。
//  - 切 repo / 切语言 时**不主动清掉错误**——保留一帧便于用户看清失败原因；
//    下一次进入翻译流程（`translate(force:)`）前才清。
//

import Foundation

@MainActor
@Observable
final class ReadmeTranslationViewModel {

    /// 当前 README 区显示状态。
    enum DisplayMode: Equatable {
        /// 默认：展示原始 README。
        case showingOriginal
        /// 展示翻译版（来源可能是缓存也可能是本次新生成）。
        case showingTranslation(html: String, language: ReadmeTranslationLanguage, createdAt: Date)
    }

    /// 翻译错误分类（驱动 toast 是否显示操作按钮）。
    enum TranslationErrorKind {
        case none
        /// AI 配置缺失（provider / API Key 未配）→ 引导跳转设置页。
        case aiConfiguration
        /// 其他错误（网络、AI 服务异常、结构破坏等）→ 仅提供关闭。
        case other
    }

    /// 当前显示模式（驱动 UI 在原文 / 译文之间切换）。
    private(set) var displayMode: DisplayMode = .showingOriginal

    /// 正在翻译中？UI 用此驱动按钮 ProgressView。
    private(set) var isTranslating: Bool = false

    /// 流式翻译过程中累积的 HTML 文本（用于 UI 实时预览，可选不消费）。
    ///
    /// **注意**：流式过程中不直接把 streamingHtml 推到 ReadmeWebView，
    /// 因为 WebView 的 loadHTMLString 每次都会触发"白屏 → 重新渲染"的 200ms 抖动，
    /// 在长 README 翻译过程中频繁调用会让用户看到不断闪烁。UI 当前选择"翻译期
    /// 仍显示原文 + 上方进度条"，仅在最终成功后一次性替换为译文。
    /// 字段保留是为了未来若做"侧栏小预览"或调试日志时可以读到流式增量。
    private(set) var streamingHtml: String?

    /// 翻译错误消息（已本地化）。
    private(set) var errorMessage: String?

    /// 当前错误的分类（驱动 toast 是否显示"前往设置"等操作按钮）。
    private(set) var translationErrorKind: TranslationErrorKind = .none

    private(set) var paywallContext: ProPaywallContext?

    /// 缓存翻译与当前源 HTML 不再匹配时为 true，UI 提示"原 README 已更新，建议重新翻译"。
    ///
    /// 仅在 `loadCachedTranslation` 命中时被写入：缓存匹配时为 false，缓存与当前
    /// 源 hash 不一致时为 true。每次 `translate` 成功后会复位为 false。
    private(set) var cacheIsStale: Bool = false

    /// 当前关注的 repoId（切换 repo 时用于丢弃旧响应）。
    private var currentRepoId: Int64?

    /// 当前选择的目标语言（切换语言时用于丢弃旧响应）。
    private var currentLanguage: ReadmeTranslationLanguage?

    /// 当前 in-flight 翻译任务。新请求来时先 cancel。
    private var currentTask: Task<Void, Never>?

    private let service: ReadmeTranslationService

    init(service: ReadmeTranslationService) {
        self.service = service
    }

    // MARK: - 入口：切 repo / 切语言

    /// 切到新 repo 时调用：重置显示态 + 异步预载该 repo + 当前语言的缓存。
    ///
    /// 不立即调用 LLM：HOM-68 验收要求"AI 摘要 / 标签推荐都是用户显式触发"，
    /// 翻译同样按需。这里只做"如果本地已有翻译，标记 cacheIsStale 让 UI 显示
    /// 一颗已翻译指示"——具体是否展示出译文仍由用户点按钮决定。
    func prepare(
        repo: Repo?,
        sourceHtml: String?,
        targetLanguage: ReadmeTranslationLanguage
    ) {
        currentTask?.cancel()
        errorMessage = nil
        translationErrorKind = .none
        streamingHtml = nil
        displayMode = .showingOriginal
        cacheIsStale = false

        guard let repo else {
            currentRepoId = nil
            currentLanguage = nil
            return
        }
        currentRepoId = repo.id
        currentLanguage = targetLanguage

        // 仅当源 HTML 已就绪时才查缓存对齐；ReadmeViewModel 还在 loading 时
        // 没必要预查（缓存键不依赖 sourceHash，但是 staleness 计算依赖）。
        //
        // HOM-68 v2（2026-06-15）：cachedTranslation 接口从 repoId 改为 owner/repo
        // —— 磁盘 cache 路径用 `<owner>/<repo>/<lang>.{html,json}`，trending /
        // activity 这类 ephemeral repo 拿不到稳定 GitHub repo id 时也能命中。
        let requestedRepoId = repo.id
        let requestedOwner = repo.owner
        let requestedName = repo.name
        let requestedLanguage = targetLanguage
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cached = try await self.service.cachedTranslation(
                    owner: requestedOwner,
                    repo: requestedName,
                    targetLanguage: requestedLanguage
                )
                guard !Task.isCancelled,
                      self.currentRepoId == requestedRepoId,
                      self.currentLanguage == requestedLanguage
                else { return }

                guard let cached else {
                    self.cacheIsStale = false
                    return
                }
                if let source = sourceHtml, !source.isEmpty {
                    self.cacheIsStale = !self.service.isCacheFresh(cached: cached, sourceHtml: source)
                } else {
                    self.cacheIsStale = false
                }
            } catch {
                // 读缓存失败不打扰用户：缓存层错误属于内部噪音
                AppLog.ai.warning("ReadmeTranslation cache lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 切换目标语言：与 prepare 同语义，但保留 repo 上下文 + 立即查新语言的缓存。
    func changeLanguage(
        to language: ReadmeTranslationLanguage,
        repo: Repo?,
        sourceHtml: String?
    ) {
        prepare(repo: repo, sourceHtml: sourceHtml, targetLanguage: language)
    }

    // MARK: - 入口：用户主动操作

    /// 用户点"显示翻译"按钮。
    ///
    /// 三个分支：
    /// 1. 已显示译文 → 切回原文（toggle 行为）；
    /// 2. 未显示译文 + 本地缓存命中 + 缓存未过期 → 直接展示缓存；
    /// 3. 其他（无缓存 / 缓存已过期 / 用户主动重新翻译）→ 调 LLM 重新翻译。
    ///
    /// 第二分支不会扣 AI 配额——这是 HOM-68 验收的核心缓存行为。
    func toggleTranslation(
        repo: Repo,
        sourceHtml: String,
        targetLanguage: ReadmeTranslationLanguage
    ) {
        // 分支 1：当前已在显示翻译 → 切回原文，不发请求
        if case .showingTranslation = displayMode {
            displayMode = .showingOriginal
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                // 命中缓存且未过期 → 直接上屏
                // HOM-68 v2：cachedTranslation 接口从 repoId 改为 owner/repo（见 prepare 同款注释）。
                if let cached = try await self.service.cachedTranslation(
                    owner: repo.owner,
                    repo: repo.name,
                    targetLanguage: targetLanguage
                ), self.service.isCacheFresh(cached: cached, sourceHtml: sourceHtml) {
                    self.applyCachedTranslation(cached, language: targetLanguage)
                    return
                }
                // 否则走完整翻译
                await self.performTranslation(
                    repo: repo,
                    sourceHtml: sourceHtml,
                    targetLanguage: targetLanguage
                )
            } catch {
                self.presentPaywallIfNeeded(error)
                let friendly = UserFacingError.map(
                    error,
                    operation: String.l10n("diagnostics.operation.translateReadme"),
                    service: "AI"
                )
                self.errorMessage = friendly.message
                self.translationErrorKind = self.classifyError(error)
                friendly.record(category: "ai", operation: "readmeTranslation.start", service: "ai-provider")
            }
        }
    }

    /// 强制重新翻译（覆盖本地缓存）。
    ///
    /// 入口：UI 里"重新翻译"按钮，或缓存因原 README 更新而 stale 时用户点确认。
    func regenerate(
        repo: Repo,
        sourceHtml: String,
        targetLanguage: ReadmeTranslationLanguage
    ) {
        Task { [weak self] in
            await self?.performTranslation(
                repo: repo,
                sourceHtml: sourceHtml,
                targetLanguage: targetLanguage
            )
        }
    }

    /// UI 显式清除当前错误（toast 关闭 / 手动 dismiss 时调用）。
    func dismissError() {
        errorMessage = nil
        translationErrorKind = .none
    }

    func dismissPaywall() {
        paywallContext = nil
    }

    /// 用户主动取消当前翻译任务（2026-06-14 dong4j 反馈：详情页右下角翻译按钮没有
    /// 停止入口，hover 时切到 stop 图标 + 点击触发取消）。
    ///
    /// 设计要点：
    ///   - **不写 errorMessage**：用户主动取消不是错误，无需 banner 打扰；
    ///   - **不清 displayMode**：保留当前显示（原文 / 旧译文），只取消正在跑的请求；
    ///   - **复位 isTranslating + streamingHtml**：让 UI 立即从"翻译中"切回常规态；
    ///   - **idempotent**：未在翻译时调用为 no-op（按钮已经走 toggle 分支，但守门更稳）。
    ///
    /// `currentTask?.cancel()` 触发 `service.translate` 内部的 `try Task.checkCancellation()`
    /// 链路，最终 `performTranslation` 的 do 块抛 `CancellationError` 进入 catch；
    /// catch 里设的 `errorMessage = error.localizedDescription` 会写入"已取消"字样
    /// （CancellationError.localizedDescription = "The operation couldn't be completed.
    /// (Swift.CancellationError error 1.)"），不友好——所以本函数主动把 errorMessage
    /// 清掉防御这种竞态。
    func cancelTranslation() {
        guard isTranslating else { return }
        currentTask?.cancel()
        currentTask = nil
        isTranslating = false
        streamingHtml = nil
        errorMessage = nil
        translationErrorKind = .none
    }

    // MARK: - 内部实现

    /// 把已读到的缓存切到展示态。
    private func applyCachedTranslation(
        _ cached: ReadmeTranslation,
        language: ReadmeTranslationLanguage
    ) {
        let createdAt = ISO8601DateFormatter.shared.date(from: cached.createdAt) ?? Date()
        displayMode = .showingTranslation(
            html: cached.translatedHtml,
            language: language,
            createdAt: createdAt
        )
        cacheIsStale = false
        errorMessage = nil
    }

    /// 实际跑一次 AI 翻译并接管所有状态。
    private func performTranslation(
        repo: Repo,
        sourceHtml: String,
        targetLanguage: ReadmeTranslationLanguage
    ) async {
        currentTask?.cancel()
        let requestedRepoId = repo.id
        let requestedLanguage = targetLanguage
        currentRepoId = repo.id
        currentLanguage = targetLanguage

        errorMessage = nil
        streamingHtml = nil
        isTranslating = true
        defer { isTranslating = false }

        do {
            let record = try await service.translate(
                request: ReadmeTranslationRequest(
                    repo: repo,
                    sourceHtml: sourceHtml,
                    targetLanguage: targetLanguage
                ),
                onDelta: { [weak self] partial in
                    // 流式期不直接 push 给 WebView（避免白屏抖动），仅保留累积值。
                    self?.streamingHtml = partial
                }
            )

            guard self.currentRepoId == requestedRepoId,
                  self.currentLanguage == requestedLanguage
            else {
                // 期间用户切了 repo 或语言：结果不再适用，缓存仍然有效，但不上屏。
                return
            }

            applyCachedTranslation(record, language: targetLanguage)
            streamingHtml = nil
        } catch {
            // 失败保留原 README（HOM-68 验收要求）：不动 displayMode。
            presentPaywallIfNeeded(error)
            let friendly = UserFacingError.map(
                error,
                operation: String.l10n("diagnostics.operation.translateReadme"),
                service: "AI"
            )
            errorMessage = friendly.message
            streamingHtml = nil
            translationErrorKind = classifyError(error)
            AppLog.ai.error("README translation failed repo=\(repo.fullName, privacy: .public) language=\(targetLanguage.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            friendly.record(
                category: "ai",
                operation: "readmeTranslation.perform",
                service: "ai-provider"
            )
        }
    }

    /// 将翻译错误分类为 `.aiConfiguration`（需跳转设置）或 `.other`。
    ///
    /// 与 `UserFacingError.mapReadmeTranslation` 保持同步的映射规则：
    /// - `ReadmeTranslationError.missingProvider` / `.missingAPIKey` → aiConfiguration
    /// - `AIClientError.missingAPIKey` / `.invalidBaseURL` → aiConfiguration
    /// - 其余 → other
    private func classifyError(_ error: Error) -> TranslationErrorKind {
        if let rt = error as? ReadmeTranslationError {
            switch rt {
            case .missingProvider, .missingAPIKey:
                return .aiConfiguration
            case .emptySource, .structureBroken:
                return .other
            }
        }
        if let ai = error as? AIClientError {
            switch ai {
            case .missingAPIKey, .invalidBaseURL:
                return .aiConfiguration
            case .emptyResponse, .responseTruncated, .modelListRequestFailed:
                return .other
            }
        }
        return .other
    }

    private func presentPaywallIfNeeded(_ error: Error) {
        guard let gateError = error as? EntitlementGateError else { return }
        paywallContext = ProPaywallContext(feature: gateError.feature, message: gateError.localizedDescription)
    }
}
