//
//  ReadmeTranslationService.swift
//  Starcat
//
//  README 翻译服务。
//
//  模块职责：
//  - 接收 WebView 已提取的可见文本段落，不再把整份 HTML 交给模型；
//  - 先翻译一个小批次尽快首屏回填，再以最多 4 路并发完成后续批次；
//  - 每完成一批立即写入磁盘，因此用户取消后下次可以从未完成段落继续；
//  - 以“源文本指纹 → 译文”保存产物，并按翻译方式隔离缓存。
//
//  关键约束：
//  - AI 只处理纯文本和稳定 id，不拥有 HTML；标签、链接、图片与代码结构不会被模型改坏；
//  - 并发上限固定为 4，并采用完成一个再补一个的有界调度，避免长 README 瞬间创建几十个请求；
//  - 结果必须是严格 JSON，且 id 集合与输入完全一致，否则整批丢弃，不注入错误位置；
//  - Service 为 `@MainActor`，但真正的网络等待在 Sendable AI client 的异步方法中，
//    最多四个 child task 可以并行等待，不会阻塞主线程。
//

import CryptoKit
import Foundation

/// README 翻译错误。
enum ReadmeTranslationError: Error, LocalizedError, Equatable {
    case missingProvider
    case missingAPIKey
    case emptySource
    /// 模型没有返回可安全对齐到源段落的完整 JSON。
    case structureBroken

    var errorDescription: String? {
        switch self {
        case .missingProvider:
            return String.l10n("readme.translate.error.missingProvider")
        case .missingAPIKey:
            return String.l10n("readme.translate.error.missingAPIKey")
        case .emptySource:
            return String.l10n("readme.translate.error.emptySource")
        case .structureBroken:
            return String.l10n("readme.translate.error.structureBroken")
        }
    }
}

/// 一次 README 翻译的完整上下文。
struct ReadmeTranslationRequest: Sendable {
    var repo: Repo
    /// 只用于完整文档指纹；不会发送给 AI。
    var sourceHtml: String
    /// WebView 从可见 DOM 中提取的自然语言段落。
    var sourceSegments: [ReadmeSourceSegment]
    var targetLanguage: ReadmeTranslationLanguage
    var mode: ReadmeTranslationMode
}

@MainActor
final class ReadmeTranslationService {

    /// README 后续批次的固定并发上限。首批仍单独串行完成，以保证最快首屏反馈。
    nonisolated static let maxConcurrentBatchCount = 4

    typealias BatchProgressHandler = @MainActor (
        _ rendered: [ReadmeRenderedTranslation],
        _ completedCount: Int,
        _ totalCount: Int
    ) -> Void

    private let translationRepository: any ReadmeTranslationRepositoryProtocol
    private let settings: AppSettings
    private let keychain: any KeychainManaging
    private let entitlementGate: EntitlementGate?

    init(
        translationRepository: any ReadmeTranslationRepositoryProtocol,
        settings: AppSettings,
        entitlementGate: EntitlementGate? = nil,
        keychain: any KeychainManaging = KeychainManager.shared
    ) {
        self.translationRepository = translationRepository
        self.settings = settings
        self.keychain = keychain
        self.entitlementGate = entitlementGate
    }

    // MARK: - 公开接口

    func cachedTranslation(
        owner: String,
        repo: String,
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode = .segmented
    ) async throws -> ReadmeTranslation? {
        try await translationRepository.find(
            owner: owner,
            repo: repo,
            targetLanguage: targetLanguage.rawValue,
            mode: mode
        )
    }

    /// 完整命中必须同时满足文档指纹一致和全部段落完成。
    nonisolated func isCacheFresh(
        cached: ReadmeTranslation,
        sourceHtml: String
    ) -> Bool {
        cached.isComplete && cached.sourceHash == Self.hash(sourceHtml)
    }

    /// 把缓存中的段落译文重新对齐到当前 DOM id。
    ///
    /// README 小改或段落重排后，未变化段落仍能命中；DOM id 不落盘，所以不会把旧位置
    /// 误套到新页面。
    nonisolated func renderedTranslations(
        from cached: ReadmeTranslation,
        matching sourceSegments: [ReadmeSourceSegment]
    ) -> [ReadmeRenderedTranslation] {
        let translatedByHash = Dictionary(
            cached.segments.map { ($0.sourceHash, $0.translatedText) },
            uniquingKeysWith: { first, _ in first }
        )
        return sourceSegments.compactMap { source in
            guard let text = translatedByHash[source.sourceHash] else { return nil }
            return ReadmeRenderedTranslation(id: source.id, translatedText: text)
        }
    }

