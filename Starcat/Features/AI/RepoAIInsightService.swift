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

    /// Y4：代码上下文降级原因（nil = 用上了代码或用户关了开关）。
    /// UI 层判定 banner 是否显示。
    var contextDegradationReason: ContextDegradationReason?

    /// Y9.3：外部网页上下文（AnySearch）降级原因（nil = 拉到了 / 用户没开 / 守卫拦截）。
    ///
    /// 与 `contextDegradationReason` 并行存在但相互正交：
    ///   - `contextDegradationReason`：代码上下文（RepoContextPacker）失败原因；
    ///   - `externalContextDegradationReason`：外部网页上下文（AnySearch）失败原因；
    ///   - 两者可同时非 nil（两路 banner 同时显示）。
    ///
    /// 关键约束：
    ///   - **守卫拦截不算降级**：用户没开 anySearchEnabled / aiExternalContextEnabled / 私仓不允许时，
    ///     `collect` 直接返回 nil，不进 catch 路径，本字段保持 nil；
    ///   - **0 结果不算降级**：HTTP 200 但业务零结果时（unique.isEmpty），那是 AnySearch 没数据，
    ///     不是错误，本字段保持 nil；
    ///   - **真错误才填**：AnySearchError / URLError / 兜底统一过 ExternalContextDegradationReason.classify
    ///     映射到具体 case，UI banner 显示对应文案。
    var externalContextDegradationReason: ExternalContextDegradationReason?
}

@MainActor
final class RepoAIInsightService {

    /// makeSource 产物：Summary / Tags 任务都用占位符渲染（`{metadata}` / `{readme}` /
    /// `{codeContext}` / `{externalContext}` / `{repoTags}` / `{libraryTags}`，详见
    /// `AIDefaultPrompts.summary` 与 `AIDefaultPrompts.tags` 注释）。
    ///
    /// `text` 字段保留是为了让 `Self.hash(text)` 作为缓存 key 输入——
    /// 它是 `metadata + "\n" + readme 块 + (可选) "\n\n" + codeContext` 的拼接快照，
    /// 但**不再直接喂给 prompt**（prompt 走拆段占位符注入）。新增的 externalContext
    /// 当 generateInsight 拿到 AnySearch 结果时会被合并进 hash 输入（详见
    /// `summarySource` 局部闭包），保证外部材料一变就让缓存失效。
    private struct Source {
        let text: String
        let hash: String

        /// Summary `{metadata}` / Tags `{metadata}` 的渲染源——
        /// repo 元数据多行块（fullName / description / language / topics / license / stars / forks / homepage）。
        let metadata: String

        /// Summary `{readme}` / Tags `{readme}` 的渲染源——清洗 + 截断后的 README 纯文本。
        /// 不含 "README:" 头（头由 prompt 模板自带，占位符仅渲染纯数据）。
        let readme: String

        /// Summary `{codeContext}` / Tags `{codeContext}` 的渲染源——
        /// RepoContextPacker 生成的 XML。失败 / 关闭 / 私仓不允许时为空字符串
        /// （不是 nil，让占位符直接渲染空段不出现 `{codeContext}` 字面量）。
        let codeContext: String

        /// Summary `{externalContext}` 的渲染源——AnySearch 生成的外部检索 markdown
        /// （已含 `<external_context trust="untrusted">` XML 包裹 + 警告语，详见
        /// `AnySearchContextProvider`）。无外部上下文 / 用户关了开关 / 私仓不允许时
        /// 为空字符串。Tags 任务不消费此字段——标签推荐不需要外部检索结果做风格参考。
        let externalContext: String

        /// Y2：从 RepoContextPacker 拿到的元信息（命中缓存或新生成都填充）。
        /// 透传到 makeInsight 写入 RepoAIInsight.contextMetadata，供 UI footer 显示。
        var contextMeta: RepoAIInsightContextMeta?

        /// Y4：本次 makeSource 阶段代码上下文降级原因（nil = 成功 或 用户关了开关）。
        /// 透传到 generateInsight 出参，UI 显示 banner。
        var contextDegradationReason: ContextDegradationReason?

        init(
            text: String,
            hash: String,
            metadata: String,
            readme: String,
            codeContext: String,
            externalContext: String = "",
            contextMeta: RepoAIInsightContextMeta? = nil,
            contextDegradationReason: ContextDegradationReason? = nil
        ) {
            self.text = text
            self.hash = hash
            self.metadata = metadata
            self.readme = readme
            self.codeContext = codeContext
            self.externalContext = externalContext
            self.contextMeta = contextMeta
            self.contextDegradationReason = contextDegradationReason
        }
    }

    private let summaryRepository: any AISummaryRepositoryProtocol
    private let readmeRepository: ReadmeRepository
    private let settings: AppSettings
    private let keychain: any KeychainManaging
    private let externalContextProvider: AnySearchContextProvider

    /// X4（2026-06-13）：注入 RepoContextPacker 的代码上下文。
    ///
    /// 设计原则与 `externalContextProvider`（AnySearch）镜像：
    ///   - `Optional`：传 nil 时完全跳过代码上下文路径（单测 / 老调用方）；
    ///   - **失败降级**：provider 内部已经做了"任何错误 → 返回 nil"的兜底，service 不再 catch；
    ///   - **影响缓存**：context xml 被拼到 `Source.text` 末尾，自动让 `Source.hash` 变化，
    ///     旧摘要缓存随之失效。
    private let repoAIContextProvider: RepoAIContextProvider?

    /// 2026-06-12 向量索引改进：摘要生成成功后回调，让 `SemanticSearchService` 走
    /// `refreshIndexIfChanged` 重建向量。
    ///
    /// 为何用闭包而非直接持有 `SemanticSearchService`：避免 RepoAIInsightService ↔
    /// SemanticSearchService 互相 @MainActor 持有的循环依赖；AppDependencies 在装配时
    /// 把 `[weak service]` 闭包挂上来即可。
    ///
    /// var 而非 let：AppDependencies 的构造顺序是先 aiInsight 后 semanticSearch，
    /// 用 setter `setOnSummaryGenerated(_:)` 在装配末尾注入回调，避免双向构造时序困境。
    private var onSummaryGenerated: (@MainActor (Repo) -> Void)?

