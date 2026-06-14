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

    /// Y2（2026-06-13）：RepoContextPacker 生成的代码上下文元信息（可选，向后兼容）。
    ///
    /// **设计要点**：
    ///   - 旧版 RepoAIInsight 不含此字段，Codable 反序列化时为 nil；
    ///   - 不直接嵌入 `PackMetadata`：PackMetadata 含 `[SkippedFile]` 等大字段，
    ///     塞进 DB 会让 ai_summaries.summary_json 列体积暴增；
    ///   - 只挑 footer 需要的 7 个字段。
    var contextMetadata: RepoAIInsightContextMeta?

    /// Y9（2026-06-14）：摘要生成时 AnySearch 拉取的外部材料（已格式化为 markdown）。
    ///
    /// **为什么放在 Insight 里**：
    ///   - **零 schema migration**（决议 F=f2b）：作为 Codable 可选字段塞进
    ///     `summaryJson` 列，老缓存 JSON 缺该字段时反序列化为 nil，向后完全兼容；
    ///   - **复用缓存生命周期**：与摘要正文同生同灭——`cacheModelKey` 编码了
    ///     `external:on/off` 状态，settings 翻转后会自动失效；
    ///   - **对话路径零 HTTP**（决议 B=b2）：`chatStream` 读 `cachedInsight` 时
    ///     一并拿到 markdown，免去重复调 AnySearch API 烧配额。
    ///
    /// **内容形态**：直接存 `AnySearchContextProvider.collect()` 产出的整段
    /// `<external_context trust="untrusted" source="AnySearch">...</external_context>`
    /// 块（含防 prompt-injection 提示行 + 6 条 `- [title](url)\n  snippet` 列表）。
    /// 长度上限：6 条 × 500 字 ≈ 3KB，对 SQLite TEXT 列无压力。
    ///
    /// **不与 summaryMarkdown 末尾的"## 外部参考来源"段冲突**：
    ///   - `summaryMarkdown` 末尾仅有链接列表（无 snippet），给"摘要面板渲染"使用；
    ///   - 本字段保留完整 snippet，给"对话 system prompt 注入"使用；
    ///   - 两份数据来源同一次 collect 调用，无内容漂移风险。
    var externalContextMarkdown: String?
}

/// Y2：UI footer 显示的代码上下文元信息（PackMetadata 的精简投影）。
struct RepoAIInsightContextMeta: Codable, Equatable, Sendable {
    /// 完整 commit SHA（40 字符）
    var commitSha: String

    /// 分支或 tag（如 `main`）
    var ref: String

    /// 用户设定的 token 上限（来自 settings.aiRepoContextTokenBudget）
    var tokenBudget: Int

    /// 实际消耗的 token 数（基于 char count 估算）
    var actualTokens: Int

    /// 进入 XML 的文件总数（Tier 0 + Tier 1 + Tier 2 截断后保留路径数）
    var totalFiles: Int

    /// Packer 生成时刻 ISO-8601（与 PackMetadata.generatedAt 同源）
    var generatedAt: String

    /// 短 commit SHA（7 字符）—— UI 显示用，避免每次自己 prefix(7)
    var commitShaShort: String { String(commitSha.prefix(7)) }
}

struct AITagSuggestion: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var confidence: Double
    var reason: String

    var id: String { name.localizedLowercase }
}
