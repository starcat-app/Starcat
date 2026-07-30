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
//  - repo、语言或翻译方式切换后，旧异步回调必须通过三者守门，不能串到新页面。
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

    private var currentRepoId: Int64?
    private var currentLanguage: ReadmeTranslationLanguage?
    private var currentMode: ReadmeTranslationMode?
    private var currentTask: Task<Void, Never>?
    private var renderRevision = 0
    private let service: ReadmeTranslationService

    init(service: ReadmeTranslationService) {
        self.service = service
    }

    // MARK: - 页面准备

    func prepare(
        repo: Repo?,
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

        guard let repo else {
            currentRepoId = nil
            currentLanguage = nil
            currentMode = nil
            return
        }
        currentRepoId = repo.id
        currentLanguage = targetLanguage
        currentMode = mode

        let requestedRepoId = repo.id
        let requestedLanguage = targetLanguage
        let requestedMode = mode
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cached = try await self.service.cachedTranslation(
                    owner: repo.owner,
                    repo: repo.name,
                    targetLanguage: requestedLanguage,
                    mode: requestedMode
                )
                guard !Task.isCancelled,
                      self.currentRepoId == requestedRepoId,
                      self.currentLanguage == requestedLanguage,
                      self.currentMode == requestedMode
                else { return }

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
        if case .showingTranslation = displayMode {
            displayMode = .showingOriginal
            publishRenderState(
                isVisible: false,
                mode: mode,
                translations: renderState.translations
            )
            return
        }

        startTranslation(
            repo: repo,
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
        startTranslation(
            repo: repo,
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

    // MARK: - 翻译流程

    private func startTranslation(
        repo: Repo,
        sourceHtml: String,
        sourceSegments: [ReadmeSourceSegment],
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode,
        force: Bool
    ) {
        currentTask?.cancel()
        currentRepoId = repo.id
        currentLanguage = targetLanguage
        currentMode = mode
        errorMessage = nil
        translationErrorKind = .none
        isTranslating = true
        totalSegmentCount = Set(sourceSegments.map(\.sourceHash)).count
        completedSegmentCount = 0

        currentTask = Task { [weak self] in
            await self?.performTranslation(
                repo: repo,
                sourceHtml: sourceHtml,
                sourceSegments: sourceSegments,
                targetLanguage: targetLanguage,
                mode: mode,
                force: force
            )
        }
    }

    private func performTranslation(
        repo: Repo,
        sourceHtml: String,
        sourceSegments: [ReadmeSourceSegment],
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode,
        force: Bool
    ) async {
        let requestedRepoId = repo.id
        let requestedLanguage = targetLanguage
        let requestedMode = mode

        do {
            let cached = force ? nil : try await service.cachedTranslation(
                owner: repo.owner,
                repo: repo.name,
                targetLanguage: targetLanguage,
                mode: mode
            )

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
                        createdAt: cachedCreatedAt(cached)
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
                    repo: repo,
                    sourceHtml: sourceHtml,
                    sourceSegments: sourceSegments,
                    targetLanguage: targetLanguage,
                    mode: mode
                ),
                cached: cached,
                onBatch: { [weak self] rendered, completed, total in
                    guard let self,
                          self.currentRepoId == requestedRepoId,
                          self.currentLanguage == requestedLanguage,
                          self.currentMode == requestedMode
                    else { return }
                    self.completedSegmentCount = completed
                    self.totalSegmentCount = total
                    self.applyTranslations(
                        rendered,
                        mode: mode,
                        language: targetLanguage,
                        createdAt: Date()
                    )
                }
            )

            guard currentRepoId == requestedRepoId,
                  currentLanguage == requestedLanguage,
                  currentMode == requestedMode
            else { return }

            let rendered = service.renderedTranslations(from: record, matching: sourceSegments)
            applyTranslations(
                rendered,
                mode: mode,
                language: targetLanguage,
                createdAt: cachedCreatedAt(record)
            )
            completedSegmentCount = totalSegmentCount
            cacheIsStale = false
            isTranslating = false
            currentTask = nil
        } catch is CancellationError {
            // 主动取消不是错误；状态已经由 cancelTranslation 立即复位。
        } catch {
            guard currentRepoId == requestedRepoId,
                  currentLanguage == requestedLanguage,
                  currentMode == requestedMode
            else { return }
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

    private func applyTranslations(
        _ translations: [ReadmeRenderedTranslation],
        mode: ReadmeTranslationMode,
        language: ReadmeTranslationLanguage,
        createdAt: Date
    ) {
        guard !translations.isEmpty else { return }
        displayMode = .showingTranslation(mode: mode, language: language, createdAt: createdAt)
        publishRenderState(isVisible: true, mode: mode, translations: translations)
        errorMessage = nil
    }

    private func publishRenderState(
        isVisible: Bool,
        mode: ReadmeTranslationMode,
        translations: [ReadmeRenderedTranslation]
    ) {
        renderRevision &+= 1
        renderState = ReadmeTranslationRenderState(
            isVisible: isVisible,
            mode: mode,
            translations: translations,
            revision: renderRevision
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
