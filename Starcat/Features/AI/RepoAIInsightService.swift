//
//  RepoAIInsightService.swift
//  Starcat
//
//  单仓 AI 摘要与标签推荐服务。
//
//  模块职责：
//  - 读取 repo 元数据与本地 README 缓存，组装 LLM 上下文；
//  - 使用 BYOK 配置调用 OpenAI-compatible chat model；
//  - 将结构化 AI 输出缓存到 SQLite；
//  - 提供缓存读取与强制重新生成两种路径。
//
//  关键约束：
//  - 不自动触发批量生成；只有用户在详情页点击生成 / 重新生成才调用 chat。
//  - 不自动写标签；标签推荐只进入 UI 确认流。
//  - Prompt 要求返回严格 JSON，解析失败直接报错，避免把不可预测文本塞进 UI。
//

import CryptoKit
import Foundation

enum RepoAIInsightError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先在 Settings → AI 填写 API Key，再生成 AI 摘要。"
        case .invalidJSON:
            return "AI 返回内容不是可解析的结构化 JSON。"
        }
    }
}

@MainActor
final class RepoAIInsightService {

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
        guard let record = try await summaryRepository.find(repoId: repo.id, model: settings.aiChatModel),
              record.sourceHash == source.hash
        else {
            return nil
        }
        return try Self.decodeInsight(json: record.summaryJson)
    }

    func generateInsight(for repo: Repo) async throws -> RepoAIInsight {
        let source = try await makeSource(for: repo)
        let client = try makeClient()
        let model = settings.aiChatModel
        let generatedAt = ISO8601DateFormatter.shared.string(from: Date())
        let response = try await client.chat(
            systemPrompt: Self.systemPrompt,
            userPrompt: Self.userPrompt(repo: repo, sourceText: source.text),
            model: model
        )
        var insight = try Self.decodeInsight(json: response)
        insight.model = model
        insight.generatedAt = generatedAt

        let jsonData = try JSONEncoder().encode(insight)
        let record = AISummaryRecord(
            repoId: repo.id,
            model: model,
            sourceHash: source.hash,
            summaryJson: String(decoding: jsonData, as: UTF8.self),
            generatedAt: generatedAt
        )
        try await summaryRepository.upsert(record)
        return insight
    }

    private func makeClient() throws -> any AIClientProtocol {
        guard let apiKey = try keychain.loadAIKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            throw RepoAIInsightError.missingAPIKey
        }

        return try OpenAIClient(configuration: AIClientConfiguration(
            apiKey: apiKey,
            baseURL: settings.aiBaseURL,
            chatModel: settings.aiChatModel,
            embeddingModel: settings.aiEmbeddingModel
        ))
    }

    private func makeSource(for repo: Repo) async throws -> (text: String, hash: String) {
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
        return (source, Self.hash(source))
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

    private static let systemPrompt = """
    You are Starcat's repository analysis assistant. Return strict JSON only.
    Analyze the repository for a developer who manages GitHub stars.
    Do not invent facts not present in the provided metadata or README.
    Suggested tags must be short, reusable, and suitable for a local tag system.
    """

    private static func userPrompt(repo: Repo, sourceText: String) -> String {
        """
        Analyze this GitHub repository and return JSON matching exactly:
        {
          "oneLiner": "中文一句话总结",
          "summary": "中文说明这个项目是什么，控制在 120 字内",
          "platforms": ["平台或生态，如 macOS, Swift, CLI"],
          "suitableFor": ["适合场景 1", "适合场景 2"],
          "strengths": ["优点 1", "优点 2"],
          "risks": ["风险或注意点 1"],
          "minimalExample": "如果 README 中有清晰示例，提炼一个最小示例；没有则为 null",
          "suggestedTags": [
            {"name": "Swift", "confidence": 0.91, "reason": "为什么推荐这个标签"}
          ],
          "model": "",
          "generatedAt": ""
        }

        Rules:
        - Use Simplified Chinese.
        - suggestedTags: 3 to 8 items, confidence between 0 and 1.
        - model and generatedAt must be empty strings; Starcat fills them locally.
        - JSON only, no markdown fences.

        Repository context:
        \(sourceText)
        """
    }
}
