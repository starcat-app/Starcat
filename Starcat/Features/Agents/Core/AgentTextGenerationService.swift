//
//  AgentTextGenerationService.swift
//  Starcat
//
//  Agent Runtime 的文本生成适配层。
//
//  这里复用 Starcat 现有 OpenAI-compatible 客户端和 AI 设置，不引入第二套 SDK。
//  Runtime 只依赖 `AgentTextGenerating`，便于测试用 fake generator 覆盖成功/失败路径。
//

import Foundation

protocol AgentTextGenerating: Sendable {
    func generateWeeklyReport(
        prompt: String,
        context: AgentRunContext,
        draftMarkdown: String
    ) async throws -> String
}

enum AgentTextGenerationError: Error, LocalizedError, Equatable {
    case missingProvider
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingProvider:
            return String.l10n("agent.textGeneration.error.missingProvider")
        case .missingAPIKey:
            return String.l10n("agent.textGeneration.error.missingAPIKey")
        }
    }
}

struct DisabledAgentTextGenerator: AgentTextGenerating {
    func generateWeeklyReport(
        prompt: String,
        context: AgentRunContext,
        draftMarkdown: String
    ) async throws -> String {
        throw AgentTextGenerationError.missingProvider
    }
}

struct OpenAIAgentTextGenerator: AgentTextGenerating {

    private let client: any AIClientProtocol
    private let model: String
    private let parameters: AIModelParameters

    init(
        client: any AIClientProtocol,
        model: String,
        parameters: AIModelParameters
    ) {
        self.client = client
        self.model = model
        self.parameters = parameters
    }

    func generateWeeklyReport(
        prompt: String,
        context: AgentRunContext,
        draftMarkdown: String
    ) async throws -> String {
        let request = AIChatRequest(
            systemPrompt: Self.systemPrompt,
            userPrompt: Self.userPrompt(
                prompt: prompt,
                context: context,
                draftMarkdown: draftMarkdown
            ),
            model: model,
            parameters: parameters,
            responseFormat: .text
        )
        let response = try await client.chat(request: request)
        return response.content
    }

    private static let systemPrompt = """
    You are Starcat's built-in GitHub Weekly Report Agent.
    Generate a concise, auditable Markdown technical weekly report from the provided local Starcat repository snapshot.
    Do not claim that you fetched live GitHub data. Do not invent repositories. Do not include destructive actions.
    Output Simplified Chinese unless the user explicitly asks for another language.
    """

    private static func userPrompt(
        prompt: String,
        context: AgentRunContext,
        draftMarkdown: String
    ) -> String {
        """
        用户目标:
        \(prompt)

        数据来源:
        \(context.sourceDescription)

        仓库快照:
        \(context.repos.map(repoLine).joined(separator: "\n"))

        本地工具生成的结构草稿:
        \(draftMarkdown)

        请基于以上真实快照重写为最终 Markdown 周刊。保留“数据来源”和“只读约束”说明。
        """
    }

    private static func repoLine(_ repo: AgentRepoSnapshot) -> String {
        "- \(repo.fullName) | \(repo.language ?? "Unknown") | \(repo.starsCount) stars | \(repo.description ?? "")"
    }
}

@MainActor
enum AgentTextGeneratorFactory {
    static func make(settings: AppSettings, keychain: any KeychainManaging = KeychainManager.shared) -> any AgentTextGenerating {
        let task = settings.aiChatTask
        guard let profile = settings.aiProviderProfiles.first(where: { $0.id == task.providerID }) else {
            return DisabledAgentTextGenerator()
        }

        let apiKey = (try? keychain.loadAIKey(forProvider: profile.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || profile.provider.allowsEmptyAPIKey else {
            return MissingAPIKeyAgentTextGenerator()
        }

        let model = nonEmpty(task.resolvedModelName) ?? settings.aiChatModel
        let parameters = settings.effectiveParameters(for: task)
        do {
            let client = try OpenAIClient(configuration: AIClientConfiguration(
                providerID: profile.id,
                provider: profile.provider,
                apiKey: apiKey,
                baseURL: profile.baseURL,
                chatModel: model,
                embeddingModel: settings.aiEmbeddingTask.resolvedModelName,
                timeoutInterval: parameters.timeoutSeconds
            ))
            return OpenAIAgentTextGenerator(
                client: client,
                model: model,
                parameters: parameters
            )
        } catch {
            return DisabledAgentTextGenerator()
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct MissingAPIKeyAgentTextGenerator: AgentTextGenerating {
    func generateWeeklyReport(
        prompt: String,
        context: AgentRunContext,
        draftMarkdown: String
    ) async throws -> String {
        throw AgentTextGenerationError.missingAPIKey
    }
}
