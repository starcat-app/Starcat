//
//  BatchAIInsightProviding.swift
//  Starcat
//
//  批量 AI 队列与单仓洞察服务之间的窄依赖边界。
//
//  关键约束：
//  - 批量启动必须在创建任何 job 前完成 Provider、API Key 与模型预检；
//  - 批量生成关闭 External Context，避免数千仓库整理隐式放大外部检索流量；
//  - 协议保持 MainActor 隔离，让队列状态与洞察服务遵循同一并发模型，并允许单测
//    注入可控的阻塞实现验证 in-flight 取消传播。
//

import Foundation

@MainActor
protocol BatchAIInsightProviding: AnyObject {
    func ensureGenerationClientsReady(includeSummary: Bool, includeTags: Bool) throws

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool
    ) async throws -> RepoAIInsightGeneration
}

extension RepoAIInsightService: BatchAIInsightProviding {
    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool
    ) async throws -> RepoAIInsightGeneration {
        try await generateInsight(
            for: repo,
            existingTagHints: existingTagHints,
            includeSummary: includeSummary,
            includeTags: includeTags,
            allowExternalContext: false
        )
    }
}
