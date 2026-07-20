//
//  StarcatMCPModels.swift
//  Starcat
//
//  MCP Service 对外返回的数据模型。
//
//  这些 DTO 是 Starcat 内部数据库模型与 MCP structuredContent 之间的边界：
//  - 不直接把 GRDB Record 暴露给 agent，避免把未来内部字段改名变成外部协议破坏；
//  - 字段保持 snake_case，方便非 Swift agent 直接消费；
//  - 只包含只读上下文，写入类能力后续单独设计审批 / audit。
//

import Foundation

/// MCP 对外暴露的 repo 摘要。
struct MCPRepoDTO: Codable, Sendable {
    let id: Int64
    let owner: String
    let name: String
    let full_name: String
    let description: String?
    let language: String?
    let stars_count: Int
    let forks_count: Int
    let watchers_count: Int
    let topics: [String]
    let license: String?
    let homepage: String?
    let html_url: String
    let clone_url: String?
    let ssh_url: String?
    let is_private: Bool
    let is_fork: Bool
    let is_archived: Bool
    let is_starred: Bool
    let pushed_at: String?
    let created_at: String?
    let updated_at: String?
    let starred_at: String?
    let cached_at: String?
    let owner_avatar: String?
    let subscribers_count: Int?
    let default_branch: String?
    let open_issues_count: Int?

    init(repo: Repo) {
        self.id = repo.id
        self.owner = repo.owner
        self.name = repo.name
        self.full_name = repo.fullName
        self.description = repo.description
        self.language = repo.language
        self.stars_count = repo.starsCount
        self.forks_count = repo.forksCount
        self.watchers_count = repo.watchersCount
        self.topics = repo.topicsArray
        self.license = repo.license
        self.homepage = repo.homepage
        self.html_url = repo.htmlUrl
        self.clone_url = repo.cloneUrl
        self.ssh_url = repo.sshUrl
        self.is_private = repo.isPrivate
        self.is_fork = repo.isFork
        self.is_archived = repo.isArchived
        self.is_starred = repo.isStarred
        self.pushed_at = repo.pushedAt
        self.created_at = repo.createdAt
        self.updated_at = repo.updatedAt
        self.starred_at = repo.starredAt
        self.cached_at = repo.cachedAt
        self.owner_avatar = repo.ownerAvatar
        self.subscribers_count = repo.subscribersCount
        self.default_branch = repo.defaultBranch
        self.open_issues_count = repo.openIssuesCount
    }
}

/// MCP 搜索结果。
struct MCPRepoSearchResult: Codable, Sendable {
    let query: String?
    let total: Int
    let limit: Int
    let repos: [MCPRepoDTO]
}

/// MCP 语义搜索结果。
struct MCPSemanticSearchResult: Codable, Sendable {
    struct Hit: Codable, Sendable {
        let repo: MCPRepoDTO
        let score: Double
        let display_score: Double
        let tier: Int
        let reason: String

        init(hit: SemanticSearchHit) {
            self.repo = MCPRepoDTO(repo: hit.repo)
            self.score = hit.score
            self.display_score = hit.displayScore
            self.tier = hit.tier
            self.reason = hit.reason
        }
    }

    let query: String
    let total: Int
    let limit: Int
    let hits: [Hit]
}

/// MCP README 读取结果。
struct MCPReadmeResult: Codable, Sendable {
    let repo: MCPRepoDTO
    let rendered_html: String?
    let markdown: String?
    let cached_at: String?
    let etag: String?
    let last_modified: String?
}

/// MCP 标签 DTO。
struct MCPTagDTO: Codable, Sendable {
    let id: String
    let name: String
    let color: String?
    let icon: String?
    let sort_order: Int
    let is_preset: Bool
    let parent_id: String?
    let created_at: String
    let updated_at: String

    init(tag: Tag) {
        self.id = tag.id
        self.name = tag.name
        self.color = tag.color
        self.icon = tag.icon
        self.sort_order = tag.sortOrder
        self.is_preset = tag.isPreset
        self.parent_id = tag.parentId
        self.created_at = tag.createdAt
        self.updated_at = tag.updatedAt
    }
}

