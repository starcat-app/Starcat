//
//  SemanticSearchService.swift
//  Starcat
//
//  AI 语义搜索服务。
//
//  模块职责：
//  - 将 Repo 元数据转换为稳定的索引文本；
//  - 使用 BYOK 配置调用 OpenAI-compatible embeddings；
//  - 把 repo embedding 缓存在 SQLite，并用 cosine similarity 排名。
//
//  关键约束：
//  - 当前 MVP 使用 SQLite BLOB + Swift cosine，不依赖 sqlite-vss/vec 动态扩展。
//    这是为了规避 macOS 沙盒分发、签名和 extension 加载路径风险。
//  - 搜索只生成查询向量；repo 向量缺失或过期时批量补索引。
//  - AI 只参与语义排序，不自动修改用户标签、笔记或状态。
//

import CryptoKit
import Foundation

struct SemanticSearchHit: Equatable, Sendable {
    let repo: Repo
    let score: Double
    let reason: String
}

enum SemanticSearchError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case noVectors

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先在 Settings → AI 填写 API Key，再使用 AI 语义搜索。"
        case .noVectors:
            return "没有可用的语义索引。"
        }
    }
}

@MainActor
final class SemanticSearchService {

    private let embeddingRepository: any RepoEmbeddingRepositoryProtocol
    private let settings: AppSettings
    private let keychain: any KeychainManaging
    private let batchSize: Int

    init(
        embeddingRepository: any RepoEmbeddingRepositoryProtocol,
        settings: AppSettings,
        keychain: any KeychainManaging = KeychainManager.shared,
        batchSize: Int = 32
    ) {
        self.embeddingRepository = embeddingRepository
        self.settings = settings
        self.keychain = keychain
        self.batchSize = batchSize
    }

    /// 对传入候选 repo 做语义搜索。
    ///
    /// 候选集由 HomeViewModel 决定：当前实现对全量 starred repos 搜索，再叠加列表过滤。
    /// 这样与原 FTS 搜索保持“全局搜索”语义一致，而不是只在当前 sidebar 分类内搜。
    func search(query: String, candidates: [Repo], limit: Int = 80) async throws -> [SemanticSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard !candidates.isEmpty else { return [] }

        let (client, model) = try makeClient(task: settings.aiEmbeddingTask)
        try await ensureIndexed(candidates, model: model, client: client)

        let stored = try await embeddingRepository.fetchEmbeddingsByRepoID(
            model: model,
            repoIDs: candidates.map(\.id)
        )
        guard !stored.isEmpty else { throw SemanticSearchError.noVectors }

        let queryVector = try await client.embedding(input: trimmed, model: model)
        let hits = candidates.compactMap { repo -> SemanticSearchHit? in
            guard let row = stored[repo.id] else { return nil }
            let vector = row.vector
            guard !vector.isEmpty, vector.count == queryVector.count else { return nil }
            let score = Self.cosineSimilarity(queryVector, vector)
            guard score.isFinite else { return nil }
            return SemanticSearchHit(
                repo: repo,
                score: score,
                reason: Self.reason(for: repo, query: trimmed, score: score)
            )
        }

        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// 手动刷新语义索引。
    ///
    /// UI 工具栏按钮会调用这里；搜索时也会自动补缺失索引。
    func refreshIndex(for repos: [Repo]) async throws {
        guard !repos.isEmpty else { return }
        let (client, model) = try makeClient(task: settings.aiEmbeddingTask)
        try await ensureIndexed(repos, model: model, client: client, force: true)
    }

    private func makeClient(task: AIModelTaskConfiguration) throws -> (any AIClientProtocol, String) {
        guard let profile = settings.aiProviderProfiles.first(where: { $0.id == task.providerID }) else {
            throw SemanticSearchError.missingAPIKey
        }
        let apiKey = try keychain.loadAIKey(forProvider: profile.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || profile.provider.allowsEmptyAPIKey else {
            throw SemanticSearchError.missingAPIKey
        }
        let model = task.resolvedModelName.nilIfBlank ?? settings.aiEmbeddingModel

        return (try OpenAIClient(configuration: AIClientConfiguration(
            providerID: profile.id,
            provider: profile.provider,
            apiKey: apiKey,
            baseURL: profile.baseURL,
            chatModel: settings.aiSummaryTask.resolvedModelName,
            embeddingModel: model,
            timeoutInterval: settings.effectiveParameters(for: task).timeoutSeconds
        )), model)
    }

    private func ensureIndexed(
        _ repos: [Repo],
        model: String,
        client: any AIClientProtocol,
        force: Bool = false
    ) async throws {
        let records = repos.map { SemanticIndexRecord(repo: $0) }
        let existing = try await embeddingRepository.fetchEmbeddingsByRepoID(
            model: model,
            repoIDs: records.map(\.repo.id)
        )
        let missingOrStale = records.filter { record in
            guard !force, let current = existing[record.repo.id] else { return true }
            return current.contentHash != record.contentHash
        }
        guard !missingOrStale.isEmpty else { return }

        for chunk in missingOrStale.chunked(into: batchSize) {
            let vectors = try await client.embeddings(inputs: chunk.map(\.indexedText), model: model)
            let now = ISO8601DateFormatter.shared.string(from: Date())
            let rows = zip(chunk, vectors).map { record, vector in
                RepoEmbedding(
                    repoId: record.repo.id,
                    model: model,
                    contentHash: record.contentHash,
                    vector: vector,
                    indexedText: record.indexedText,
                    updatedAt: now
                )
            }
            try await embeddingRepository.upsert(rows)
        }
    }

    /// Cosine similarity 纯函数，单测可直接覆盖。
    nonisolated static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .nan }
        var dot: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for (lhs, rhs) in zip(a, b) {
            let x = Double(lhs)
            let y = Double(rhs)
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return .nan }
        return dot / (sqrt(normA) * sqrt(normB))
    }

    private static func reason(for repo: Repo, query: String, score: Double) -> String {
        let scoreText = "\(Int((max(0, min(score, 1)) * 100).rounded()))%"
        let lowerQuery = query.localizedLowercase
        if repo.fullName.localizedLowercase.contains(lowerQuery) {
            return "仓库名直接相关，语义相似度 \(scoreText)"
        }
        if let description = repo.description, description.localizedLowercase.contains(lowerQuery) {
            return "描述包含相关概念，语义相似度 \(scoreText)"
        }
        if let topics = repo.topics, topics.localizedLowercase.contains(lowerQuery) {
            return "Topics 命中相关方向，语义相似度 \(scoreText)"
        }
        return "AI 向量相似度 \(scoreText)"
    }
}

private struct SemanticIndexRecord {
    let repo: Repo
    let indexedText: String
    let contentHash: String

    init(repo: Repo) {
        self.repo = repo
        self.indexedText = Self.makeIndexedText(from: repo)
        self.contentHash = Self.hash(indexedText)
    }

    private static func makeIndexedText(from repo: Repo) -> String {
        [
            "Repository: \(repo.fullName)",
            "Owner: \(repo.owner)",
            "Name: \(repo.name)",
            "Description: \(repo.description ?? "")",
            "Language: \(repo.language ?? "")",
            "Topics: \(repo.topics ?? "")",
            "License: \(repo.license ?? "")",
            "Homepage: \(repo.homepage ?? "")",
            "Stars: \(repo.starsCount)",
            "Forks: \(repo.forksCount)"
        ]
        .joined(separator: "\n")
    }

    private static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
