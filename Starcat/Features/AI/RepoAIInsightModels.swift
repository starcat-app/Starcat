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

    /// External Context Sources 的轻量元数据。
    ///
    /// 只保存 UI 展示所需的 title / URL / host / provider / fetchedAt，不保存
    /// `extractedText` 或 snippet，避免把第三方网页正文长期塞进 AI 摘要缓存。
    var externalContextSources: [AIExternalContextSource]? = nil

    /// Y9.1（2026-06-14）：摘要生成那一刻的"上下文配置快照"。
    ///
    /// **为什么需要这个字段**：
    /// 用 `contextMetadata != nil` 反推「当时是否启用代码上下文」是不可靠的——
    /// `contextMetadata == nil` 既可能是用户当时关了开关，也可能是当时 RepoContextPacker
    /// 下载失败 / 仓库私有 / 网络异常等降级路径。两种情况下的"用户意图"完全不同，
    /// 但靠 insight 现状无法区分。同样地，`externalContextMarkdown == nil` 不能区分
    /// 「用户当时关了 anysearch」vs「anysearch 调用失败了」。
    ///
    /// **解决方案**：在 `generateInsight` 完成时把当时的 settings effective 值快照下来，
    /// 后续 `isInsightStaleAgainstCurrentSettings` 拿快照与当前 settings 对比，准确判定
    /// 「用户翻过开关」这一事件。
    ///
    /// **向后兼容**：旧缓存 JSON 缺该字段 → Codable 反序列化为 nil → `isStale` 函数
    /// guard nil 直接返回 false（不报 stale），让历史 insight 自动豁免本次新加的判定，
    /// 避免出现"用户什么都没动但每次都提示设置已变更"的误报（dong4j 2026-06-14 反馈）。
    ///
    /// **存 effective 值而非原始 settings 字段**：
    ///   - `aiExternalContextEnabled`、`anySearchEnabled`、`aiExternalContextAllowPrivateRepos`
    ///     是 3 个相互制约的开关（双 AND + 私仓门控），存原始值会让"是否真的带了外网"
    ///     的判定散落到调用方；
    ///   - 直接存"effective allowed = true/false"，stale 判定就是两个 bool 比较，最干净。
    var generationContextSettings: GenerationContextSettings?
}

/// Y9.1（2026-06-14）：摘要生成时的"上下文配置快照"，用于精准判定 insight 是否
/// 与当前 settings 不一致（用户翻过开关）。
///
/// **存 effective 值而非原始 settings 字段**：见 `RepoAIInsight.generationContextSettings`
/// 的注释，避免 stale 判定逻辑散落。
struct GenerationContextSettings: Codable, Equatable, Sendable {
    /// 生成时 `settings.aiRepoContextEnabled` 的值（用户当时是否想要代码上下文）。
    var codeContextEnabled: Bool

    /// 生成时 AnySearch 外部材料**最终是否被允许**（双开关 AND + 私仓门控的 effective 结果）。
    /// 等价于 `AnySearchContextProvider.allowsExternalContext(...)` 在生成那一刻的返回值。
    var externalContextAllowed: Bool
}

struct AIExternalContextSource: Codable, Identifiable, Equatable, Sendable {
    var title: String
    var url: URL
    var host: String
    var provider: ExternalSearchProviderID
    var fetchedAt: String

    var id: String { "\(provider.rawValue):\(url.absoluteString)" }
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

/// AI 标签生成的"已有标签"提示，分两层语义传递给 prompt。
///
/// **为什么不用扁平 `[String]`**：
/// service 层无法区分"哪些是 repo 已绑定的（强信号，应优先复用避免重复打）"
/// 与"哪些是用户标签库里其它常用项（弱信号，作为风格参考）"。
/// 扁平数组下 prompt 只能写一句"优先复用"，LLM 对 repo 自身已有标签
/// 的避重感知会被全局标签稀释，容易生成「向量搜索 / Vector Search / 向量检索」
/// 这种同义不同名标签让标签库爆炸。
///
/// **设计约束**：
/// - 两个数组都已**去重 + 排序 + 截断**完成（由 `RepoAIInsightService.makeTagHints`
///   工厂方法统一生成）；service 层不再做二次处理；
/// - 排序保证 deterministic：同一份输入 → 同一份 source.hash → AI 摘要缓存稳定命中，
///   避免 `Set → Array` 顺序不稳导致缓存频繁失效；
/// - `repoTags` 与 `libraryTags` 互斥：`libraryTags` 工厂方法构造时已去掉 `repoTags`
///   里的元素，避免同一标签在 prompt 里出现两次（占字符 + 信号矛盾）；
/// - 任一数组为空时 prompt 对应段落不渲染（避免出现 `Existing tags ... :` 后跟空行）。
struct AITagHints: Sendable, Equatable {

    /// 当前 repo 已绑定的标签名（强信号，AI 必须优先复用避免同义重复）。
    /// 列表全部传，不截断——单个 repo 标签数量普遍 ≤10，prompt 占用可控。
    var repoTags: [String]

    /// 用户标签库里其它高频标签名（弱信号，作为风格 / 命名习惯参考）。
    /// 已去掉 `repoTags` 里的元素，并按使用次数倒序截断到约定上限。
    var libraryTags: [String]

    static let empty = AITagHints(repoTags: [], libraryTags: [])

    var isEmpty: Bool { repoTags.isEmpty && libraryTags.isEmpty }
}