/// MCP 私有笔记 DTO。只在用户显式开启 `mcpExposePrivateNotes` 后返回。
struct MCPRepoNoteDTO: Codable, Sendable {
    let repo_id: Int64
    let content: String?
    let status: String
    let is_ai_generated: Bool
    let edited_at: String?

    init(note: RepoNote) {
        self.repo_id = note.repoId
        self.content = note.content
        self.status = note.status
        self.is_ai_generated = note.isAIGenerated
        self.edited_at = note.editedAt
    }
}

/// MCP 对外暴露的缓存 AI 摘要。
///
/// 不直接编码完整 `RepoAIInsight`，避免外部 Agent 依赖内部 UI、External Search 或
/// RepoContext 诊断字段。这里仅保留稳定的正文、模型与生成时间契约。
struct MCPRepoSummaryDTO: Codable, Sendable {
    let repo_id: Int64
    let one_liner: String
    let summary_markdown: String
    let model: String
    let generated_at: String

    init(repoID: Int64, insight: RepoAIInsight) {
        self.repo_id = repoID
        self.one_liner = insight.oneLiner
        self.summary_markdown = insight.summaryMarkdown ?? insight.summary
        self.model = insight.model
        self.generated_at = insight.generatedAt
    }
}

/// Agent 一次读取单仓上下文的聚合结果。
///
/// 私有笔记关闭时返回 `private_notes_exposed = false` 和 `note = nil`，而不是让整个
/// context 请求失败；这样 Agent 仍能读取 repo、标签和摘要，同时明确知道缺失原因。
struct MCPRepoContextDTO: Codable, Sendable {
    let repo: MCPRepoDTO
    let tags: [MCPTagDTO]
    let private_notes_exposed: Bool
    let note: MCPRepoNoteDTO?
    let summary: MCPRepoSummaryDTO?
}

/// MCP 当前能力快照。只暴露权限状态，不包含 Local API Key 或其它凭据。
struct MCPCapabilitiesDTO: Codable, Sendable {
    let server_version: String
    let loopback_only: Bool
    let private_notes_read: Bool
    let statistics_read: Bool
    let local_writes: Bool
    let batch_writes: Bool
    let destructive_writes: Bool
    let ai_summary_generation: Bool
}

/// MCP 统计接口使用的稳定名称/数量结构，不把 RAG 内部快照类型直接暴露给外部 Agent。
struct MCPNamedCountDTO: Codable, Sendable {
    let name: String
    let count: Int
}

/// AI 用量汇总。`calls_with_usage` 单独存在，避免 Provider 未返回 usage 时被误判为零消耗。
struct MCPAIUsageSummaryDTO: Codable, Sendable {
    let total_tokens: Int
    let input_tokens: Int
    let output_tokens: Int
    let call_count: Int
    let successful_call_count: Int
    let calls_with_usage: Int
    let embedding_item_count: Int
    let success_rate: Double
    let usage_availability_rate: Double

    init(summary: AIUsageSummary) {
        total_tokens = summary.totalTokens
        input_tokens = summary.inputTokens
        output_tokens = summary.outputTokens
        call_count = summary.callCount
        successful_call_count = summary.successfulCallCount
        calls_with_usage = summary.callsWithUsage
        embedding_item_count = summary.embeddingItemCount
        success_rate = summary.successRate
        usage_availability_rate = summary.usageAvailabilityRate
    }
}

struct MCPAIUsageDimensionDTO: Codable, Sendable {
    let key: String
    let input_tokens: Int
    let output_tokens: Int
    let total_tokens: Int
    let call_count: Int

    init(point: AIUsageDimensionPoint) {
        key = point.key
        input_tokens = point.inputTokens
        output_tokens = point.outputTokens
        total_tokens = point.totalTokens
        call_count = point.callCount
    }
}

struct MCPAIUsageDailyDTO: Codable, Sendable {
    let day: String
    let input_tokens: Int
    let output_tokens: Int
    let total_tokens: Int
    let call_count: Int

