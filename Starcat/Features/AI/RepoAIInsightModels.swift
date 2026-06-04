//
//  RepoAIInsightModels.swift
//  Starcat
//
//  单仓 AI 智能化领域模型。
//
//  模块职责：
//  - 定义详情页 AI 摘要需要展示的结构化内容；
//  - 定义 AI 标签推荐的确认单元；
//  - 作为 AI 输出 JSON 与 SwiftUI UI 之间的稳定边界。
//
//  关键约束：
//  - 字段保持小而稳定，避免第一版 prompt 输出过宽导致解析脆弱。
//  - 推荐标签只是建议，不能因为模型返回就自动落库。
//

import Foundation

struct RepoAIInsight: Codable, Equatable, Sendable {
    var oneLiner: String
    var summary: String
    var summaryMarkdown: String?
    var platforms: [String]
    var suitableFor: [String]
    var strengths: [String]
    var risks: [String]
    var minimalExample: String?
    var suggestedTags: [AITagSuggestion]
    var model: String
    var generatedAt: String
}

struct AITagSuggestion: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var confidence: Double
    var reason: String

    var id: String { name.localizedLowercase }
}