    /// 分批翻译并增量写缓存。
    ///
    /// - Parameters:
    ///   - cached: 允许复用的旧缓存；强制重新翻译时传 nil。
    ///   - onBatch: 首批和每个并发批次完成后回调当前累计可渲染结果。
    /// - Returns: 完整或部分记录。正常返回一定完整；用户取消时，已完成批次已提前落盘。
    func translate(
        request: ReadmeTranslationRequest,
        cached: ReadmeTranslation?,
        onBatch: BatchProgressHandler? = nil
    ) async throws -> ReadmeTranslation {
        try entitlementGate?.requirePro(.readmeTranslation)

        let trimmedSource = request.sourceHtml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !request.sourceSegments.isEmpty else {
            throw ReadmeTranslationError.emptySource
        }

        let task = settings.aiTranslationTask
        let (client, model) = try makeClient(task: task, fallbackModel: settings.aiChatModel)
        let parameters = settings.effectiveParameters(for: task)
        let configuredPrompt = request.mode == .segmented
            ? task.prompt
            : settings.aiFullTranslationPrompt
        let prompt = Self.effectivePromptConfiguration(
            configuredPrompt,
            mode: request.mode
        )
        let documentHash = Self.hash(trimmedSource)

        // 同一段落可能在 README 中重复出现；按 hash 去重请求，渲染时再映射回每个 DOM id。
        let uniqueSources = Self.uniqueSegments(request.sourceSegments)
        let currentSourceHashes = Set(uniqueSources.map(\.sourceHash))
        var translatedByHash: [String: String] = [:]
        if let cached {
            for item in cached.segments where currentSourceHashes.contains(item.sourceHash) {
                translatedByHash[item.sourceHash] = item.translatedText
            }
        }

        let missing = uniqueSources.filter { translatedByHash[$0.sourceHash] == nil }
        var record = Self.makeRecord(
            request: request,
            model: model,
            documentHash: documentHash,
            translatedByHash: translatedByHash,
            isComplete: missing.isEmpty
        )

        // 先把可复用缓存立即交给 UI。即使后续网络失败，用户也能看到已完成段落。
        if !translatedByHash.isEmpty {
            onBatch?(
                renderedTranslations(from: record, matching: request.sourceSegments),
                translatedByHash.count,
                uniqueSources.count
            )
        }

        guard !missing.isEmpty else {
            // 旧缓存可能是“内容重排但段落全复用”；写回当前文档 hash，后续即可完整命中。
            try await translationRepository.upsert(
                record,
                owner: request.repo.owner,
                repo: request.repo.name,
                mode: request.mode
            )
            return record
        }

        let batches = Self.makeBatches(missing)
        let firstBatch = batches[0]
        let firstRequest = try Self.makeAIRequest(
            batch: firstBatch,
            targetLanguage: request.targetLanguage,
            mode: request.mode,
            prompt: prompt,
            model: model,
            parameters: parameters
        )

        // 首批只放 5 段 / 1800 字符，优先降低首段译文出现时间。
        let firstResult = try await Self.performBatch(client: client, request: firstRequest, source: firstBatch)
        try Task.checkCancellation()
        Self.merge(firstResult, into: &translatedByHash)
        record = Self.makeRecord(
            request: request,
            model: model,
            documentHash: documentHash,
            translatedByHash: translatedByHash,
            isComplete: translatedByHash.count == uniqueSources.count
        )
        try await persistAndPublish(
            record,
            request: request,
            sourceSegments: request.sourceSegments,
            completedCount: translatedByHash.count,
            totalCount: uniqueSources.count,
            onBatch: onBatch
        )

        let remainingBatches = Array(batches.dropFirst())
        if !remainingBatches.isEmpty {
            let aiRequests = try remainingBatches.map {
                try Self.makeAIRequest(
                    batch: $0,
                    targetLanguage: request.targetLanguage,
                    mode: request.mode,
                    prompt: prompt,
                    model: model,
                    parameters: parameters
                )
            }

            // 固定 4 路并发：一个任务完成后才补下一个，避免长 README 一次性创建几十个请求。
            try await withThrowingTaskGroup(of: [ReadmeTranslatedSegment].self) { group in
                let initialCount = min(Self.maxConcurrentBatchCount, remainingBatches.count)
                for index in 0..<initialCount {
                    let batch = remainingBatches[index]
                    let aiRequest = aiRequests[index]
                    group.addTask {
                        try await Self.performBatch(client: client, request: aiRequest, source: batch)
                    }
                }

                var nextIndex = initialCount
                while let result = try await group.next() {
                    try Task.checkCancellation()
                    Self.merge(result, into: &translatedByHash)
                    record = Self.makeRecord(
                        request: request,
                        model: model,
                        documentHash: documentHash,
                        translatedByHash: translatedByHash,
                        isComplete: translatedByHash.count == uniqueSources.count
                    )
                    try await persistAndPublish(
                        record,
                        request: request,
                        sourceSegments: request.sourceSegments,
                        completedCount: translatedByHash.count,
                        totalCount: uniqueSources.count,
                        onBatch: onBatch
                    )

                    if nextIndex < remainingBatches.count {
                        let batch = remainingBatches[nextIndex]
                        let aiRequest = aiRequests[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            try await Self.performBatch(client: client, request: aiRequest, source: batch)
                        }
                    }
                }
            }
        }

        return record
    }