    init(point: AIUsageDailyPoint) {
        day = point.day
        input_tokens = point.inputTokens
        output_tokens = point.outputTokens
        total_tokens = point.totalTokens
        call_count = point.callCount
    }
}

/// Agent 可筛选的 AI 用量统计，不返回原始调用事件、Prompt、回复或错误正文。
struct MCPAIUsageStatisticsDTO: Codable, Sendable {
    let generated_at: String
    let time_range: String
    let feature: String?
    let provider_id: String?
    let model: String?
    let summary: MCPAIUsageSummaryDTO
    let daily: [MCPAIUsageDailyDTO]
    let by_feature: [MCPAIUsageDimensionDTO]
    let by_provider: [MCPAIUsageDimensionDTO]
    let by_model: [MCPAIUsageDimensionDTO]

    init(filter: AIUsageFilter, snapshot: AIUsageStatisticsSnapshot, generatedAt: Date = Date()) {
        generated_at = ISO8601DateFormatter.shared.string(from: generatedAt)
        time_range = filter.timeRange.rawValue
        feature = filter.feature?.rawValue
        provider_id = filter.providerID
        model = filter.model
        summary = MCPAIUsageSummaryDTO(summary: snapshot.summary)
        daily = snapshot.daily.map(MCPAIUsageDailyDTO.init(point:))
        by_feature = snapshot.byFeature.map(MCPAIUsageDimensionDTO.init(point:))
        by_provider = snapshot.byProvider.map(MCPAIUsageDimensionDTO.init(point:))
        by_model = snapshot.byModel.map(MCPAIUsageDimensionDTO.init(point:))
    }
}

struct MCPRAGIndexHealthDTO: Codable, Sendable {
    let total_chunks: Int
    let ready_chunks: Int
    let keyword_only_chunks: Int
    let pending_chunks: Int
    let failed_chunks: Int
    let stale_chunks: Int
    let embedding_model: String

    init(health: KnowledgeBaseMetadataSnapshot.IndexHealth) {
        total_chunks = health.totalChunks
        ready_chunks = health.readyChunks
        keyword_only_chunks = health.keywordOnlyChunks
        pending_chunks = health.pendingChunks
        failed_chunks = health.failedChunks
        stale_chunks = health.staleChunks
        embedding_model = health.embeddingModel
    }
}

struct MCPRAGSourceCoverageDTO: Codable, Sendable {
    let source: String
    let repository_count: Int
    let chunk_count: Int
    let ready_chunk_count: Int
    let failed_chunk_count: Int
    let stale_chunk_count: Int

    init(coverage: KnowledgeBaseMetadataSnapshot.SourceIndexCoverage) {
        source = coverage.source.rawValue
        repository_count = coverage.repositoryCount
        chunk_count = coverage.chunkCount
        ready_chunk_count = coverage.readyChunkCount
        failed_chunk_count = coverage.failedChunkCount
        stale_chunk_count = coverage.staleChunkCount
    }
}

struct MCPTopRepositoryStatisticsDTO: Codable, Sendable {
    let repo_id: Int64
    let full_name: String
    let github_stars: Int

    init(repository: KnowledgeBaseMetadataSnapshot.TopRepository) {
        repo_id = repository.repoID
        full_name = repository.fullName
        github_stars = repository.stars
    }
}

/// 完整知识库统计。私有笔记相关数量只在用户允许 MCP 读取私有笔记时编码。
struct MCPKnowledgeBaseStatisticsDTO: Codable, Sendable {
    let generated_at: String
    let content_updated_at: String?
    let project_count: Int
    let starred_project_count: Int
    let retained_after_unstar_count: Int
    let starred_status_counts: [MCPNamedCountDTO]
    let status_counts: [MCPNamedCountDTO]
    let starred_tagged_project_count: Int
    let starred_untagged_project_count: Int
    let tagged_project_count: Int
    let untagged_project_count: Int
    let tag_count: Int
    let known_language_project_count: Int
    let unknown_language_project_count: Int
    let top_languages: [MCPNamedCountDTO]
    let top_tags: [MCPNamedCountDTO]
    let added_in_last_30_days_count: Int
    let pushed_in_last_30_days_count: Int
    let ai_summary_project_count: Int
    let private_notes_exposed: Bool
    let private_note_project_count: Int?
    let ai_generated_note_project_count: Int?
    let private_notes_edited_in_last_30_days_project_count: Int?
    let ai_summaries_generated_in_last_30_days_project_count: Int
    let source_index_coverage: [MCPRAGSourceCoverageDTO]
    let excluded_chunk_count: Int
    let without_readme_source_project_count: Int
    let without_indexable_source_project_count: Int
    let top_starred_repositories: [MCPTopRepositoryStatisticsDTO]
    let index_health: MCPRAGIndexHealthDTO

