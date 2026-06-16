//
//  SemanticSearchService.swift
//  Starcat
//
//  AI 语义搜索服务（详见 `docs/详细设计/26-向量搜索改进.md`）。
//
//  模块职责：
//  - 把 repo 元数据 / README / AI 摘要 / 用户笔记拼成 `IndexedSnapshot`，调用 embedding API
//    向量化后落 SQLite；
//  - 搜索时只生成 query 向量；repo 向量缺失或 diff 超阈值时按批补索引；
//  - 用 cosine similarity 在 Swift 内存里排名（不依赖 sqlite-vss / vec 扩展）。
//
//  关键约束：
//  - 当前 MVP 用 SQLite BLOB + Swift cosine，不依赖动态扩展（macOS 沙盒签名约束）；
//  - AI 只参与语义排序，不自动改用户标签 / 笔记 / 状态；
//  - "要不要重建向量"由 `IndexedTextDiff.shouldRebuild` 决定，**不再**走旧的 `content_hash`
//    全等比对——避免 stars / forks 等高频字段误触发；
//  - `refreshIndex(for:)` = 强制重建路径（force=true，跳过 diff），UI 手动按钮 / 全量重建用；
//  - `refreshIndexIfChanged(for:)` = 单 repo 路径，供 README 加载完毕 / AI 摘要生成 /
//    用户笔记保存等触发。debounce / 节流由调用方负责。
//

import Foundation

struct SemanticSearchHit: Equatable, Sendable {
    let repo: Repo
    /// 原始 cosine similarity，[-1, 1]，文本 embedding 实际范围 ~[0.3, 0.95]。
    /// 仅作调试 / 测试参考；UI 展示与阈值过滤都走 `displayScore`。
    let score: Double
    /// A 重标定后的展示分（2026-06-14 dong4j 改造）：
    /// 经验区间 `[0.30, 0.95]` 线性归一到 `[0, 1]`，再叠加 B 字面命中 boost
    /// （fullName/description/topics 包含 query → 强制 ≥ 0.95）。
    /// **HomeViewModel 阈值过滤的判定字段就是它**——让设置页 75% 滑杆与列表 75% 数字
    /// 同语义。FTS hit 的 +0.15 boost 不计入 displayScore（FTS 命中是召回信号，
    /// 不是相似度本身），只在排序阶段生效。
    let displayScore: Double
    /// 视觉档位 1-4（★1 / ★2 / ★3 / ★4）。
    /// 由 `displayScore` 映射：≥0.85→4，≥0.65→3，≥0.45→2，其余→1。
    /// 给 UI "高/中/低" 视觉强度提示用，避免精确数字带来的过度解读。
    let tier: Int
    let reason: String
}

enum SemanticSearchError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case noVectors

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "ai.semanticSearch.error.missingAPIKey")
        case .noVectors:
            return String(localized: "ai.semanticSearch.error.noVectors")
        }
    }
}

@MainActor
final class SemanticSearchService {

    private let embeddingRepository: any RepoEmbeddingRepositoryProtocol
    private let readmeRepository: ReadmeRepository?
    private let noteRepository: (any RepoNoteRepositoryProtocol)?
    private let summaryRepository: (any AISummaryRepositoryProtocol)?
    private let settings: AppSettings
    private let keychain: any KeychainManaging
    private let batchSize: Int

    init(
        embeddingRepository: any RepoEmbeddingRepositoryProtocol,
        settings: AppSettings,
        readmeRepository: ReadmeRepository? = nil,
        noteRepository: (any RepoNoteRepositoryProtocol)? = nil,
        summaryRepository: (any AISummaryRepositoryProtocol)? = nil,
        keychain: any KeychainManaging = KeychainManager.shared,
        batchSize: Int = 32
    ) {
        self.embeddingRepository = embeddingRepository
        self.readmeRepository = readmeRepository
        self.noteRepository = noteRepository
        self.summaryRepository = summaryRepository
        self.settings = settings
        self.keychain = keychain
        self.batchSize = batchSize
    }

