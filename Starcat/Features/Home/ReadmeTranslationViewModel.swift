//
//  ReadmeTranslationViewModel.swift
//  Starcat
//
//  README 翻译 UI 状态机。
//
//  模块职责：
//  - 控制“原文 / 分段双语 / 全文译文”的展示；
//  - 把 WebView 提取的源段落交给 Service，并在每批完成后增量更新 DOM 渲染状态；
//  - 维护进度、取消、缓存过期和错误提示。
//
//  关键约束：
//  - SwiftUI 是翻译状态的单一来源；WKWebView 只执行段落提取和 DOM 注入；
//  - 取消不会清掉已完成段落，Service 已逐批落盘，下次点击从缺失段落继续；
//  - repo、语言或翻译方式切换后，旧异步回调必须过 isCurrentGeneration：
//    identity + 语言 + mode + !Task.isCancelled。缓存命中、onBatch、完成、
//    alreadyInTargetLanguage 都走同一道门，否则会把 A 的译文贴进 B 的 DOM。
//  - 主窗口共用一份 VM（星标 / 探索 / 活动 / 周刊 / Trending）。切条目时必须
//    由当前详情页 prepare 成新 identity；上屏还要按 identity 过滤，避免 B 的
//    WebView 吃到 A 的 renderState。
//

import Foundation

@MainActor
@Observable
final class ReadmeTranslationViewModel {

    enum DisplayMode: Equatable {
        case showingOriginal
        case showingTranslation(
            mode: ReadmeTranslationMode,
            language: ReadmeTranslationLanguage,
            createdAt: Date
        )
    }

    enum TranslationErrorKind {
        case none
        case aiConfiguration
        case other
    }

    private(set) var displayMode: DisplayMode = .showingOriginal
    private(set) var renderState: ReadmeTranslationRenderState = .hidden
    private(set) var isTranslating = false
    private(set) var completedSegmentCount = 0
    private(set) var totalSegmentCount = 0
    private(set) var errorMessage: String?
    private(set) var translationErrorKind: TranslationErrorKind = .none
    private(set) var paywallContext: ProPaywallContext?
    private(set) var cacheIsStale = false

    /// README 用 `readme:owner/name`；通知详情用 `inbox:threadId`。不能只用 repoId：
    /// 未入库通知没有稳定 GitHub id，全是 0 会让切线程时串台。
    private var currentIdentity: String?
    private var currentCacheOwner: String?
    private var currentCacheRepo: String?
    private var currentLanguage: ReadmeTranslationLanguage?
    private var currentMode: ReadmeTranslationMode?
    private var currentTask: Task<Void, Never>?
    private var renderRevision = 0
    private let service: any ReadmeTranslationServiceProtocol

    init(service: any ReadmeTranslationServiceProtocol) {
        self.service = service
    }

    // MARK: - 页面准备

    func prepare(
        repo: Repo?,
        sourceHtml: String?,
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode
    ) {
        prepare(
            identity: repo.map { Self.readmeIdentity(for: $0) },
            cacheOwner: repo?.owner,
            cacheRepo: repo?.name,
            sourceHtml: sourceHtml,
            targetLanguage: targetLanguage,
            mode: mode
        )
    }

