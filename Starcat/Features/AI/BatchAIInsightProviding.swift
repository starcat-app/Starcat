//
//  BatchAIInsightProviding.swift
//  Starcat
//
//  批量 AI 队列与单仓洞察服务之间的窄依赖边界。
//
//  关键约束：
//  - 批量启动必须在创建任何 job 前完成 Provider、API Key 与模型预检；
//  - 手动批量入口显式传递本次代码上下文与外部搜索选择；未传覆盖值的后台整理仍关闭
//    External Context，避免数千仓库整理隐式放大外部检索流量；
//  - 协议保持 MainActor 隔离，让队列状态与洞察服务遵循同一并发模型，并允许单测
//    注入可控的阻塞实现验证 in-flight 取消传播。
//

import Foundation

@MainActor
protocol BatchAIInsightProviding: AnyObject {
    func ensureGenerationClientsReady(includeSummary: Bool, includeTags: Bool) throws

    /// 标签专用批量入口。一个请求承载多个仓库，返回值必须包含每个 repo id。
    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints]
    ) async throws -> [Int64: [AITagSuggestion]]

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?
    ) async throws -> RepoAIInsightGeneration
}

extension RepoAIInsightService: BatchAIInsightProviding {
    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints]
    ) async throws -> [Int64: [AITagSuggestion]] {
        try await generateTagSuggestions(
            for: repos,
            tagHintsByRepoID: tagHintsByRepoID
        )
    }

    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?
    ) async throws -> RepoAIInsightGeneration {
        try await generateInsight(
            for: repo,
            existingTagHints: existingTagHints,
            includeSummary: includeSummary,
            includeTags: includeTags,
            // nil 代表自动整理等旧调用方：继续禁止批量外部搜索；手动入口传入明确值后，
            // 再由 RepoAIInsightService 按 Provider 可用性与私有仓库策略逐仓判断。
            allowExternalContext: externalContextEnabledOverride != nil,
            codeContextEnabledOverride: codeContextEnabledOverride,
            externalContextEnabledOverride: externalContextEnabledOverride
        )
    }
}