    /// 对传入候选 repo 做语义搜索（2026-06-14 A+B+C 改造）。
    ///
    /// 候选集由 HomeViewModel 决定：当前实现对全量 starred repos 搜索，再叠加列表过滤。
    /// 这样与原 FTS 搜索保持"全局搜索"语义一致，而不是只在当前 sidebar 分类内搜。
    ///
    /// **召回与排序信号**（短 query × 长 doc 的稀释问题修补）：
    /// - **A 显示层重标定**：原始 cosine 经验区间 `[0.30, 0.95]` 归一到 `[0, 1]`，
    ///   解决"完全无关 ≈ 0.30 / 完全相关 ≈ 0.95" 的 cosine 在文本 embedding 模型下
    ///   实际值域偏移问题。同时计算 1-4 档视觉 tier。
    /// - **B 字面命中 boost**：query 完整出现在 `fullName / description / topics` 时，
    ///   `effectiveScore = max(cosine, 0.95)`。"用户复制 description 都才 68%" 的
    ///   核心 case 被这条短路修复——字面命中直接置顶。
    /// - **C FTS hit 加权**：`ftsHitIDs` 内的 repo 排序分 +0.15。FTS 命中是召回信号，
    ///   不是相似度本身——所以**只影响排序，不影响 `displayScore` / `tier`**。
    ///   思路 1（boost 而非过滤）保住"语义同义但字面没匹"的召回能力。
    ///
    /// - Parameters:
    ///   - query: 用户原文。
    ///   - candidates: 候选 repo 集合（通常是当前用户全量 starred）。
    ///   - ftsHitIDs: FTS5 命中的 repo ID 集合，由 caller 在调用前先跑 FTS 拿到。
    ///     传空集 = 不启用 C 加权（仅 A+B 生效）。
    ///   - limit: 最多返回多少条。
    func search(
        query: String,
        candidates: [Repo],
        ftsHitIDs: Set<Int64> = [],
        limit: Int = 80
    ) async throws -> [SemanticSearchHit] {
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

        // 用 (hit, sortScore) 元组临时承载排序分；最终输出只暴露 hit。
        let scored: [(hit: SemanticSearchHit, sortScore: Double)] = candidates.compactMap { repo in
            guard let row = stored[repo.id] else { return nil }
            let vector = row.vector
            guard !vector.isEmpty, vector.count == queryVector.count else { return nil }
            let cosine = Self.cosineSimilarity(queryVector, vector)
            guard cosine.isFinite else { return nil }

            // B：字面命中 boost。effectiveScore 用于 displayScore 计算 + 排序基础。
            let literalHit = Self.hasLiteralMatch(repo: repo, query: trimmed)
            let effectiveScore = literalHit ? max(cosine, Self.literalBoostFloor) : cosine

            // C：FTS hit 仅给排序加权，不影响 displayScore（FTS 是召回信号不是相似度）。
            let ftsBoost: Double = ftsHitIDs.contains(repo.id) ? Self.ftsBoostWeight : 0
            let sortScore = effectiveScore + ftsBoost

            // A：经验区间归一到 [0, 1]。
            let displayScore = Self.normalizeDisplayScore(effectiveScore)
            let tier = Self.tier(forDisplayScore: displayScore)

            let hit = SemanticSearchHit(
                repo: repo,
                score: cosine,
                displayScore: displayScore,
                tier: tier,
                reason: Self.reason(
                    for: repo,
                    query: trimmed,
                    displayScore: displayScore,
                    literalHit: literalHit,
                    ftsHit: ftsHitIDs.contains(repo.id)
                )
            )
            return (hit, sortScore)
        }

        return Array(scored.sorted { $0.sortScore > $1.sortScore }.prefix(limit).map(\.hit))
    }

    /// 强制刷新一批 repo 的向量索引（force=true 路径）。
    ///
    /// UI 工具栏的"重建索引"按钮 + 设置页"全量重建" 调这里；搜索时缺失索引也会走
    /// `ensureIndexed(force: false)` 自动补缺，但走 diff 短路。
    ///
    /// **返回值（2026-06-13 dong4j 反馈"开始预拉闪烁"改造）**：实际调用 embedding
    /// API 重新写入的 repo 数。`force=true` 路径下通常等于 `repos.count`；空入参 = 0。
    /// `@discardableResult` 让既有 callsite 无需修改（HomeViewModel 等只关心异常）。
    @discardableResult
    func refreshIndex(for repos: [Repo]) async throws -> Int {
        guard !repos.isEmpty else { return 0 }
        let (client, model) = try makeClient(task: settings.aiEmbeddingTask)
        return try await ensureIndexed(repos, model: model, client: client, force: true)
    }