    func prepare(
        identity: String?,
        cacheOwner: String?,
        cacheRepo: String?,
        sourceHtml: String?,
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode
    ) {
        currentTask?.cancel()
        currentTask = nil
        isTranslating = false
        errorMessage = nil
        translationErrorKind = .none
        displayMode = .showingOriginal
        renderState = .hidden
        completedSegmentCount = 0
        totalSegmentCount = 0
        cacheIsStale = false

        guard let identity, let cacheOwner, let cacheRepo else {
            currentIdentity = nil
            currentCacheOwner = nil
            currentCacheRepo = nil
            currentLanguage = nil
            currentMode = nil
            return
        }
        currentIdentity = identity
        currentCacheOwner = cacheOwner
        currentCacheRepo = cacheRepo
        currentLanguage = targetLanguage
        currentMode = mode

        let requestedIdentity = identity
        let requestedLanguage = targetLanguage
        let requestedMode = mode
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cached = try await self.service.cachedTranslation(
                    owner: cacheOwner,
                    repo: cacheRepo,
                    targetLanguage: requestedLanguage,
                    mode: requestedMode
                )
                guard self.isCurrentGeneration(
                    identity: requestedIdentity,
                    language: requestedLanguage,
                    mode: requestedMode
                ) else { return }

                if let cached, let sourceHtml, !sourceHtml.isEmpty {
                    self.cacheIsStale = !self.service.isCacheFresh(
                        cached: cached,
                        sourceHtml: sourceHtml
                    )
                } else {
                    self.cacheIsStale = cached?.isComplete == false
                }
            } catch {
                AppLog.ai.warning("ReadmeTranslation cache lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func changeLanguage(
        to language: ReadmeTranslationLanguage,
        repo: Repo?,
        sourceHtml: String?,
        mode: ReadmeTranslationMode
    ) {
        prepare(
            repo: repo,
            sourceHtml: sourceHtml,
            targetLanguage: language,
            mode: mode
        )
    }

    func changeMode(
        to mode: ReadmeTranslationMode,
        repo: Repo?,
        sourceHtml: String?,
        targetLanguage: ReadmeTranslationLanguage
    ) {
        prepare(
            repo: repo,
            sourceHtml: sourceHtml,
            targetLanguage: targetLanguage,
            mode: mode
        )
    }

    // MARK: - 用户操作

    func toggleTranslation(
        repo: Repo,
        sourceHtml: String,
        sourceSegments: [ReadmeSourceSegment],
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode
    ) {
        toggleTranslation(
            identity: Self.readmeIdentity(for: repo),
            cacheOwner: repo.owner,
            cacheRepo: repo.name,
            repoId: repo.id,
            sourceHtml: sourceHtml,
            sourceSegments: sourceSegments,
            targetLanguage: targetLanguage,
            mode: mode
        )
    }

    func toggleTranslation(
        identity: String,
        cacheOwner: String,
        cacheRepo: String,
        repoId: Int64? = nil,
        sourceHtml: String,
        sourceSegments: [ReadmeSourceSegment],
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode
    ) {
        if case .showingTranslation = displayMode {
            displayMode = .showingOriginal
            publishRenderState(
                isVisible: false,
                mode: mode,
                translations: renderState.translations,
                prefersAnimatedEntrance: false
            )
            return
        }

        startTranslation(
            identity: identity,
            cacheOwner: cacheOwner,
            cacheRepo: cacheRepo,
            repoId: repoId,
            sourceHtml: sourceHtml,
            sourceSegments: sourceSegments,
            targetLanguage: targetLanguage,
            mode: mode,
            force: false
        )
    }

    /// 对照已上屏时评论后到：只补缺段，不切回原文、不重翻已有译文。
    func continueTranslationIfNeeded(
        identity: String,
        cacheOwner: String,
        cacheRepo: String,
        repoId: Int64? = nil,
        sourceHtml: String,
        sourceSegments: [ReadmeSourceSegment],
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode
    ) {
        guard case .showingTranslation = displayMode, !isTranslating else { return }
        let done = Set(renderState.translations.map(\.id))
        let pending = TranslationSourceLanguageGate.segmentsNeedingTranslation(
            sourceSegments,
            target: targetLanguage
        )
        guard pending.contains(where: { !done.contains($0.id) }) else { return }
        startTranslation(
            identity: identity,
            cacheOwner: cacheOwner,
            cacheRepo: cacheRepo,
            repoId: repoId,
            sourceHtml: sourceHtml,
            sourceSegments: sourceSegments,
            targetLanguage: targetLanguage,
            mode: mode,
            force: false
        )
    }

    func regenerate(
        repo: Repo,
        sourceHtml: String,
        sourceSegments: [ReadmeSourceSegment],
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode
    ) {
        regenerate(
            identity: Self.readmeIdentity(for: repo),
            cacheOwner: repo.owner,
            cacheRepo: repo.name,
            repoId: repo.id,
            sourceHtml: sourceHtml,
            sourceSegments: sourceSegments,
            targetLanguage: targetLanguage,
            mode: mode
        )
    }

    func regenerate(
        identity: String,
        cacheOwner: String,
        cacheRepo: String,
        repoId: Int64? = nil,
        sourceHtml: String,
        sourceSegments: [ReadmeSourceSegment],
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode
    ) {
        startTranslation(
            identity: identity,
            cacheOwner: cacheOwner,
            cacheRepo: cacheRepo,
            repoId: repoId,
            sourceHtml: sourceHtml,
            sourceSegments: sourceSegments,
            targetLanguage: targetLanguage,
            mode: mode,
            force: true
        )
    }

    func cancelTranslation() {
        guard isTranslating else { return }
        currentTask?.cancel()
        currentTask = nil
        isTranslating = false
        errorMessage = nil
        translationErrorKind = .none
        // 已完成批次继续留在原文下方；下次点击会读取磁盘部分缓存并翻剩余段落。
    }

    func dismissError() {
        errorMessage = nil
        translationErrorKind = .none
    }

    func dismissPaywall() {
        paywallContext = nil
    }

    /// README 详情用 `readme:owner/name`。探索 / 活动 / 周刊和星标必须同一套，不能只用 repoId。
    static func readmeIdentity(owner: String, repo: String) -> String {
        "readme:\(owner)/\(repo)"
    }

    static func readmeIdentity(for repo: Repo) -> String {
        readmeIdentity(owner: repo.owner, repo: repo.name)
    }

    /// 只把「属于这个 identity」的译文交给 WebView。共享 VM 在切仓后的一帧里
    /// 仍可能带着上一仓的 renderState。
    func visibleRenderState(matching identity: String) -> ReadmeTranslationRenderState {
        guard renderState.isVisible, currentIdentity == identity else {
            return .hidden
        }
        return renderState
    }

    func isActivelyTranslating(matching identity: String) -> Bool {
        isTranslating && currentIdentity == identity
    }

    func isShowingTranslation(matching identity: String) -> Bool {
        guard currentIdentity == identity else { return false }
        if case .showingTranslation = displayMode { return true }
        return false
    }

    // MARK: - 翻译流程

    private func startTranslation(
        identity: String,
        cacheOwner: String,
        cacheRepo: String,
        repoId: Int64?,
        sourceHtml: String,
        sourceSegments: [ReadmeSourceSegment],
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode,
        force: Bool
    ) {
        let pending = TranslationSourceLanguageGate.segmentsNeedingTranslation(
            sourceSegments,
            target: targetLanguage
        )
        // 全部已是目标语言：不转圈、不打接口。混排时只让 Service 把对不上的段送出去。
        guard !pending.isEmpty else { return }

        currentTask?.cancel()
        currentIdentity = identity
        currentCacheOwner = cacheOwner
        currentCacheRepo = cacheRepo
        currentLanguage = targetLanguage
        currentMode = mode
        errorMessage = nil
        translationErrorKind = .none
        isTranslating = true
        totalSegmentCount = Set(sourceSegments.map(\.sourceHash)).count
        completedSegmentCount = 0

        currentTask = Task { [weak self] in
            await self?.performTranslation(
                identity: identity,
                cacheOwner: cacheOwner,
                cacheRepo: cacheRepo,
                repoId: repoId,
                sourceHtml: sourceHtml,
                sourceSegments: sourceSegments,
                targetLanguage: targetLanguage,
                mode: mode,
                force: force
            )
        }
    }

    private func performTranslation(
        identity: String,
        cacheOwner: String,
        cacheRepo: String,
        repoId: Int64?,
        sourceHtml: String,
        sourceSegments: [ReadmeSourceSegment],
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode,
        force: Bool
    ) async {
        let requestedIdentity = identity
        let requestedLanguage = targetLanguage
        let requestedMode = mode

        do {
            let cached = force ? nil : try await service.cachedTranslation(
                owner: cacheOwner,
                repo: cacheRepo,
                targetLanguage: targetLanguage,
                mode: mode
            )
            guard isCurrentGeneration(
                identity: requestedIdentity,
                language: requestedLanguage,
                mode: requestedMode
            ) else { return }

            if let cached {
                let rendered = service.renderedTranslations(
                    from: cached,
                    matching: sourceSegments
                )
                if !rendered.isEmpty {
                    applyTranslations(
                        rendered,
                        mode: mode,
                        language: targetLanguage,
                        createdAt: cachedCreatedAt(cached),
                        prefersAnimatedEntrance: false
                    )
                    completedSegmentCount = Set(
                        cached.segments.map(\.sourceHash)
                    ).intersection(Set(sourceSegments.map(\.sourceHash))).count
                }
                if service.isCacheFresh(cached: cached, sourceHtml: sourceHtml) {
                    cacheIsStale = false
                    isTranslating = false
                    currentTask = nil
                    return
                }
            }

            let record = try await service.translate(
                request: ReadmeTranslationRequest(
                    cacheOwner: cacheOwner,
                    cacheRepo: cacheRepo,
                    repoId: repoId,
                    sourceHtml: sourceHtml,
                    sourceSegments: sourceSegments,
                    targetLanguage: targetLanguage,
                    mode: mode
                ),
                cached: cached,
                onBatch: { [weak self] rendered, completed, total in
                    guard let self,
                          self.isCurrentGeneration(
                            identity: requestedIdentity,
                            language: requestedLanguage,
                            mode: requestedMode
                          )
                    else { return }
                    self.completedSegmentCount = completed
                    self.totalSegmentCount = total
                    self.applyTranslations(
                        rendered,
                        mode: mode,
                        language: targetLanguage,
                        createdAt: Date(),
                        prefersAnimatedEntrance: true
                    )
                }
            )

            guard isCurrentGeneration(
                identity: requestedIdentity,
                language: requestedLanguage,
                mode: requestedMode
            ) else { return }

            let rendered = service.renderedTranslations(from: record, matching: sourceSegments)
            applyTranslations(
                rendered,
                mode: mode,
                language: targetLanguage,
                createdAt: cachedCreatedAt(record),
                prefersAnimatedEntrance: true
            )
            completedSegmentCount = totalSegmentCount
            cacheIsStale = false
            isTranslating = false
            currentTask = nil
        } catch is CancellationError {
            // 主动取消不是错误；状态已经由 cancelTranslation / prepare 立即复位。
        } catch ReadmeTranslationError.alreadyInTargetLanguage {
            guard isCurrentGeneration(
                identity: requestedIdentity,
                language: requestedLanguage,
                mode: requestedMode
            ) else { return }
            isTranslating = false
            currentTask = nil
        } catch {
            guard isCurrentGeneration(
                identity: requestedIdentity,
                language: requestedLanguage,
                mode: requestedMode
            ) else { return }
            isTranslating = false
            currentTask = nil
            presentPaywallIfNeeded(error)
            let friendly = UserFacingError.map(
                error,
                operation: String.l10n("diagnostics.operation.translateReadme"),
                service: "AI"
            )
            errorMessage = friendly.message
            translationErrorKind = classifyError(error)
            friendly.record(
                category: "ai",
                operation: "readmeTranslation.perform",
                service: "ai-provider"
            )
        }
    }

    /// 切仓 / 切语言 / 取消后，旧 Task 可能还停在 await 之后。
    /// 过期回调不能再改当前页的译文、进度或 `currentTask`。
    private func isCurrentGeneration(
        identity: String,
        language: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode
    ) -> Bool {
        !Task.isCancelled
            && currentIdentity == identity
            && currentLanguage == language
            && currentMode == mode
    }

    private func applyTranslations(
        _ translations: [ReadmeRenderedTranslation],
        mode: ReadmeTranslationMode,
        language: ReadmeTranslationLanguage,
        createdAt: Date,
        prefersAnimatedEntrance: Bool
    ) {
        guard !translations.isEmpty else { return }
        displayMode = .showingTranslation(mode: mode, language: language, createdAt: createdAt)
        publishRenderState(
            isVisible: true,
            mode: mode,
            translations: translations,
            prefersAnimatedEntrance: prefersAnimatedEntrance
        )
        errorMessage = nil
    }

    private func publishRenderState(
        isVisible: Bool,
        mode: ReadmeTranslationMode,
        translations: [ReadmeRenderedTranslation],
        prefersAnimatedEntrance: Bool
    ) {
        renderRevision &+= 1
        renderState = ReadmeTranslationRenderState(
            isVisible: isVisible,
            mode: mode,
            translations: translations,
            revision: renderRevision,
            prefersAnimatedEntrance: prefersAnimatedEntrance
        )
    }

    private func cachedCreatedAt(_ cached: ReadmeTranslation) -> Date {
        ISO8601DateFormatter.githubDate(from: cached.createdAt) ?? Date()
    }

    // MARK: - 错误分类

    private func classifyError(_ error: Error) -> TranslationErrorKind {
        if let translation = error as? ReadmeTranslationError {
            switch translation {
            case .missingProvider, .missingAPIKey:
                return .aiConfiguration
            case .emptySource, .structureBroken:
                return .other
            case .alreadyInTargetLanguage:
                return .none
            }
        }
        if let ai = error as? AIClientError {
            switch ai {
            case .missingAPIKey, .invalidBaseURL, .authenticationRejected, .paymentRequired:
                return .aiConfiguration
            case .invalidChatHistory, .emptyResponse, .responseTruncated, .modelListRequestFailed,
                 .rateLimited, .requestRejected, .networkUnavailable, .timedOut, .requestFailed:
                return .other
            }
        }
        return .other
    }

    private func presentPaywallIfNeeded(_ error: Error) {
        guard let gateError = error as? EntitlementGateError else { return }
        paywallContext = ProPaywallContext(
            feature: gateError.feature,
            message: gateError.localizedDescription
        )
    }
}
