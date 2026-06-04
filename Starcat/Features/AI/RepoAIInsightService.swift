//
//  RepoAIInsightService.swift
//  Starcat
//
//  单仓 AI 摘要与标签推荐服务。
//
//  模块职责：
//  - 读取 repo 元数据与本地 README 缓存，组装 LLM 上下文；
//  - 按 Settings 中的任务配置分别调用摘要模型与标签模型；
//  - 摘要优先使用流式响应，标签保持 JSON 解析；
//  - 将最终可展示结果缓存到 SQLite。
//
//  关键约束：
//  - 不自动触发批量生成；只有用户在详情页点击生成 / 重新生成才调用 chat。
//  - 不自动写标签；标签推荐只进入 UI 确认流。
//  - 摘要和标签是两个独立 AI 任务。标签 JSON 失败不应让已生成的摘要文本丢失。
//

import CryptoKit
import Foundation

enum RepoAIInsightError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case missingProvider(String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先在 Settings → AI 配置对应 Provider 的 API Key，再生成 AI 摘要。"
        case .missingProvider(let task):
            return "AI 任务 \(task) 没有可用的 Provider 配置。"
        case .invalidJSON:
            return "AI 返回内容不是可解析的结构化 JSON。"
        }
    }
}

struct RepoAIInsightGeneration: Equatable, Sendable {
    var insight: RepoAIInsight
    var tagErrorMessage: String?
}

@MainActor
final class RepoAIInsightService {

    private struct Source {
        let text: String
        let hash: String
    }

    private let summaryRepository: any AISummaryRepositoryProtocol
    private let readmeRepository: ReadmeRepository
    private let settings: AppSettings
    private let keychain: any KeychainManaging

    init(
        summaryRepository: any AISummaryRepositoryProtocol,
        readmeRepository: ReadmeRepository,
        settings: AppSettings,
        keychain: any KeychainManaging = KeychainManager.shared
    ) {
        self.summaryRepository = summaryRepository
        self.readmeRepository = readmeRepository
        self.settings = settings
        self.keychain = keychain
    }

    func cachedInsight(for repo: Repo) async throws -> RepoAIInsight? {
        let source = try await makeSource(for: repo)
        guard let record = try await summaryRepository.find(repoId: repo.id, model: cacheModelKey()),
              record.sourceHash == source.hash
        else {
            return nil
        }
        return try Self.decodeInsight(json: record.summaryJson)
    }

    func generateInsight(
        for repo: Repo,
        onSummaryDelta: (@MainActor (String) -> Void)? = nil
    ) async throws -> RepoAIInsightGeneration {
        let source = try await makeSource(for: repo)
        let generatedAt = ISO8601DateFormatter.shared.string(from: Date())

        async let tagResult = tagSuggestionsResult(source: source)
        let summaryText = try await generateSummary(source: source, onDelta: onSummaryDelta)
        let resolvedTagResult = await tagResult
        let suggestions = (try? resolvedTagResult.get()) ?? []
        let tagErrorMessage: String? = {
            if case .failure(let error) = resolvedTagResult {
                return error.localizedDescription
            }
            return nil
        }()

        let summaryModel = settings.aiSummaryTask.resolvedModelName.nilIfBlank ?? settings.aiChatModel
        var insight = Self.makeInsight(
            summaryText: summaryText,
            tags: suggestions,
            model: summaryModel,
            generatedAt: generatedAt
        )

        // 保留旧字段的同时把新摘要正文写进 summaryMarkdown，UI 优先读该字段。
        insight.summaryMarkdown = summaryText

        let jsonData = try JSONEncoder().encode(insight)
        let record = AISummaryRecord(
            repoId: repo.id,
            model: cacheModelKey(),
            sourceHash: source.hash,
            summaryJson: String(decoding: jsonData, as: UTF8.self),
            generatedAt: generatedAt
        )
        try await summaryRepository.upsert(record)
        return RepoAIInsightGeneration(insight: insight, tagErrorMessage: tagErrorMessage)
    }