    init(
        summaryRepository: any AISummaryRepositoryProtocol,
        readmeRepository: ReadmeRepository,
        settings: AppSettings,
        keychain: any KeychainManaging = KeychainManager.shared,
        repoAIContextProvider: RepoAIContextProvider? = nil,
        onSummaryGenerated: (@MainActor (Repo) -> Void)? = nil
    ) {
        self.summaryRepository = summaryRepository
        self.readmeRepository = readmeRepository
        self.settings = settings
        self.keychain = keychain
        self.externalContextProvider = AnySearchContextProvider(settings: settings)
        self.repoAIContextProvider = repoAIContextProvider
        self.onSummaryGenerated = onSummaryGenerated
    }

    /// 装配时序后置注入回调（AppDependencies 用）。
    /// 让 `SemanticSearchService` 先构造完，再回头给 `aiInsight` 挂上 "weak semantic" 闭包。
    func setOnSummaryGenerated(_ handler: (@MainActor (Repo) -> Void)?) {
        self.onSummaryGenerated = handler
    }

    /// 当前对话流式所用的模型名。
    ///
    /// 与 `chatStream` / `makeClient` 中的解析顺序完全一致——优先用 `aiChatTask`
    /// 的 `resolvedModelName`，空则 fallback 到全局 `aiChatModel`。给"复制完整对话"
    /// 导出的 Markdown 末尾署名「由 X 生成」时使用。
    /// HOM-150 dong4j 2026-06-04 15:48 反馈："markdown 的最后应该加上由什么模型生成
    /// 的，就像 AI 摘要生成最后也添加了由什么模型生成的"。
    ///
    /// 2026-06-14 v4：从 `aiSummaryTask` 改成 `aiChatTask`（chat 提到 task 平级）。
    /// 老用户首次启动时 `aiChatTask` 默认值会用与摘要同 provider+model（详见
    /// `AppSettings.init` 的 fallback 逻辑），所以 model 选择行为对老用户无感。
    var resolvedChatModelName: String {
        settings.aiChatTask.resolvedModelName.nilIfBlank ?? settings.aiChatModel
    }

    func cachedInsight(for repo: Repo) async throws -> RepoAIInsight? {
        let source = try await makeSource(for: repo)
        return try await loadCachedInsight(source: source, repo: repo)
    }

    /// Y9（2026-06-14）：根据已经算好的 `Source` 加载缓存 insight。
    ///
    /// 提取该 helper 是为了让 `chatStream` 只调一次 `makeSource`（重 IO：可能触发
    /// ZIP 下载 / snapshotService.resolveBranch 网络调用），把 hash 比对与 source 计算
    /// 解耦。`cachedInsight(for:)` 公开 API 形式不变，内部走同一条路径。
    private func loadCachedInsight(source: Source, repo: Repo) async throws -> RepoAIInsight? {
        guard let record = try await summaryRepository.find(repoId: repo.id, model: cacheModelKey()),
              record.sourceHash == source.hash
        else {
            return nil
        }
        return try Self.decodeInsight(json: record.summaryJson)
    }

