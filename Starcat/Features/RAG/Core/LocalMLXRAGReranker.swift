//
//  LocalMLXRAGReranker.swift
//  Starcat
//
//  知识库 RAG 的本地重排序：进程内 MLX 加载 Qwen3-Reranker，不发起任何网络请求。
//
//  定位：`RAGReranking` 的第三个实现（前两个是 TEI / Cohere 远程 HTTP）。遵循既有
//  RAG 检索配置语义——`RAGRerankConfiguration.isEnabled` 默认关闭，用户在检索设置里
//  显式开启；模型未下载时抛 `LocalAIError.modelNotInstalled`，由检索管线把错误上抛。
//
//  关键约束：
//  - 候选截断、文档拼装、下标映射与评分校验复用 TEI/Cohere 的同一候选快照，
//    本地异常评分也必须上抛，不能让界面误报重排成功。
//  - Qwen3-Reranker 是判别式 causal 打分（yes/no logits → normalizedRelevance 0...1），
//    mlx-swift-lm 的 `RerankerContainer` 已封装该协议；score 直接可用，无需归一化。
//

import Foundation
import MLXLMCommon

struct LocalMLXRAGReranker: RAGReranking {

    let provider: RAGRerankProvider = .localMLX

    private let configuration: RAGRerankConfiguration
    private let runtime: LocalMLXRuntime
    private let model: LocalAIModelCatalogEntry

    var debugCandidateLimit: Int? { configuration.candidateLimit }
    /// Debug Trace 记录本次选择的模型；安装状态在调用时校验，不静默回退其它权重。
    var debugModel: String? {
        model.displayName
    }

    init(
        configuration: RAGRerankConfiguration,
        model: LocalAIModelCatalogEntry,
        runtime: LocalMLXRuntime = .shared
    ) {
        self.configuration = configuration.normalized
        self.runtime = runtime
        self.model = model
    }

    /// Qwen3-Reranker 官方建议指令：与 query 一起进 prompt 提升判别质量。
    private static let instruction =
        "Given a user query, retrieve relevant repository passages that answer the query."

    func rerank(
        query: String, candidates: [RAGChildHit]
    ) async throws -> [(hit: RAGChildHit, score: Double)] {
        let directory = LocalAIModelStorage.installedDirectoryURL(entryID: model.id)
        let context = LocalAILogContext(modelName: model.displayName, feature: "rerank", directory: directory)
        return try await LocalAILogContext.$current.withValue(context) {
            let start = ProcessInfo.processInfo.systemUptime
            LocalAILog.record("request.received", "Rerank request received.", fields: ["candidates": String(candidates.count)])
            do {
                let result = try await performRerank(query: query, candidates: candidates, directory: directory)
                LocalAILog.record("request.completed", "Rerank request completed.", fields: [
                    "results": String(result.count),
                    "durationSeconds": LocalAILogEvent.seconds(ProcessInfo.processInfo.systemUptime - start)
                ])
                return result
            } catch {
                LocalAILog.record("request.failed", "Rerank request ended without a result.",
                                  level: error is CancellationError ? .info : .error, fields: LocalAILogEvent.errorFields(error))
                throw error
            }
        }
    }

    /// 只记录候选数量和耗时，query/候选正文不进入运行日志。
    private func performRerank(
        query: String, candidates: [RAGChildHit], directory: URL?
    ) async throws -> [(hit: RAGChildHit, score: Double)] {
        let snapshot = RAGRerankCandidateSnapshot(candidates: candidates, limit: configuration.candidateLimit)
        guard !snapshot.hits.isEmpty else { return [] }

        guard let directory else {
            throw LocalAIError.modelNotInstalled(model.displayName)
        }

        // score 类型由 config.json 决定（Qwen3 判别式 → normalizedRelevance 0...1）。
        let response = try await runtime.withReranker(directory: directory) { container in
            try await container.scores(
                query: query,
                documents: snapshot.documents,
                instruction: Self.instruction,
                options: RerankExecutionOptions(maxBatchSize: 1, maxBatchTokens: 2_048))
        }

        return try snapshot.applying(
            response.results.map { RAGRerankIndexedScore(index: $0.index, score: $0.score) },
            backend: model.displayName
        )
    }
}