    private func tagSuggestionsResult(source: Source) async -> Result<[AITagSuggestion], Error> {
        do {
            return .success(try await generateTags(source: source))
        } catch {
            AppLog.ai.error("AI tag generation failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    private func generateSummary(
        source: Source,
        onDelta: (@MainActor (String) -> Void)?
    ) async throws -> String {
        let task = settings.aiSummaryTask
        let (client, model) = try makeClient(task: task, fallbackModel: settings.aiChatModel, taskName: "摘要")
        let request = AIChatRequest(
            systemPrompt: task.prompt.systemPrompt,
            userPrompt: task.prompt.renderedUserPrompt(context: source.text),
            model: model,
            parameters: task.parameters,
            responseFormat: .text
        )

        if task.parameters.streamEnabled {
            var accumulated = ""
            for try await event in client.chatStream(request: request) {
                switch event {
                case .delta(let delta):
                    accumulated += delta
                    onDelta?(accumulated)
                case .completed(let response):
                    return response.content
                }
            }
            guard let final = accumulated.nilIfBlank else { throw AIClientError.emptyResponse }
            return final
        } else {
            let response = try await client.chat(request: request)
            return response.content
        }
    }

    private func generateTags(source: Source) async throws -> [AITagSuggestion] {
        let task = settings.aiTagsTask
        let (client, model) = try makeClient(task: task, fallbackModel: settings.aiChatModel, taskName: "推荐标签")
        let response = try await client.chat(request: AIChatRequest(
            systemPrompt: task.prompt.systemPrompt,
            userPrompt: task.prompt.renderedUserPrompt(context: source.text),
            model: model,
            parameters: task.parameters,
            responseFormat: .jsonObject
        ))
        return try Self.decodeTagSuggestions(json: response.content)
    }

    private func makeClient(
        task: AIModelTaskConfiguration,
        fallbackModel: String,
        taskName: String
    ) throws -> (any AIClientProtocol, String) {
        guard let profile = settings.aiProviderProfiles.first(where: { $0.id == task.providerID }) else {
            throw RepoAIInsightError.missingProvider(taskName)
        }
        let apiKey = try keychain.loadAIKey(forProvider: profile.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || profile.provider.allowsEmptyAPIKey else {
            throw RepoAIInsightError.missingAPIKey
        }
        let model = task.resolvedModelName.nilIfBlank ?? fallbackModel

        return (try OpenAIClient(configuration: AIClientConfiguration(
            providerID: profile.id,
            provider: profile.provider,
            apiKey: apiKey,
            baseURL: profile.baseURL,
            chatModel: model,
            embeddingModel: settings.aiEmbeddingTask.resolvedModelName,
            timeoutInterval: task.parameters.timeoutSeconds
        )), model)
    }

    private func cacheModelKey() -> String {
        let summaryModel = settings.aiSummaryTask.resolvedModelName.nilIfBlank ?? settings.aiChatModel
        let tagsModel = settings.aiTagsTask.resolvedModelName.nilIfBlank ?? settings.aiChatModel
        return "summary:\(settings.aiSummaryTask.providerID)/\(summaryModel)|tags:\(settings.aiTagsTask.providerID)/\(tagsModel)"
    }

    private func makeSource(for repo: Repo) async throws -> Source {
        let readme = try await readmeRepository.find(repoId: repo.id)
        let readmeText = Self.stripHTML(readme?.renderedHtml ?? readme?.content ?? "")
        let source = [
            "Repository: \(repo.fullName)",
            "Description: \(repo.description ?? "")",
            "Language: \(repo.language ?? "")",
            "Topics: \(repo.topics ?? "")",
            "License: \(repo.license ?? "")",
            "Stars: \(repo.starsCount)",
            "Forks: \(repo.forksCount)",
            "Homepage: \(repo.homepage ?? "")",
            "README:",
            String(readmeText.prefix(12_000))
        ].joined(separator: "\n")
        return Source(text: source, hash: Self.hash(source))
    }

    nonisolated static func decodeInsight(json raw: String) throws -> RepoAIInsight {
        let json = extractJSONObject(from: raw)
        guard let data = json.data(using: .utf8) else { throw RepoAIInsightError.invalidJSON }
        do {
            return try JSONDecoder().decode(RepoAIInsight.self, from: data)
        } catch {
            throw RepoAIInsightError.invalidJSON
        }
    }

    nonisolated static func decodeTagSuggestions(json raw: String) throws -> [AITagSuggestion] {
        let json = extractJSONObject(from: raw)
        guard let data = json.data(using: .utf8) else { throw RepoAIInsightError.invalidJSON }
        do {
            if let envelope = try? JSONDecoder().decode(AITagSuggestionEnvelope.self, from: data) {
                return envelope.suggestedTags
            }
            return try JSONDecoder().decode([AITagSuggestion].self, from: data)
        } catch {
            throw RepoAIInsightError.invalidJSON
        }
    }

    private nonisolated static func makeInsight(
        summaryText: String,
        tags: [AITagSuggestion],
        model: String,
        generatedAt: String
    ) -> RepoAIInsight {
        let normalized = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = firstMeaningfulMarkdownLine(from: normalized) ?? String(normalized.prefix(80))
        return RepoAIInsight(
            oneLiner: firstLine,
            summary: normalized,
            summaryMarkdown: normalized,
            platforms: [],
            suitableFor: [],
            strengths: [],
            risks: [],
            minimalExample: nil,
            suggestedTags: tags,
            model: model,
            generatedAt: generatedAt
        )
    }

    /// 从 Markdown 摘要中提取缓存用的一句话。
    ///
    /// 默认 Prompt 会把第一行写成 `## 一句话总结`，如果直接取首行会让缓存旧字段失去意义。
    /// 这里跳过标题、列表符号和代码围栏，取第一段真正正文，供旧 UI / 旧缓存字段兼容。
    private nonisolated static func firstMeaningfulMarkdownLine(from markdown: String) -> String? {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                !line.isEmpty
                    && !line.hasPrefix("#")
                    && !line.hasPrefix("```")
                    && line != "---"
            }
    }

    private nonisolated static func extractJSONObject(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end
        else {
            return trimmed
        }
        return String(trimmed[start...end])
    }

    private nonisolated static func stripHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct AITagSuggestionEnvelope: Codable {
    var suggestedTags: [AITagSuggestion]
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