    func generateInsight(
        for repo: Repo,
        existingTagHints: AITagHints = .empty,
        includeSummary: Bool = true,
        includeTags: Bool = true,
        allowExternalContext: Bool = true,
        onSummaryDelta: (@MainActor (String) -> Void)? = nil
    ) async throws -> RepoAIInsightGeneration {
        let source = try await makeSource(for: repo)
        let generatedAt = ISO8601DateFormatter.shared.string(from: Date())
        let resolvedExternalContext: AIExternalContext?
        // Y9.3（2026-06-14 dong4j 反馈）：捕获 anysearch 降级原因，让 UI 给出具体反馈
        // （之前只打 log 静默降级，用户看不到为什么没注入）。
        var externalDegradationReason: ExternalContextDegradationReason?
        if includeSummary, allowExternalContext {
            do {
                resolvedExternalContext = try await externalContextProvider.collect(for: repo)
            } catch {
                // 外部搜索是补充能力，失败不能阻断本地 README 摘要。
                AppLog.ai.error("AnySearch external context skipped: \(error.localizedDescription, privacy: .public)")
                resolvedExternalContext = nil
                externalDegradationReason = ExternalContextDegradationReason.classify(error)
            }
        } else {
            resolvedExternalContext = nil
        }

        // 2026-06-14 dong4j 反馈重构：Tags 双层 hints 改走占位符渲染路径
        //   ({repoTags} / {libraryTags}，详见 AIDefaultPrompts.tags 注释)，
        //   不再在 source.text 末尾硬拼接附录，因此：
        //   - 摘要任务的 source 不再被无关 Tag 规则污染（旧实现 augmentedSource 同时
        //     喂给了 summary 和 tags 两条路径，是隐性 bug）；
        //   - Tag format rules 已上提到 system prompt 默认值（用户可见 / 可改 / 改坏点 Restore Default）。
        //
        // 双层 hints 由调用方通过 `RepoAIInsightService.makeTagHints(...)` 工厂方法统一构造，
        // 保证两条入口（单仓 AI 摘要 / 批量 AI 整理）信号源不漂移；详见 `AITagHints` 注释。

        // 两者都需要时并发跑；任一关闭则串行 / 短路，避免无意义 AI 调用。
        // Summary 走 `summarySource`（含 AnySearch 外部材料），Tags 走 `(source, hints)`。
        //
        // 2026-06-14 v4 拆段重构：旧实现把 ext.markdown 拼到 `source.text` 末尾，依赖
        // Summary prompt 的单一 `{context}` 占位符替换吞下整段。新实现把 `externalContext`
        // 升级为一等字段，由 generateSummary 通过独立 `{externalContext}` 占位符渲染；
        // `text` 字段仍合并 ext.markdown 仅为了 hash 计算——任何 ext 变化都让缓存失效，
        // 与 v3 行为等价。
        let summarySource: Source = {
            guard let context = resolvedExternalContext else { return source }
            let hashInput = source.text + "\n" + context.markdown
            return Source(
                text: hashInput,
                hash: Self.hash(hashInput),
                metadata: source.metadata,
                readme: source.readme,
                codeContext: source.codeContext,
                externalContext: context.markdown,
                contextMeta: source.contextMeta,
                contextDegradationReason: source.contextDegradationReason
            )
        }()

        var summaryText: String
        let resolvedTagResult: Result<[AITagSuggestion], Error>
        if includeSummary, includeTags {
            async let tagResult = tagSuggestionsResult(source: source, hints: existingTagHints)
            summaryText = try await generateSummary(source: summarySource, onDelta: onSummaryDelta)
            resolvedTagResult = await tagResult
        } else if includeSummary {
            summaryText = try await generateSummary(source: summarySource, onDelta: onSummaryDelta)
            resolvedTagResult = .success([])
        } else if includeTags {
            summaryText = ""
            resolvedTagResult = await tagSuggestionsResult(source: source, hints: existingTagHints)
        } else {
            // 调用方两者都关：返回空 insight，避免无意义网络调用。
            summaryText = ""
            resolvedTagResult = .success([])
        }
        let suggestions = (try? resolvedTagResult.get()) ?? []
        if let context = resolvedExternalContext, !summaryText.isEmpty {
            let links = context.sources.map { "- [\($0.host ?? $0.absoluteString)](\($0.absoluteString))" }
            // 2026-06-14 v4：footer 标题走 i18n。旧版硬编码"## 外部参考来源"导致英文
            // 系统下生成的摘要混杂中文标题，与 prompt 的 {outputLanguage} 策略冲突。
            let footerTitle = String(localized: "ai.assistant.summary.externalReferences.title")
            summaryText += "\n\n## \(footerTitle)\n" + links.joined(separator: "\n")
        }
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
            generatedAt: generatedAt,
            // Y2：把 makeSource 阶段拿到的 PackMetadata 投影透传到 RepoAIInsight，
            // 让 UI footer 能显示"基于 commit abc123 (4280 tokens, 38 files)"。
            contextMeta: source.contextMeta
        )

        // 保留旧字段的同时把新摘要正文写进 summaryMarkdown，UI 优先读该字段。
        insight.summaryMarkdown = summaryText

        // Y9（2026-06-14，决议 B=b2）：把 AnySearch 拉来的整段 markdown 回填到 insight。
        //
        // 设计要点：
        //   - 直接存 `resolvedExternalContext?.markdown`（已含 <external_context> XML 包裹 +
        //     防 prompt-injection 提示 + 6 条 snippet），不做任何二次处理；
        //   - 用户关了 anySearch / external context / 私仓不允许 → resolvedExternalContext 为 nil →
        //     此处赋 nil，对话路径读到 nil 时静默不拼，与"用户意图"一致；
        //   - 与 `summaryText` 末尾追加的"## 外部参考来源"链接列表不冲突——前者给摘要面板渲染
        //     展示用，后者给对话 system prompt 注入用，两份数据来源同一次 collect 调用。
        insight.externalContextMarkdown = resolvedExternalContext?.markdown

        // Y9.1（2026-06-14）：把生成时的"上下文配置快照"写进 insight。
        //
        // 这是 stale banner 判定的唯一信任源：UI 层用 `snap vs 当前 settings` 对比，
        // 只在用户翻过开关时报 stale；老 insight 缺该字段（Codable 反序列化为 nil）
        // 自动豁免，规避 Y9 初版"老缓存每次都误报"的 bug（dong4j 2026-06-14 反馈）。
        //
        // externalContextAllowed 存 effective 结果（双开关 AND + 私仓门控的最终值），
        // 与 chatStream 的 AnySearchContextProvider.allowsExternalContext(...) 同款判定，
        // 避免后续 UI 层重复计算 3 个开关的组合。
        insight.generationContextSettings = GenerationContextSettings(
            codeContextEnabled: settings.aiRepoContextEnabled,
            externalContextAllowed: AnySearchContextProvider.allowsExternalContext(
                repoIsPrivate: repo.isPrivate,
                enabled: settings.anySearchEnabled && settings.aiExternalContextEnabled,
                allowPrivate: settings.aiExternalContextAllowPrivateRepos
            )
        )