    // MARK: - 缓存与批处理

    private func persistAndPublish(
        _ record: ReadmeTranslation,
        request: ReadmeTranslationRequest,
        sourceSegments: [ReadmeSourceSegment],
        completedCount: Int,
        totalCount: Int,
        onBatch: BatchProgressHandler?
    ) async throws {
        try await translationRepository.upsert(
            record,
            owner: request.repo.owner,
            repo: request.repo.name,
            mode: request.mode
        )
        onBatch?(
            renderedTranslations(from: record, matching: sourceSegments),
            completedCount,
            totalCount
        )
    }

    private nonisolated static func uniqueSegments(
        _ segments: [ReadmeSourceSegment]
    ) -> [ReadmeSourceSegment] {
        var seen = Set<String>()
        return segments.filter { seen.insert($0.sourceHash).inserted }
    }

    /// 首批更小，后续批次略大；两者都同时受段落数和字符预算限制。
    nonisolated static func makeBatches(
        _ segments: [ReadmeSourceSegment]
    ) -> [[ReadmeSourceSegment]] {
        guard !segments.isEmpty else { return [] }
        var remaining = segments[...]
        var result: [[ReadmeSourceSegment]] = []

        let first = takeBatch(from: &remaining, maxCount: 5, maxCharacters: 1_800)
        result.append(first)
        while !remaining.isEmpty {
            result.append(takeBatch(from: &remaining, maxCount: 10, maxCharacters: 3_500))
        }
        return result
    }

    private nonisolated static func takeBatch(
        from remaining: inout ArraySlice<ReadmeSourceSegment>,
        maxCount: Int,
        maxCharacters: Int
    ) -> [ReadmeSourceSegment] {
        var batch: [ReadmeSourceSegment] = []
        var characters = 0
        while let next = remaining.first, batch.count < maxCount {
            if !batch.isEmpty, characters + next.text.count > maxCharacters { break }
            batch.append(next)
            characters += next.text.count
            remaining = remaining.dropFirst()
        }
        return batch
    }

    private nonisolated static func merge(
        _ segments: [ReadmeTranslatedSegment],
        into translatedByHash: inout [String: String]
    ) {
        for segment in segments {
            translatedByHash[segment.sourceHash] = segment.translatedText
        }
    }

    private nonisolated static func makeRecord(
        request: ReadmeTranslationRequest,
        model: String,
        documentHash: String,
        translatedByHash: [String: String],
        isComplete: Bool
    ) -> ReadmeTranslation {
        let segments = translatedByHash
            .map { ReadmeTranslatedSegment(sourceHash: $0.key, translatedText: $0.value) }
            .sorted { $0.sourceHash < $1.sourceHash }
        return ReadmeTranslation(
            repoId: request.repo.id,
            targetLanguage: request.targetLanguage.rawValue,
            model: model,
            sourceHash: documentHash,
            segments: segments,
            isComplete: isComplete,
            size: segments.reduce(0) { $0 + $1.translatedText.utf8.count },
            createdAt: ISO8601DateFormatter.shared.string(from: Date())
        )
    }