    init(snapshot: KnowledgeBaseMetadataSnapshot, privateNotesExposed: Bool) {
        generated_at = ISO8601DateFormatter.shared.string(from: snapshot.generatedAt)
        content_updated_at = snapshot.contentUpdatedAt.map { ISO8601DateFormatter.shared.string(from: $0) }
        project_count = snapshot.projectCount
        starred_project_count = snapshot.starredProjectCount
        retained_after_unstar_count = snapshot.retainedAfterUnstarCount
        starred_status_counts = snapshot.starredStatusCounts.map { .init(name: $0.name, count: $0.count) }
        status_counts = snapshot.statusCounts.map { .init(name: $0.name, count: $0.count) }
        starred_tagged_project_count = snapshot.starredTaggedProjectCount
        starred_untagged_project_count = snapshot.starredUntaggedProjectCount
        tagged_project_count = snapshot.taggedProjectCount
        untagged_project_count = snapshot.untaggedProjectCount
        tag_count = snapshot.tagCount
        known_language_project_count = snapshot.knownLanguageProjectCount
        unknown_language_project_count = snapshot.unknownLanguageProjectCount
        top_languages = snapshot.topLanguages.map { .init(name: $0.name, count: $0.count) }
        top_tags = snapshot.topTags.map { .init(name: $0.name, count: $0.count) }
        added_in_last_30_days_count = snapshot.addedInLast30DaysCount
        pushed_in_last_30_days_count = snapshot.pushedInLast30DaysCount
        ai_summary_project_count = snapshot.aiSummaryProjectCount
        private_notes_exposed = privateNotesExposed
        private_note_project_count = privateNotesExposed ? snapshot.privateNoteProjectCount : nil
        ai_generated_note_project_count = privateNotesExposed ? snapshot.aiGeneratedNoteProjectCount : nil
        private_notes_edited_in_last_30_days_project_count = privateNotesExposed
            ? snapshot.privateNotesEditedInLast30DaysProjectCount
            : nil
        ai_summaries_generated_in_last_30_days_project_count = snapshot.aiSummariesGeneratedInLast30DaysProjectCount
        source_index_coverage = snapshot.sourceIndexCoverage.map(MCPRAGSourceCoverageDTO.init(coverage:))
        excluded_chunk_count = snapshot.excludedChunkCount
        without_readme_source_project_count = snapshot.withoutReadmeSourceProjectCount
        without_indexable_source_project_count = snapshot.withoutIndexableSourceProjectCount
        top_starred_repositories = snapshot.topStarredRepositories.map(MCPTopRepositoryStatisticsDTO.init(repository:))
        index_health = MCPRAGIndexHealthDTO(health: snapshot.indexHealth)
    }
}

/// 常用数字的一次性紧凑快照，减少 Agent 回答概览问题时的多轮工具调用。
struct MCPOverviewStatisticsDTO: Codable, Sendable {
    let generated_at: String
    let starred_repository_count: Int
    let knowledge_base_project_count: Int
    let retained_after_unstar_count: Int
    let tag_count: Int
    let ai_usage_time_range: String
    let ai_usage: MCPAIUsageSummaryDTO
    let rag_index: MCPRAGIndexHealthDTO
    let excluded_chunk_count: Int
}

/// 摘要生成工具的稳定返回值。
struct MCPRepoSummaryGenerationResult: Codable, Sendable {
    let repo: MCPRepoDTO
    let summary: MCPRepoSummaryDTO
    let persisted: Bool
}
