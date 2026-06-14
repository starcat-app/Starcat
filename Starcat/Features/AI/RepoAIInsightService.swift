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
}

@MainActor
final class RepoAIInsightService {

    private struct Source {
        let text: String
        let hash: String
        /// Y2：从 RepoContextPacker 拿到的元信息（命中缓存或新生成都填充）。
        /// 透传到 makeInsight 写入 RepoAIInsight.contextMetadata，供 UI footer 显示。
        var contextMeta: RepoAIInsightContextMeta?

        /// Y4：本次 makeSource 阶段代码上下文降级原因（nil = 成功 或 用户关了开关）。
        /// 透传到 generateInsight 出参，UI 显示 banner。
        var contextDegradationReason: ContextDegradationReason?

        init(
            text: String,
            hash: String,
            contextMeta: RepoAIInsightContextMeta? = nil,
            contextDegradationReason: ContextDegradationReason? = nil
        ) {
            self.text = text
            self.hash = hash
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
    /// 与 `chatStream` / `makeClient` 中的解析顺序完全一致——优先用 `aiSummaryTask`
    /// 的 `resolvedModelName`，空则 fallback 到全局 `aiChatModel`。给"复制完整对话"
    /// 导出的 Markdown 末尾署名「由 X 生成」时使用。
    /// HOM-150 dong4j 2026-06-04 15:48 反馈："markdown 的最后应该加上由什么模型生成
    /// 的，就像 AI 摘要生成最后也添加了由什么模型生成的"。
    var resolvedChatModelName: String {
        settings.aiSummaryTask.resolvedModelName.nilIfBlank ?? settings.aiChatModel
    }

    func cachedInsight(for repo: Repo) async throws -> RepoAIInsight? {
        let source = try await makeSource(for: repo)
        guard let record = try await summaryRepository.find(repoId: repo.id, model: cacheModelKey()),
              record.sourceHash == source.hash
        else {
            return nil
        }
        return try Self.decodeInsight(json: record.summaryJson)
    }

    func generateInsight(
        for repo: Repo,
        existingTagHints: [String] = [],
        includeSummary: Bool = true,
        includeTags: Bool = true,
        allowExternalContext: Bool = true,
        onSummaryDelta: (@MainActor (String) -> Void)? = nil
    ) async throws -> RepoAIInsightGeneration {
        let source = try await makeSource(for: repo)
        let generatedAt = ISO8601DateFormatter.shared.string(from: Date())
        let resolvedExternalContext: AIExternalContext?
        if includeSummary, allowExternalContext {
            do {
                resolvedExternalContext = try await externalContextProvider.collect(for: repo)
            } catch {
                // 外部搜索是补充能力，失败不能阻断本地 README 摘要。
                AppLog.ai.error("AnySearch external context skipped: \(error.localizedDescription, privacy: .public)")
                resolvedExternalContext = nil
            }
        } else {
            resolvedExternalContext = nil
        }

        // HOM-52：标签生成路径在 source 末尾追加两段强制约束：
        //   (1) Tag format rules —— 限制中英文标签长度 / 风格，覆盖所有用户 prompt（含自定义）
        //   (2) Existing user tags —— 批量路径传入时引导 AI 优先复用
        //
        // 为何不写进 default prompt：用户可能已经在 Settings 改过 prompt（持久化在 UserDefaults），
        // 改 default 对老用户不生效。注入到 {context} 末尾走的是同一个 prompt template 替换路径，
        // 无论用户怎么改 system / user prompt 都会拿到这两段规则。
        // includeTags == false 时不注入，避免摘要任务的 prompt 被无关规则污染。
        let augmentedSource: Source = {
            guard includeTags else { return source }

            var appendix = """

            Tag format rules (必须遵守):
            - 中文标签：长度 ≤ 4 字（如「向量检索」「编辑器」「机器学习」），名词或简短术语，不要句子。
            - 英文标签：单个领域词、专业缩写或常见技术术语（如 RAG / LLM / Vector / DevOps / WebRTC / Editor），不要复合短语。
            - 中英文混用时每个标签独立判断；同一仓库的标签风格保持一致。
            """

            let trimmedHints = existingTagHints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(50)
            if !trimmedHints.isEmpty {
                appendix += """


                Existing user tags (优先复用，无法归类的才新增；避免标签数量爆炸):
                \(trimmedHints.joined(separator: ", "))
                """
            }

            let merged = source.text + appendix
            return Source(text: merged, hash: Self.hash(merged))
        }()

        // 两者都需要时并发跑（与原实现一致）；任一关闭则串行 / 短路，避免无意义 AI 调用。
        let summarySource: Source = {
            guard let context = resolvedExternalContext else { return augmentedSource }
            let merged = augmentedSource.text + "\n" + context.markdown
            return Source(text: merged, hash: Self.hash(merged))
        }()

        var summaryText: String
        let resolvedTagResult: Result<[AITagSuggestion], Error>
        if includeSummary, includeTags {
            async let tagResult = tagSuggestionsResult(source: augmentedSource)
            summaryText = try await generateSummary(source: summarySource, onDelta: onSummaryDelta)
            resolvedTagResult = await tagResult
        } else if includeSummary {
            summaryText = try await generateSummary(source: summarySource, onDelta: onSummaryDelta)
            resolvedTagResult = .success([])
        } else if includeTags {
            summaryText = ""
            resolvedTagResult = await tagSuggestionsResult(source: augmentedSource)
        } else {
            // 调用方两者都关：返回空 insight，避免无意义网络调用。
            summaryText = ""
            resolvedTagResult = .success([])
        }
        let suggestions = (try? resolvedTagResult.get()) ?? []
        if let context = resolvedExternalContext, !summaryText.isEmpty {
            let links = context.sources.map { "- [\($0.host ?? $0.absoluteString)](\($0.absoluteString))" }
            summaryText += "\n\n## 外部参考来源\n" + links.joined(separator: "\n")
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
            // 注：augmentedSource / summarySource 都从 source 派生但不改 contextDegradationReason，
            // 这里直接读最原始 source 的 reason 即可。
            contextDegradationReason: source.contextDegradationReason
        )
    }

    /// 与仓库对话（HOM-150）。
    ///
    /// 与 `generateInsight` 的区别：
    /// - 走"多轮 chat"路径：system prompt 注入 repo 元数据 + README，
    ///   `history` 承载之前的用户/助手轮次，本轮发的内容放 `userMessage`；
    /// - **强制流式**，忽略 `aiSummaryTask.parameters.streamEnabled`——
    ///   chat 体验对"打字机式增量出字"非常敏感，非流式整段返回会让窗口长时间空白；
    /// - **不写 SQLite 缓存**：对话上下文是临时的，下次打开窗口重新开始；持久化要等
    ///   后续真的有"历史会话回看"需求再设计表结构；
    /// - **不解析 JSON / 不限制结构**：模型可以自由用 Markdown 回答（含代码块）。
    ///
    /// 复用 `aiSummaryTask` 的 provider / model / 参数（temperature 0.2、maxToken 2048）。
    /// 后续若发现"摘要适合低温度、对话需要更高 temperature"，再独立 `aiChatTask` 配置。
    /// 同 `generateInsight` 一样，复用 `makeSource(for:)` 拼出的"repo 元数据 + README"
    /// 上下文，避免对 README WebView 缓存路径出现两份取数逻辑。
    func chatStream(
        for repo: Repo,
        history: [AIChatMessage],
        userMessage: String,
        onDelta: (@MainActor (String) -> Void)? = nil
    ) async throws -> String {
        let source = try await makeSource(for: repo)
        let task = settings.aiSummaryTask
        let (client, model) = try makeClient(task: task, fallbackModel: settings.aiChatModel, taskName: "对话")

        let systemPrompt = """
        You are Starcat's repository chat assistant.
        Reply in Simplified Chinese only.
        Stay grounded in the provided repository context (metadata + README).
        If a question cannot be answered from that context, say "未从 README 或仓库元数据中确认" — do not invent APIs, commands, links, or version numbers.
        Markdown is allowed (including fenced code blocks); keep replies focused on what the user asked, no padding.

        Repository context:
        \(source.text)
        """

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
                onDelta?(accumulated)
            case .completed(let response):
                return response.content
            }
        }
        // 部分服务端在 stream 结束时不发 `completed` 事件，只靠 chunk 累积。
        // 这里兜底用累积值；若仍为空才抛 emptyResponse。
        guard let final = accumulated.nilIfBlank else { throw AIClientError.emptyResponse }
        return final
    }