    // MARK: - AI 调用

    private func makeClient(
        task: AIModelTaskConfiguration,
        fallbackModel: String
    ) throws -> (any AIClientProtocol, String) {
        guard let profile = settings.aiProviderProfiles.first(where: { $0.id == task.providerID }) else {
            throw ReadmeTranslationError.missingProvider
        }
        let apiKey = (try? keychain.loadAIKey(forProvider: profile.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || profile.provider.allowsEmptyAPIKey else {
            throw ReadmeTranslationError.missingAPIKey
        }
        let model = resolvedModelName(task: task, fallback: fallbackModel)
        let client = try OpenAIClient(configuration: AIClientConfiguration(
            providerID: profile.id,
            provider: profile.provider,
            apiKey: apiKey,
            baseURL: profile.baseURL,
            chatModel: model,
            embeddingModel: settings.aiEmbeddingTask.resolvedModelName,
            timeoutInterval: settings.effectiveParameters(for: task).timeoutSeconds
        ))
        return (client, model)
    }

    private func resolvedModelName(task: AIModelTaskConfiguration, fallback: String) -> String {
        let candidate = task.resolvedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? fallback : candidate
    }

    private nonisolated static func makeAIRequest(
        batch: [ReadmeSourceSegment],
        targetLanguage: ReadmeTranslationLanguage,
        mode: ReadmeTranslationMode,
        prompt: AIPromptConfiguration,
        model: String,
        parameters: AIModelParameters
    ) throws -> AIChatRequest {
        let payload = TranslationBatchInput(
            segments: batch.map { .init(id: $0.id, text: $0.text) }
        )
        let data = try JSONEncoder().encode(payload)
        let json = String(decoding: data, as: UTF8.self)
        var batchParameters = parameters
        // 整页时代的 128K 输出上限会被部分 Provider 当成长生成请求处理。单批最多
        // 3500 字符，8K 已覆盖中英长度膨胀并显著缩小服务端预留；流式 JSON 也没有
        // 可消费的中间态，所以固定走非流式。
        batchParameters.maxCompletionTokens = min(max(parameters.maxCompletionTokens, 512), 8 * 1_024)
        batchParameters.streamEnabled = false
        return AIChatRequest(
            systemPrompt: renderTemplate(
                prompt.systemPrompt,
                targetLanguage: targetLanguage,
                sourceSegmentsJSON: json
            ),
            userPrompt: renderTemplate(
                prompt.userPromptTemplate,
                targetLanguage: targetLanguage,
                sourceSegmentsJSON: json
            ),
            history: [],
            model: model,
            parameters: batchParameters,
            responseFormat: .jsonObject,
            usageContext: AIUsageContext(
                feature: .readmeTranslation,
                phase: mode.usagePhase
            )
        )
    }

    nonisolated static func performBatch(
        client: any AIClientProtocol,
        request: AIChatRequest,
        source: [ReadmeSourceSegment]
    ) async throws -> [ReadmeTranslatedSegment] {
        var currentRequest = request
        for attempt in 0...1 {
            let response = try await client.chat(request: currentRequest)
            try Task.checkCancellation()
            if let result = decodeBatchResponse(response.content, source: source) {
                return result
            }

            guard attempt == 0 else {
                throw ReadmeTranslationError.structureBroken
            }

            // 只重试当前失败批次，已完成批次仍由上层缓存复用。补一条纠错指令，
            // 避免低温度模型原样重复第一次的非 JSON 输出。
            AppLog.ai.warning(
                "README translation batch returned invalid structure; retrying once sourceCount=\(source.count, privacy: .public) responseChars=\(response.content.count, privacy: .public)"
            )
            currentRequest.userPrompt += """

            Your previous response could not be parsed. Return only the required JSON object, with exactly one non-empty translation for every input id.
            """
        }

        throw ReadmeTranslationError.structureBroken
    }

    /// 从模型正文中提取并校验一个批次。
    ///
    /// 部分兼容服务即使收到 `response_format=json_object`，仍可能包一层 Markdown fence、
    /// `<think>` 或简短说明。这里允许从外围文本中提取 JSON，但最终仍要求数量、id、
    /// 唯一性和非空译文全部严格匹配，不能把错位翻译注入 README。
    nonisolated static func decodeBatchResponse(
        _ content: String,
        source: [ReadmeSourceSegment]
    ) -> [ReadmeTranslatedSegment]? {
        let cleaned = stripFenceWrapping(
            content.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var candidates = [cleaned]
        candidates.append(contentsOf: jsonObjectCandidates(in: cleaned))

        var visited = Set<String>()
        for candidate in candidates where visited.insert(candidate).inserted {
            guard let data = candidate.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(TranslationBatchOutput.self, from: data),
                  let result = validatedTranslations(decoded, source: source)
            else { continue }
            return result
        }
        return nil
    }

    private nonisolated static func validatedTranslations(
        _ decoded: TranslationBatchOutput,
        source: [ReadmeSourceSegment]
    ) -> [ReadmeTranslatedSegment]? {
        let expectedIDs = Set(source.map(\.id))
        guard expectedIDs.count == source.count,
              decoded.translations.count == source.count
        else { return nil }

        let sourceByID = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        var seen = Set<String>()
        var result: [ReadmeTranslatedSegment] = []
        for item in decoded.translations {
            guard seen.insert(item.id).inserted,
                  let original = sourceByID[item.id]
            else { return nil }

            let text = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            result.append(
                ReadmeTranslatedSegment(
                    sourceHash: original.sourceHash,
                    translatedText: text
                )
            )
        }
        guard seen == expectedIDs else { return nil }
        return result
    }

    /// 扫描外围文本中的完整顶层 JSON object；字符串内部的花括号不参与层级计算。
    private nonisolated static func jsonObjectCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        var start: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for index in text.indices {
            let character = text[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let candidateStart = start {
                    candidates.append(String(text[candidateStart...index]))
                    start = nil
                }
            }
        }
        return candidates
    }

    // MARK: - Prompt

    nonisolated static let targetLanguagePlaceholder = "{targetLanguage}"
    nonisolated static let readmeSegmentsPlaceholder = "{readmeSegments}"
    nonisolated static let readmeTextNodesPlaceholder = "{readmeTextNodes}"
    /// 自定义旧 Prompt 的数据安全兼容：仍替换旧占位符，但注入内容已经是段落 JSON。
    nonisolated static let legacyReadmeHTMLPlaceholder = "{readmeHTML}"

    nonisolated static func renderTemplate(
        _ template: String,
        targetLanguage: ReadmeTranslationLanguage,
        sourceSegmentsJSON: String
    ) -> String {
        template
            .replacingOccurrences(of: targetLanguagePlaceholder, with: targetLanguage.promptName)
            .replacingOccurrences(of: readmeSegmentsPlaceholder, with: sourceSegmentsJSON)
            .replacingOccurrences(of: readmeTextNodesPlaceholder, with: sourceSegmentsJSON)
            .replacingOccurrences(of: legacyReadmeHTMLPlaceholder, with: sourceSegmentsJSON)
    }

    nonisolated static func effectivePromptConfiguration(
        _ prompt: AIPromptConfiguration,
        mode: ReadmeTranslationMode = .segmented
    ) -> AIPromptConfiguration {
        let trimmedSystem = prompt.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = prompt.userPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSystem.isEmpty || trimmedUser.isEmpty {
            return mode == .segmented
                ? AIDefaultPrompts.translation
                : AIDefaultPrompts.fullTranslation
        }
        if prompt == AIDefaultPrompts.legacyTranslationHTMLV1 {
            return mode == .segmented
                ? AIDefaultPrompts.translation
                : AIDefaultPrompts.fullTranslation
        }
        return prompt
    }

    nonisolated static func stripFenceWrapping(_ text: String) -> String {
        var result = text
        if result.lowercased().hasPrefix("```") {
            if let firstNewline = result.firstIndex(of: "\n") {
                result.removeSubrange(result.startIndex...firstNewline)
            } else {
                result.removeSubrange(result.startIndex..<result.index(result.startIndex, offsetBy: 3))
            }
        }
        if result.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("```"),
           let range = result.range(of: "```", options: [.backwards]) {
            result.removeSubrange(range.lowerBound..<result.endIndex)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct TranslationBatchInput: Codable, Sendable {
    struct Segment: Codable, Sendable {
        let id: String
        let text: String
    }

    let segments: [Segment]
}

private struct TranslationBatchOutput: Codable, Sendable {
    struct Item: Codable, Sendable {
        let id: String
        let translation: String
    }

    let translations: [Item]
}