    /// 单 repo 按 diff 阈值判定后**有需要**才重建。
    ///
    /// 触发时机：
    /// - `RepoAIInsightService.generateInsight` 摘要生成成功后；
    /// - `RepoNotesSectionViewModel` 笔记 upsert 成功后（已带 1.5s debounce）；
    /// - 后台 `SemanticIndexBuilder` 补完 README Markdown 后。
    ///
    /// 不抛 missingAPIKey：未配置 Provider 时静默 no-op，避免每次保存笔记都弹错误。
    ///
    /// **返回值（2026-06-13 dong4j 反馈"开始预拉闪烁"改造）**：
    /// - `true`：实际调用 embedding API 重建了向量；
    /// - `false`：被 diff 阈值跳过、缺 API Key 静默 no-op、或重建抛错。
    ///
    /// `SemanticIndexBuilder` 用它统计 `skipped` 计数，完成时判定"是否全部跳过"
    /// 切到 `.alreadyUpToDate` 状态显示"已是最新"绿色徽章。其它 callsite
    /// （摘要回调 / 笔记保存 / README backfill）不关心结果，靠 `@discardableResult` 静默。
    @discardableResult
    func refreshIndexIfChanged(for repo: Repo) async -> Bool {
        do {
            let (client, model) = try makeClient(task: settings.aiEmbeddingTask)
            let rebuilt = try await ensureIndexed([repo], model: model, client: client)
            return rebuilt > 0
        } catch SemanticSearchError.missingAPIKey {
            // 静默：用户没配 AI，不打扰
            return false
        } catch {
            AppLog.ai.error("refreshIndexIfChanged failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
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

    /// 核心：确保 `repos` 的向量索引存在且最新。
    ///
    /// force=false：先取本地 snapshot，用 `IndexedTextDiff.shouldRebuild` 判定是否真的要重建；
    /// force=true：跳过 diff，每个 repo 都重新拼 snapshot + 调 embedding。
    ///
    /// **返回值**：实际向 embedding API 提交并 upsert 的 repo 数（= `workItems.count`）。
    /// 给上层 `refreshIndex` / `refreshIndexIfChanged` 报告"真的重建了几条"，让
    /// `SemanticIndexBuilder` 可以区分"全部跳过（已是最新）"和"实际重建"两种完成态。
    /// `search()` 路径不关心该计数，靠 `@discardableResult` 静默忽略。
    @discardableResult
    private func ensureIndexed(
        _ repos: [Repo],
        model: String,
        client: any AIClientProtocol,
        force: Bool = false
    ) async throws -> Int {
        guard !repos.isEmpty else { return 0 }

        // 取本地已有 embedding（用于 diff 比对）
        let existing = try await embeddingRepository.fetchEmbeddingsByRepoID(
            model: model,
            repoIDs: repos.map(\.id)
        )

        // 为每个 repo 拼出 new snapshot；待重建的进 missingOrStale
        let thresholds = settings.aiIndexThresholds
        let truncateLen = settings.aiReadmeTruncateLength

        struct WorkItem {
            let repo: Repo
            let snapshot: IndexedSnapshot
            let renderedText: String
        }
        var workItems: [WorkItem] = []
        workItems.reserveCapacity(repos.count)

        // 用户在 Settings 编辑过的 embedding template（默认值见 AIDefaultPrompts.embedding）。
        // template 是用户层面可改的，每次重建索引都拿当前最新值。
        let embeddingTemplate = settings.aiEmbeddingTask.prompt.userPromptTemplate

        for repo in repos {
            let snapshot = await buildSnapshot(for: repo, truncateLength: truncateLen)
            let renderedText = IndexedTextBuilder.render(
                snapshot: snapshot,
                userPromptTemplate: embeddingTemplate
            )

            if !force, let row = existing[repo.id] {
                let oldSnapshot = (try? IndexedSnapshot.decode(json: row.snapshotJson))
                if !IndexedTextDiff.shouldRebuild(
                    old: oldSnapshot,
                    new: snapshot,
                    thresholds: thresholds
                ) {
                    continue
                }
            }
            workItems.append(WorkItem(repo: repo, snapshot: snapshot, renderedText: renderedText))
        }
        guard !workItems.isEmpty else { return 0 }

        // 分批调 embedding API
        for chunk in workItems.chunked(into: batchSize) {
            let vectors = try await client.embeddings(inputs: chunk.map(\.renderedText), model: model)
            let now = ISO8601DateFormatter.shared.string(from: Date())
            let rows = try zip(chunk, vectors).map { item, vector -> RepoEmbedding in
                let json = try item.snapshot.encodedJSONString()
                return RepoEmbedding(
                    repoId: item.repo.id,
                    model: model,
                    vector: vector,
                    snapshotJson: json,
                    updatedAt: now
                )
            }
            try await embeddingRepository.upsert(rows)
        }
        return workItems.count
    }

    /// 拼接单个 repo 的 `IndexedSnapshot`：从 readme / summary / note repository 取数据，
    /// 经过 `ReadmePreprocessor` 清洗 / 截断，再交给 `IndexedTextBuilder`。
    ///
    /// **README 取数策略**：优先用 `readmes.content`（raw markdown，决策 E3）；为空回退
    /// `rendered_html`（HTML 路径，决策 A3 的 stripHTML 兜底）。两者都没有 → readmePlainText = nil，
    /// `IndexedTextBuilder.chooseBody` 走 description+topics 兜底。
    private func buildSnapshot(for repo: Repo, truncateLength: Int) async -> IndexedSnapshot {
        let readme = await loadReadmeText(repoId: repo.id, truncateLength: truncateLength)
        let summary = await loadAISummaryText(repoId: repo.id)
        let note = await loadNoteText(repoId: repo.id)
        return IndexedTextBuilder.buildSnapshot(
            repo: repo,
            readmePlainText: readme,
            aiSummary: summary,
            noteContent: note
        )
    }

    private func loadReadmeText(repoId: Int64, truncateLength: Int) async -> String? {
        guard let readmeRepo = readmeRepository else { return nil }
        do {
            // HOM-201 P2-2:content 拆到独立表 readme_contents,显式调 findContent;
            // 默认 find 只回 html 元数据,避免列表 / 详情场景拉冗余 markdown body。
            if let content = try await readmeRepo.findContent(repoId: repoId),
               !content.isEmpty {
                return ReadmePreprocessor.process(markdown: content, maxLength: truncateLength)
            }
            // markdown 没 backfill 时回退用 HTML(WebView 主路径仍有 rendered_html)
            guard let readme = try await readmeRepo.find(repoId: repoId) else { return nil }
            if let html = readme.renderedHtml, !html.isEmpty {
                return ReadmePreprocessor.process(html: html, maxLength: truncateLength)
            }
            return nil
        } catch {
            AppLog.ai.error("loadReadmeText failed for \(repoId): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func loadAISummaryText(repoId: Int64) async -> String? {
        guard let summaryRepo = summaryRepository else { return nil }
        do {
            let records = try await summaryRepo.fetchLatestPerRepo()
            guard let record = records[repoId] else { return nil }
            // summary_json 是 RepoAIInsight 编码：优先用 summaryMarkdown，回退 summary 旧字段
            let insight = try? RepoAIInsightService.decodeInsight(json: record.summaryJson)
            let text = insight?.summaryMarkdown?.nilIfBlank
                ?? insight?.summary.nilIfBlank
            return text
        } catch {
            AppLog.ai.error("loadAISummaryText failed for \(repoId): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func loadNoteText(repoId: Int64) async -> String? {
        guard let noteRepo = noteRepository else { return nil }
        do {
            guard let note = try await noteRepo.find(repoId: repoId),
                  let content = note.content?.nilIfBlank else { return nil }
            return content
        } catch {
            AppLog.ai.error("loadNoteText failed for \(repoId): \(error.localizedDescription, privacy: .public)")
            return nil
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

    // MARK: - A+B+C 排序信号常量与纯函数

    /// A 经验区间锚定下界。文本 embedding 模型（OpenAI / BGE / GTE 等）实测：
    /// 完全无关文本 cosine 普遍在 0.30~0.50，远高于 0；以 0.30 为下界让"完全无关"映射到 0%。
    nonisolated static let displayScoreLowAnchor: Double = 0.30
    /// A 经验区间锚定上界。同一字符串的 embedding cosine 也很少到 1.0，多在 0.95~0.99；
    /// 以 0.95 为上界让"高度相关"映射到 100%。
    nonisolated static let displayScoreHighAnchor: Double = 0.95

    /// B 字面命中 boost 阈值。effectiveScore = max(cosine, literalBoostFloor)。
    /// 0.95 是经验值：字面命中的 repo 至少和"高度相关"同档，避免出现"我搜的词就在 description
    /// 里，但相似度才 60%" 的反直觉体验。
    nonisolated static let literalBoostFloor: Double = 0.95

    /// C FTS hit 排序加权系数。固定加在 sortScore 上（非 displayScore）。
    /// 0.15 ≈ 经验区间跨度（0.65）的 23%，足以让 FTS 命中越过 1-2 档非命中候选，
    /// 但不至于完全压过明显更高的语义相关。
    nonisolated static let ftsBoostWeight: Double = 0.15

    /// 把 effectiveScore（cosine 或 literal boost 后的值）线性映射到 [0, 1]。
    /// 超出锚定区间的输入做 clamp，保证返回值范围稳定。
    nonisolated static func normalizeDisplayScore(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        let span = displayScoreHighAnchor - displayScoreLowAnchor
        let normalized = (raw - displayScoreLowAnchor) / span
        return max(0, min(1, normalized))
    }

    /// 把 displayScore 映射到 1-4 档视觉档位：
    /// - 4★：≥ 0.85（高度相关）
    /// - 3★：≥ 0.65
    /// - 2★：≥ 0.45
    /// - 1★：其余
    /// 档位边界刻意用比 displayScore 阈值（0.75）更细的分布，让用户在 0.45~0.85
    /// 区间也能看到视觉差异。
    nonisolated static func tier(forDisplayScore score: Double) -> Int {
        if score >= 0.85 { return 4 }
        if score >= 0.65 { return 3 }
        if score >= 0.45 { return 2 }
        return 1
    }

    /// 判定 query 字符串是否字面出现在 repo 的 fullName / description / topics 任一字段。
    /// 用 `localizedLowercase + contains` 做大小写不敏感子串匹配；不做分词、不做正则。
    nonisolated static func hasLiteralMatch(repo: Repo, query: String) -> Bool {
        let lowerQuery = query.localizedLowercase
        if repo.fullName.localizedLowercase.contains(lowerQuery) { return true }
        if let description = repo.description, description.localizedLowercase.contains(lowerQuery) { return true }
        if let topics = repo.topics, topics.localizedLowercase.contains(lowerQuery) { return true }
        return false
    }

    /// 生成展示用的命中原因文案。
    /// 用 displayScore 而非原始 cosine 作为百分数显示，与 UI 阈值滑杆同语义。
    private static func reason(
        for repo: Repo,
        query: String,
        displayScore: Double,
        literalHit: Bool,
        ftsHit: Bool
    ) -> String {
        let scoreText = "\(Int((max(0, min(displayScore, 1)) * 100).rounded()))%"
        let lowerQuery = query.localizedLowercase
        if repo.fullName.localizedLowercase.contains(lowerQuery) {
            return String(format: String(localized: "ai.semanticSearch.reason.nameMatchFormat"), scoreText)
        }
        if let description = repo.description, description.localizedLowercase.contains(lowerQuery) {
            return String(format: String(localized: "ai.semanticSearch.reason.descriptionMatchFormat"), scoreText)
        }
        if let topics = repo.topics, topics.localizedLowercase.contains(lowerQuery) {
            return String(format: String(localized: "ai.semanticSearch.reason.topicsMatchFormat"), scoreText)
        }
        if ftsHit {
            return String(format: String(localized: "ai.semanticSearch.reason.notesMatchFormat"), scoreText)
        }
        // literalHit == false && ftsHit == false：纯语义召回
        _ = literalHit
        return String(format: String(localized: "ai.semanticSearch.reason.vectorOnlyFormat"), scoreText)
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