    private func tagSuggestionsResult(source: Source) async -> Result<[AITagSuggestion], Error> {
        do {
            return .success(try await generateTags(source: source))
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
        let request = AIChatRequest(
            systemPrompt: task.prompt.systemPrompt,
            userPrompt: task.prompt.renderedUserPrompt(context: source.text),
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

    private func generateTags(source: Source) async throws -> [AITagSuggestion] {
        let task = settings.aiTagsTask
        let (client, model) = try makeClient(task: task, fallbackModel: settings.aiChatModel, taskName: "推荐标签")
        let response = try await client.chat(request: AIChatRequest(
            systemPrompt: task.prompt.systemPrompt,
            userPrompt: task.prompt.renderedUserPrompt(context: source.text),
            model: model,
            parameters: settings.effectiveParameters(for: task),
            responseFormat: .jsonObject
        ))
        return try Self.decodeTagSuggestions(json: response.content)
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

    /// 拼出"喂 LLM 的 repo 上下文"——元数据 + 清洗后的 README。
    ///
    /// **2026-06-12 改造**（向量索引改进）：
    /// - README 清洗逻辑从本地 `Self.stripHTML` + 硬编码 12000 截断改为
    ///   `ReadmePreprocessor.process(html:/markdown:)`，与向量索引共用同一份规则；
    /// - 截断长度从 `AppSettings.aiReadmeTruncateLength` 读，让用户在 Settings 滑杆调整后
    ///   AI 摘要 / 向量化都同步生效；
    /// - 优先使用 `readmes.content`（raw markdown）：决策 E3 后台懒补全完成时直接用原文，
    ///   信息密度比 HTML 剥后高；fallback `rendered_html` 保留兼容。
    private func makeSource(for repo: Repo) async throws -> Source {
        let readme = try await readmeRepository.find(repoId: repo.id)
        let truncateLength = settings.aiReadmeTruncateLength
        let readmeText: String = {
            if let markdown = readme?.content, !markdown.isEmpty {
                return ReadmePreprocessor.process(markdown: markdown, maxLength: truncateLength)
            }
            if let html = readme?.renderedHtml, !html.isEmpty {
                return ReadmePreprocessor.process(html: html, maxLength: truncateLength)
            }
            return ""
        }()
        var source = [
            "Repository: \(repo.fullName)",
            "Description: \(repo.description ?? "")",
            "Language: \(repo.language ?? "")",
            "Topics: \(repo.topics ?? "")",
            "License: \(repo.license ?? "")",
            "Stars: \(repo.starsCount)",
            "Forks: \(repo.forksCount)",
            "Homepage: \(repo.homepage ?? "")",
            "README:",
            readmeText
        ].joined(separator: "\n")

        // X4（2026-06-13）：注入 RepoContextPacker 产出的代码上下文 XML（若 provider 可用）。
        //
        // 设计要点：
        //   - 始终拼到 source 末尾（README 之后）：让 LLM 先理解仓库定位（README）再看代码结构，
        //     与 RepoContextPacker XML 输出的 `<repository>` 根标签语义对齐；
        //   - 拼接整段原始 XML 而不是 marker / placeholder：LLM 直接消费 XML，无需 service 端
        //     做"摘要再摘要"；
        //   - **读 contextURL 时用 String(contentsOf:)** 而不是 streaming：context.xml 已经
        //     按 token budget 限过（默认 8000 tokens ≈ 32KB），一次读全无内存压力；
        //   - **任何失败都静默吞**：provider.context(for:) 已经把网络 / 磁盘 / pack 错误降级
        //     成 nil 了，这里只需再防御 String 读取本身失败（极少触发，比如文件刚被外部删）。
        //
        // Y2：同时把 PackMetadata 投影成 RepoAIInsightContextMeta 透传出去，让上层 UI footer 用。
        // Y4：按 provider outcome 3 态分别处理（success / featureDisabled / degraded）。
        var contextMeta: RepoAIInsightContextMeta?
        var degradationReason: ContextDegradationReason?
        if let provider = repoAIContextProvider {
            let outcome = try await provider.contextOutcome(for: repo)
            switch outcome {
            case .success(let result):
                if let contextXml = try? String(contentsOf: result.url, encoding: .utf8),
                   !contextXml.isEmpty {
                    source += "\n\n" + contextXml
                    contextMeta = RepoAIInsightContextMeta(
                        commitSha: result.metadata.commitSha,
                        ref: result.metadata.ref,
                        tokenBudget: result.metadata.tokenBudget,
                        actualTokens: result.metadata.stats.actualTokens,
                        totalFiles: result.metadata.stats.totalFiles,
                        generatedAt: result.metadata.generatedAt
                    )
                }
            case .featureDisabled:
                // 用户主动关：不显示 banner，degradationReason 留 nil
                break
            case .degraded(let reason):
                // 失败：摘要照常生成（README-only），banner 让用户知道为什么没用代码
                degradationReason = reason
            }
        }

        return Source(
            text: source,
            hash: Self.hash(source),
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