        // HOM-52：只跑标签（includeSummary == false）时不写 ai_summaries 缓存——
        // 否则会用空 summaryText 覆盖已有的有效摘要缓存。调用方仍能拿到 suggestions。
        if includeSummary, repo.isStarred {
            let jsonData = try JSONEncoder().encode(insight)
            let record = AISummaryRecord(
                repoId: repo.id,
                model: cacheModelKey(),
                sourceHash: source.hash,
                summaryJson: String(decoding: jsonData, as: UTF8.self),
                generatedAt: generatedAt
            )
            try await summaryRepository.upsert(record)

            // 2026-06-12 向量索引改进：摘要生成成功后触发单 repo 向量重建。
            // AppDependencies 装配时挂的 `[weak semanticSearchService]` 闭包负责走
            // `refreshIndexIfChanged`，diff 判定通过才真的调 embedding API。
            // 不在 try await 失败路径触发：上面 `try await summaryRepository.upsert` 抛错就直接 throw，
            // 触发点放在 upsert 之后保证状态一致。
            onSummaryGenerated?(repo)
        }
        return RepoAIInsightGeneration(
            insight: insight,
            tagErrorMessage: tagErrorMessage,
            // Y4：透传 makeSource 阶段的代码上下文降级原因。
            // 注：summarySource 从 source 派生但不改 contextDegradationReason，
            // 这里直接读最原始 source 的 reason 即可。
            contextDegradationReason: source.contextDegradationReason,
            // Y9.3：透传 anysearch 降级原因，UI 层渲染独立 banner。
            externalContextDegradationReason: externalDegradationReason
        )
    }

    /// 与仓库对话（HOM-150）。
    ///
    /// 与 `generateInsight` 的区别：
    /// - 走"多轮 chat"路径：system prompt 注入 repo 元数据 + README，
    ///   `history` 承载之前的用户/助手轮次，本轮发的内容放 `userMessage`；
    /// - **强制流式**，忽略 `aiChatTask.parameters.streamEnabled`——
    ///   chat 体验对"打字机式增量出字"非常敏感，非流式整段返回会让窗口长时间空白；
    /// - **不写 SQLite 缓存**：对话上下文是临时的，下次打开窗口重新开始；持久化要等
    ///   后续真的有"历史会话回看"需求再设计表结构；
    /// - **不解析 JSON / 不限制结构**：模型可以自由用 Markdown 回答（含代码块）。
    ///
    /// 2026-06-14 v4 拆分 `aiChatTask`（之前复用 `aiSummaryTask`）：把 chat 的 prompt /
    /// provider / model / 参数都暴露给 Settings 编辑，跟其他 4 个任务平级。老用户首次启动
    /// 时 `aiChatTask` 默认值会用与摘要同 provider+model + summaryDefault 参数，行为对
    /// 老用户基本无感（唯一差异：system prompt 现在走 `AIDefaultPrompts.chat` 模板）。
    /// 同 `generateInsight` 一样，复用 `makeSource(for:)` 拼出的"repo 元数据 + README"
    /// 上下文，避免对 README WebView 缓存路径出现两份取数逻辑。
    ///
    /// **Y9（2026-06-14）对话上下文增强**（决议 A=a2 / B=b2 / F1=f1b）：
    /// system prompt 在 README + (可选) Code XML 之外，按当前 settings 决定是否额外注入：
    ///   - **AI 摘要正文**（包括 markdown）：从 `loadCachedInsight` 读，没缓存就为空字符串；
    ///     喂给 prompt 模板的 `{summary}` 占位符，渲染为 `## AI Summary` 段；
    ///   - **AnySearch 外部材料**：从 `cachedInsight.externalContextMarkdown` 读，
    ///     **零额外 HTTP**（决议 B=b2，对话路径不重复调 AnySearch API 烧配额）；
    ///     需 settings 当前允许（anySearch+externalContext+私仓门控）才注入；
    ///   - **代码上下文 XML**：由 `makeSource` 内部根据 `aiRepoContextEnabled` 决定，
    ///     与摘要路径完全对称，无需额外参数。
    ///
    /// 这意味着：用户在快捷菜单或 Settings 翻开关 → 下一条对话立即生效（settings 是
    /// `@MainActor @Observable`，本方法同 actor 直读零 race）。如果用户翻开关后
    /// `cacheModelKey` / `source.hash` 失效 → cachedInsight 拿不到 → 对话退化成
    /// README-only（含 Code XML if 开），与摘要面板 "[设置已变更, 重新生成]" 提示
    /// 形成对偶反馈链。
    /// HOM-70 v2（2026-06-15）：新增 `carriedOverSummary: String?` 必填入参——本 session 由
    /// 「上下文溢出 → 新建并承接」诞生时，调用方（`RepoAIChatViewModel.sendMessage`）
    /// 把 `currentCarriedOverSummary` 透传进来，service 注入 system prompt 的
    /// `{previousSessionCarryOver}` section，让 AI 知道上一对话末尾聊到哪儿。
    /// 普通 session 传 `nil` —— 项目未上线不给默认值，强制 callsite 显式声明意图，
    /// 避免未来新增对话路径漏注入承接段。
    ///
    /// 2026-06-15 v4.y：再加 `wikiLinks` / `codeFlowPageURL` 两个必填入参 —— 把已收录
    /// 的外部 Wiki 镜像 + 本地 CodeFlow `file://` 链接注入 system prompt 的
    /// `{starcatResources}` section，由 `StarcatResourcesProvider.snapshot(...)` 渲染。
    /// 调用方（`RepoAIChatViewModel.sendMessage`）从 bootstrap 期缓存的内存值
    /// （`wikiContextService.cachedLinks(...)` + `CodeFlowStorage.existingProject(...).pageURL`）
    /// 透传过来；无资源时传空数组 / nil，section 渲染为空 header（LLM 自动忽略）。
    func chatStream(
        for repo: Repo,
        history: [AIChatMessage],
        userMessage: String,
        carriedOverSummary: String?,
        wikiLinks: [WikiLink],
        codeFlowPageURL: URL?,
        // 聊天链路只上抛本次新增 delta。累积值由 ViewModel 单点维护，避免 SDK、
        // service、UI 三层各复制一次不断增长的完整字符串。
        onDelta: (@MainActor (String) -> Void)? = nil
    ) async throws -> String {
        let source = try await makeSource(for: repo)

        // Y9：复用同一份 source 做缓存比对（避免 makeSource 被调两次造成重复网络 IO）。
        // 缓存命中 = 摘要 + AnySearch markdown 都从 `ai_summaries.summary_json` 直接拿到。
        // try? 故意吞错：缓存读失败（比如 SQLite 临时锁）不应阻塞对话主流程。
        let cached = try? await loadCachedInsight(source: source, repo: repo)

        let task = settings.aiChatTask
        let (client, model) = try makeClient(task: task, fallbackModel: settings.aiChatModel, taskName: "对话")

        let systemPrompt = buildChatSystemPrompt(
            repo: repo,
            source: source,
            cached: cached,
            carriedOverSummary: carriedOverSummary,
            wikiLinks: wikiLinks,
            codeFlowPageURL: codeFlowPageURL
        )

        let request = AIChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userMessage,
            history: history,
            model: model,
            parameters: settings.effectiveParameters(for: task),
            responseFormat: .text
        )

        var accumulated = ""
        for try await event in client.chatStream(request: request) {
            switch event {
            case .delta(let delta):
                accumulated += delta
                onDelta?(delta)
            case .completed(let response):
                return response.content
            }
        }
        // 部分服务端在 stream 结束时不发 `completed` 事件，只靠 chunk 累积。
        // 这里兜底用累积值；若仍为空才抛 emptyResponse。
        guard let final = accumulated.nilIfBlank else { throw AIClientError.emptyResponse }
        return final
    }

    /// 2026-06-14 v4 重构：拼装对话路径的 system prompt，走 `aiChatTask.prompt` 模板
    /// + 占位符渲染（详见 `AIDefaultPrompts.chat` 注释，2026-06-15 起 8 占位符）。
    ///
    /// 实质渲染逻辑下沉到 `assembleChatSystemPrompt(...)` 静态函数（internal 可测），
    /// 本方法负责"读 settings + 私仓门控 + 拆 source 字段 + 调 RuntimeContextProvider"
    /// 等 actor-bound 准备工作。
    private func buildChatSystemPrompt(
        repo: Repo,
        source: Source,
        cached: RepoAIInsight?,
        carriedOverSummary: String?,
        wikiLinks: [WikiLink],
        codeFlowPageURL: URL?
    ) -> String {
        let externalAllowed = AnySearchContextProvider.allowsExternalContext(
            repoIsPrivate: repo.isPrivate,
            enabled: settings.anySearchEnabled && settings.aiExternalContextEnabled,
            allowPrivate: settings.aiExternalContextAllowPrivateRepos
        )
        // 私仓门控不通过时，把 externalContext 强制清空（即便 cached 里有也不注入）。
        let externalContext = externalAllowed
            ? (cached?.externalContextMarkdown ?? "")
            : ""
        // 2026-06-15：每次组装都实时抓 runtimeContext。UTC 时间到整点精度，
        // 同一小时内字符串完全相同，服务端 prompt cache 仍能命中；跨小时才 miss 一次。
        // 2026-06-15 v4.y：starcatResources 走纯函数 provider，wiki / codeflow 数据由
        // viewModel bootstrap 期缓存好（cache hit 秒返回，miss 后台刷新），这里直接拼字符串。
        let starcatResources = StarcatResourcesProvider.snapshot(
            wikiLinks: wikiLinks,
            codeFlowPageURL: codeFlowPageURL
        )
        return Self.assembleChatSystemPrompt(
            template: settings.aiChatTask.prompt.systemPrompt,
            outputLanguage: Self.outputLanguageDescriptor(),
            runtimeContext: RuntimeContextProvider.snapshot(),
            starcatResources: starcatResources,
            metadata: source.metadata,
            readme: source.readme,
            codeContext: source.codeContext,
            summary: cached?.summaryMarkdown ?? "",
            externalContext: externalContext,
            previousSessionCarryOver: carriedOverSummary ?? ""
        )
    }

    /// v4：对话 system prompt 渲染的纯函数（静态、无 actor 副作用、internal for tests）。
    ///
    /// 直接走 `AIPromptConfiguration.renderedSystemPrompt(placeholders:)`，跟 Summary /
    /// Tags 任务的渲染路径完全一致。占位符在 `template` 里找不到时保留字面量
    /// （让 LLM 看到 `{xxx}` 便于排错），找到则替换为对应字段。
    ///
    /// **空 section 处理**（跟 Summary v4 同款）：`codeContext` / `summary` / `externalContext`
    /// 任意一个为空字符串都直接渲染成空 section header（如 `## AI Summary` 后面什么都没有），
    /// LLM 自然忽略，不在这里做"删除整段 section"的复杂字符串处理——pre-launch 阶段
    /// 简单稳定优先，token 浪费 < 5/section 可以接受。
    ///
    /// **签名变更说明**：v3 旧签名是 `(sourceText, cachedSummaryMarkdown, cachedExternalMarkdown,
    /// allowExternal)`，把 metadata + readme + codeContext 黑盒拼成 `sourceText` 喂进去。
    /// v4 改成"6 个一等参数"，跟模板的 6 占位符一一对应，让单测能精确断言每个占位符的渲染结果。
    /// 2026-06-15 v4.x 追加 `runtimeContext` 参数，对应模板新增的 `{runtimeContext}` 占位符。
    ///
    /// `nonisolated`：本函数纯字符串拼接、无 actor 副作用，单测从 sync 上下文可直接调用。
    nonisolated static func assembleChatSystemPrompt(
        template: String,
        outputLanguage: String,
        runtimeContext: String,
        starcatResources: String,
        metadata: String,
        readme: String,
        codeContext: String,
        summary: String,
        externalContext: String,
        previousSessionCarryOver: String
    ) -> String {
        // 复用 AIPromptConfiguration.render（{key} → value，dict 没有的 key 保留字面量
        // 让 LLM 看到便于排错），与 Summary / Tags 任务的渲染语义统一。
        //
        // 「必填参数 + 不给默认值」遵循 HOM-70 v2 同款约束：项目未上线，让编译器帮我找到
        // 所有 callsite 一并升级，避免后续新增对话路径漏注入。具体到本函数：
        // - `previousSessionCarryOver` 普通 session 传 `""`（承接段为空 section header）；
        // - `runtimeContext` 调用方应传 `RuntimeContextProvider.snapshot()`，不留兜底空串
        //   入口避免"忘了调 provider 还能编译过"的潜在 bug；
        // - `starcatResources` 调用方传 `StarcatResourcesProvider.snapshot(wikiLinks:codeFlowPageURL:)`
        //   的结果（全空时本身就是空串，section 自然为空 header）。
        AIPromptConfiguration.render(
            template: template,
            placeholders: [
                "outputLanguage": outputLanguage,
                "runtimeContext": runtimeContext,
                "starcatResources": starcatResources,
                "metadata": metadata,
                "readme": readme,
                "codeContext": codeContext,
                "summary": summary,
                "externalContext": externalContext,
                "previousSessionCarryOver": previousSessionCarryOver
            ]
        )
    }

    private func tagSuggestionsResult(
        source: Source,
        hints: AITagHints
    ) async -> Result<[AITagSuggestion], Error> {
        do {
            return .success(try await generateTags(source: source, hints: hints))
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
        let params = settings.effectiveParameters(for: task)
        // Summary 任务占位符（v4，2026-06-14）：
        // - system: `{outputLanguage}`
        // - user:   `{outputLanguage}` / `{metadata}` / `{readme}` / `{codeContext}` / `{externalContext}`
        // 详见 `AIDefaultPrompts.summary` 注释。删某个占位符 → 不渲染对应内容；
        // dict 里 build 完整 5 key 即可，prompt 模板里没用到的 key 不会有副作用。
        let outputLanguage = Self.outputLanguageDescriptor()
        let request = AIChatRequest(
            systemPrompt: task.prompt.renderedSystemPrompt(placeholders: [
                "outputLanguage": outputLanguage
            ]),
            userPrompt: task.prompt.renderedUserPrompt(placeholders: [
                "outputLanguage": outputLanguage,
                "metadata": source.metadata,
                "readme": source.readme,
                "codeContext": source.codeContext,
                "externalContext": source.externalContext
            ]),
            model: model,
            parameters: params,
            responseFormat: .text
        )

        if params.streamEnabled {
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

    /// Tags 任务私有占位符渲染。
    ///
    /// **占位符约定**（v4，详见 `AIDefaultPrompts.tags` 注释）：
    /// - system prompt：`{outputLanguage}`（驱动 Tag Style Rules 分支 + reason 字段语言）
    /// - user prompt：`{metadata}` / `{readme}` / `{codeContext}` / `{repoTags}` / `{libraryTags}`
    ///
    /// **2026-06-14 v4 重命名**（dong4j 拍板，方案 C 全栈占位符归一化）：
    /// 旧两段式 `{output.language}` / `{repository.metadata}` / `{repository.readme}` /
    /// `{repository.code_context}` / `{tags.repo}` / `{tags.library}` 重命名为单段驼峰，
    /// 跟 Embedding / Translation / Summary 任务对齐。pre-launch 直接换名，不做 backward compat。
    ///
    /// **删占位符 = 不注入对应数据**：用户在 Settings 改默认 prompt 把某个占位符删掉，
    /// service 这里仍然 build 同一份 dict，但替换不到 → 自然不渲染对应内容；
    /// 反过来用户多写了占位符也无害（dict 没有就保留字面量，让 LLM 直接看到便于排错）。
    private func generateTags(source: Source, hints: AITagHints) async throws -> [AITagSuggestion] {
        let task = settings.aiTagsTask
        let (client, model) = try makeClient(task: task, fallbackModel: settings.aiChatModel, taskName: "推荐标签")

        let outputLanguage = Self.outputLanguageDescriptor()
        let systemPrompt = task.prompt.renderedSystemPrompt(placeholders: [
            "outputLanguage": outputLanguage
        ])
        // hints 已由 makeTagHints 工厂方法做过 trim + 去重 + 排序 + 截断（详见 AITagHints 注释），
        // 这里 join 即可；任一为空时占位符渲染为空字符串，prompt 模板里对应的 label
        // 保持原样（用户编辑 prompt 时所见即所得）。
        let userPrompt = task.prompt.renderedUserPrompt(placeholders: [
            "metadata": source.metadata,
            "readme": source.readme,
            "codeContext": source.codeContext,
            "repoTags": hints.repoTags.joined(separator: ", "),
            "libraryTags": hints.libraryTags.joined(separator: ", ")
        ])

        let response = try await client.chat(request: AIChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            parameters: settings.effectiveParameters(for: task),
            responseFormat: .jsonObject
        ))
        return try Self.decodeTagSuggestions(json: response.content)
    }

    /// `{outputLanguage}` 占位符的 Locale 派发。
    ///
    /// 派发到 LLM 一眼能识别的英文语言名（`Simplified Chinese` / `English` / 等），
    /// 避免不同 Provider 对 BCP-47 标识（`zh-Hans`）解读不一致。
    /// Tags 与 Summary 任务都用此 helper 提供 `{outputLanguage}` 值（2026-06-14 v4
    /// 起统一）；将来其它需要按系统语言切换输出的任务也复用本 helper。
    nonisolated static func outputLanguageDescriptor() -> String {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        switch lang {
        case "zh":
            let region = Locale.current.language.region?.identifier
            return (region == "TW" || region == "HK" || region == "MO")
                ? "Traditional Chinese"
                : "Simplified Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        case "ru": return "Russian"
        case "pt": return "Portuguese"
        default:   return "English"
        }
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
            timeoutInterval: settings.effectiveParameters(for: task).timeoutSeconds
        )), model)
    }

    private func cacheModelKey() -> String {
        let summaryModel = settings.aiSummaryTask.resolvedModelName.nilIfBlank ?? settings.aiChatModel
        let tagsModel = settings.aiTagsTask.resolvedModelName.nilIfBlank ?? settings.aiChatModel
        let external: String = {
            guard settings.anySearchEnabled && settings.aiExternalContextEnabled else { return "off" }
            return settings.aiExternalContextAllowPrivateRepos ? "on-private" : "on-public"
        }()
        return "summary:\(settings.aiSummaryTask.providerID)/\(summaryModel)|tags:\(settings.aiTagsTask.providerID)/\(tagsModel)|external:\(external)"
    }

    /// 为标签生成构造双层 hints：repo 自身已绑定标签（强信号） + 用户标签库其它高频标签（弱信号）。
    ///
    /// **必须由两条调用入口共享**——`RepoAIInsightViewModel.generate(...)`（单仓 AI 摘要应用标签）
    /// 与 `BatchAIQueueService.processSingle(...)`（批量 AI 整理）。两边必须走同一份提示构造逻辑，
    /// 否则又会出现 2026-06-14 上午发现的"单仓路径漏传 hints / 批量只取全局 Top 50 漏掉 repo
    /// 自身标签"两条路径漂移问题。
    ///
    /// **算法**：
    /// 1. 拉 `repo` 当前已绑定标签（一般 ≤10 个，全部传入；强信号）。
    /// 2. 拉全库标签 + 全库使用次数 dict，按 (使用次数 DESC, name ASC) 稳定排序。
    /// 3. 从全库标签中**剔除已在 repo 上**的项（避免与 repoTags 重复占字符 / 信号矛盾）。
    /// 4. 截断到 `libraryLimit`（默认 30，dong4j 2026-06-14 拍板：≤40 个不挤压 README，
    ///    避免 prompt 偏向风格匹配过强）。
    ///
    /// **稳定性约束**：
    /// - 两个 list 都按 `(useCount DESC, name ASC)` 排序——不用 `Set → Array` 顺序不稳的
    ///   桶序，避免同一份输入产生不同 source.hash 让 AI 摘要缓存失效。
    /// - 任一 repository 抛错时降级为空数组（标签生成是辅助优化项，不能因此阻断 AI 摘要主流程）。
    ///
    /// **参数**：
    /// - `libraryLimit` 默认 30，可由 caller 调整；过大 (>50) 会让 prompt 偏向"风格匹配"信号
    ///   稀释「优先在 repo 已有里复用」的强信号；过小 (<10) 又失去"参考其它命名颗粒度"的价值。
    static func makeTagHints(
        for repo: Repo,
        repoTagRepository: any RepoTagRepositoryProtocol,
        tagRepository: any TagRepositoryProtocol,
        libraryLimit: Int = 30
    ) async -> AITagHints {
        async let repoTagsResult: [Tag] = {
            (try? await repoTagRepository.fetchTags(forRepo: repo.id)) ?? []
        }()
        async let allTagsResult: [Tag] = {
            (try? await tagRepository.fetchAll()) ?? []
        }()
        async let countsResult: [String: Int] = {
            (try? await repoTagRepository.repoCountsByTag()) ?? [:]
        }()

        let repoTags = await repoTagsResult
        let allTags = await allTagsResult
        let counts = await countsResult

        // repo 已有标签：trim + 去空 + 去重 + 排序（稳定 hash）。
        // 不按 useCount 排——repo 自身这几个标签信号同等重要，按 name 字典序最稳。
        let repoNames: [String] = {
            let cleaned = repoTags
                .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Array(Set(cleaned)).sorted()
        }()

        // 全库标签：剔除 repo 已有项 → 按 (useCount DESC, name ASC) 排 → 截断。
        let repoNameSet = Set(repoNames)
        let libraryNames: [String] = allTags
            .map { (name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), id: $0.id) }
            .filter { !$0.name.isEmpty && !repoNameSet.contains($0.name) }
            .sorted { lhs, rhs in
                let lc = counts[lhs.id] ?? 0
                let rc = counts[rhs.id] ?? 0
                if lc != rc { return lc > rc }
                return lhs.name < rhs.name
            }
            .prefix(max(0, libraryLimit))
            .map(\.name)

        return AITagHints(repoTags: repoNames, libraryTags: libraryNames)
    }

    /// 拼出"喂 LLM 的 repo 上下文"——元数据 + 清洗后的 README。
    ///
    /// **2026-06-12 改造**（向量索引改进）：
    /// - README 清洗逻辑从本地 `Self.stripHTML` + 硬编码 12000 截断改为
    ///   `ReadmePreprocessor.process(html:/markdown:)`，与向量索引共用同一份规则；
    /// - 截断长度从 `AppSettings.aiReadmeTruncateLength` 读，让用户在 Settings 滑杆调整后
    ///   AI 摘要 / 向量化都同步生效；
    /// - 优先使用 `readme_contents.content`(raw markdown,HOM-201 P2-2 拆表后独立):
    ///   决策 E3 后台懒补全完成时直接用原文,信息密度比 HTML 剥后高;
    ///   fallback `rendered_html` 保留兼容。
    private func makeSource(for repo: Repo) async throws -> Source {
        let markdown = try await readmeRepository.findContent(repoId: repo.id)
        let readme: Readme? = (markdown == nil)
            ? try await readmeRepository.find(repoId: repo.id)
            : nil
        let truncateLength = settings.aiReadmeTruncateLength
        let readmeText: String = {
            if let markdown, !markdown.isEmpty {
                return ReadmePreprocessor.process(markdown: markdown, maxLength: truncateLength)
            }
            if let html = readme?.renderedHtml, !html.isEmpty {
                return ReadmePreprocessor.process(html: html, maxLength: truncateLength)
            }
            return ""
        }()

        // HOM-199 AI 摘要缓存稳定化（2026-06-14）：拆分"喂 LLM 的文本"和"缓存键 hash"两条路径。
        //
        // 旧版用同一个 `source` 字符串既送 LLM 又算 SHA256 写进 `ai_summaries.source_hash`。
        // 但 `source` 里塞了 `Stars: N` / `Forks: M` 这种 GitHub sync 每次都会刷新的流量数据，
        // 导致——
        //   1. 用户登录 / 重新登录 → AuthSession 触发立即 performFullSync；
        //   2. 几乎每个仓库的 starsCount / forksCount 都被刷成新值；
        //   3. 所有 ai_summaries.source_hash 一次性全部失效；
        //   4. UI 端 cachedInsight() 因 hash 不匹配返回 nil → 用户看到"AI 摘要全部消失"，
        //      数据其实没丢，DB 表里 summary_json 还在。
        //
        // 修复策略：保留 `llmText`（含 stars/forks/homepage，让 LLM 仍有热度感知，
        // 重新生成时摘要质量不退化），但 `hashText` 只包含"语义稳定子集"：
        //   - repo 身份：fullName
        //   - 作者主动维护的元信息：description / language / topics / license
        //   - README 正文
        //   - 代码上下文 XML（commit SHA 改 = 代码语义改，应该重生成 → 仍进 hash）
        //
        // 剔除字段：
        //   - Stars / Forks：纯流量数据，不影响"这个项目做什么"的判定
        //   - Homepage：少数仓库主会改，但改了不需要重生成摘要（首页 URL 跟项目定位无关）
        //
        // 注：旧 hash 与新 hash 算法不同，存量缓存会一次性"看似失效"。这是一次性升级代价；
        // 之后该 repo 重新生成一次即可永久稳定，不会再因为 stars 涨一颗就失效。
        // 元数据块——单独抽出，给 Summary `{metadata}` 与 Tags `{metadata}` 占位符
        // 共用注入；Source.text 字段也用它做 hash 输入快照（README 头由 prompt 模板
        // 自带，不在 metadata 块里，占位符仅渲染纯数据）。
        let metadataBlock = [
            "Repository: \(repo.fullName)",
            "Description: \(repo.description ?? "")",
            "Language: \(repo.language ?? "")",
            "Topics: \(repo.topics ?? "")",
            "License: \(repo.license ?? "")",
            "Stars: \(repo.starsCount)",
            "Forks: \(repo.forksCount)",
            "Homepage: \(repo.homepage ?? "")"
        ].joined(separator: "\n")

        // hashText 元数据子集（剔除 stars/forks/homepage 这类高频流量字段）
        // —— HOM-199 缓存稳定化保留逻辑。
        let metadataHashBlock = [
            "Repository: \(repo.fullName)",
            "Description: \(repo.description ?? "")",
            "Language: \(repo.language ?? "")",
            "Topics: \(repo.topics ?? "")",
            "License: \(repo.license ?? "")"
        ].joined(separator: "\n")

        var llmText = metadataBlock + "\nREADME:\n" + readmeText
        var hashText = metadataHashBlock + "\nREADME:\n" + readmeText

        // X4（2026-06-13）：注入 RepoContextPacker 产出的代码上下文 XML（若 provider 可用）。
        //
        // 设计要点：
        //   - 始终拼到 source 末尾（README 之后）：让 LLM 先理解仓库定位（README）再看代码结构，
        //     与 RepoContextPacker XML 输出的 `<repository>` 根标签语义对齐；
        //   - 拼接整段原始 XML 而不是 marker / placeholder：LLM 直接消费 XML，无需 service 端
        //     做"摘要再摘要"；
        //   - **xml 内容直接消费 `result.xml`**：2026-06-14 silent failure 修复后，xml 已在
        //     provider 内部的 security scope 内通过 `RepoContextStorage.loadContextXml(...)`
        //     读好，service 不再做任何文件 IO。这一改动根除了"用户把 RepoContext 输出根目录
        //     改成自选文件夹时，service 在 scope 外 `String(contentsOf:)` 必失败、被 `try?`
        //     吞成 nil、contextMeta 永远 nil 的 silent failure"（dong4j 反馈
        //     addyosmani/agent-skills 案例）。
        //
        // Y2：同时把 PackMetadata 投影成 RepoAIInsightContextMeta 透传出去，让上层 UI footer 用。
        // Y4：按 provider outcome 3 态分别处理（success / featureDisabled / degraded）。
        var contextMeta: RepoAIInsightContextMeta?
        var degradationReason: ContextDegradationReason?
        var codeContextXml = ""
        if let provider = repoAIContextProvider {
            let outcome = try await provider.contextOutcome(for: repo)
            switch outcome {
            case .success(let result):
                // 代码上下文 XML 既给 LLM 用又进 hash：commit SHA 改 = 代码语义改
                // = 该重生成摘要。这是"语义级变更"，不属于 HOM-199 要稳定化的流量字段。
                llmText += "\n\n" + result.xml
                hashText += "\n\n" + result.xml
                codeContextXml = result.xml
                contextMeta = RepoAIInsightContextMeta(
                    commitSha: result.metadata.commitSha,
                    ref: result.metadata.ref,
                    tokenBudget: result.metadata.tokenBudget,
                    actualTokens: result.metadata.stats.actualTokens,
                    totalFiles: result.metadata.stats.totalFiles,
                    generatedAt: result.metadata.generatedAt
                )
            case .featureDisabled:
                // 用户主动关：不显示 banner，degradationReason 留 nil
                break
            case .degraded(let reason):
                // 失败：摘要照常生成（README-only），banner 让用户知道为什么没用代码
                degradationReason = reason
            }
        }

        return Source(
            text: llmText,
            hash: Self.hash(hashText),
            metadata: metadataBlock,
            readme: readmeText,
            codeContext: codeContextXml,
            contextMeta: contextMeta,
            contextDegradationReason: degradationReason
        )
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
        generatedAt: String,
        contextMeta: RepoAIInsightContextMeta? = nil
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
            generatedAt: generatedAt,
            contextMetadata: contextMeta
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

    // 2026-06-12：原 `stripHTML(_:)` 已被 `ReadmePreprocessor.process(html:)` 取代。
    // 旧实现还有 `<style>` / `<script>` / 标签剔除 + 实体解码 + 空白压缩，但与向量化路径
    // 的逻辑碎成两份。新设计单一职责，避免后续两边维护漂移。

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
