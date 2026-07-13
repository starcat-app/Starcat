//
//  KnowledgeRAGModels.swift
//  Starcat
//
//  知识库 RAG 从输入框到检索、生成、引用的共享数据契约。
//
//  关键约束：AI Planner 只提出查询计划；知识库边界、@repo 显式范围、数值上限和
//  支持字段校验始终由本地执行层强制落实，不能把数据访问权限交给模型决定。
//

import Foundation

enum RAGExplicitRepoMode: String, Codable, Hashable, Sendable {
    case only
    case prefer
    case exclude
}

enum RAGAttachmentHandling: String, Codable, Sendable {
    case vision
    case textContext = "text_context"
    case unsupported
}

struct RAGComposerAttachment: Identifiable, Equatable, Sendable {
    var id: UUID
    var filename: String
    var contentType: String
    var sizeInBytes: Int64
    var localURL: URL
    var handling: RAGAttachmentHandling
}

enum RAGGitHubLinkRelation: String, Codable, Sendable {
    case inKnowledge = "in_knowledge"
    case knownButNotInKnowledge = "known_but_not_in_knowledge"
    case external
}

struct RAGGitHubLinkReference: Equatable, Sendable {
    var url: URL
    var owner: String
    var repo: String
    var matchedRepoID: Int64?
    var relation: RAGGitHubLinkRelation
}

struct RAGComposerContext: Equatable, Sendable {
    var explicitRepoIDs: [Int64] = []
    var explicitRepoMode: RAGExplicitRepoMode = .only
    var selectedModelID: String?
    var attachments: [RAGComposerAttachment] = []
    var pastedGitHubLinks: [RAGGitHubLinkReference] = []
    /// 用户可以在执行前移除 Planner 建议的远程上下文 chip。
    var disabledRemoteResources: Set<RAGRemoteContextResource> = []
}

struct RAGServiceRequest: Sendable {
    var rawQuestion: String
    var composerContext: RAGComposerContext
    var conversationID: UUID?
    /// 仅由 Debug 工作台开启；关闭时 Service 不构造或回传任何调试记录。
    var isDebugEnabled = false
    /// 仅用于调试面板标识实际调用的 provider endpoint，不参与网络请求构造。
    var debugEndpoint: String? = nil
    /// 问答 Trace 的统一起点。压缩发生在 `ask` 之前，必须沿用同一时钟，才能让调试面板
    /// 按真实先后计算每一步耗时；关闭 Debug 时保持 `nil`，不改变常规请求行为。
    var debugTraceStartedAt: Date? = nil
}

enum RAGQueryMode: String, Codable, Sendable {
    case semanticOnly = "semantic_only"
    case filteredSemantic = "filtered_semantic"
    case structuredOnly = "structured_only"
    case needsClarification = "needs_clarification"
}

struct RAGRepoFilter: Codable, Equatable, Sendable {
    var status: RepoStatus?
    var languages: [String] = []
    var tags: [String] = []
    var minStars: Int?
    var maxStars: Int?
    var minForks: Int?
    var maxForks: Int?
    var licenses: [String] = []
    var includeArchived: Bool?
    var includeForks: Bool?
    var starredAfter: Date?
    var starredBefore: Date?
    var libraryUpdatedAfter: Date?
    var libraryUpdatedBefore: Date?
    var repoCreatedAfter: Date?
    var repoCreatedBefore: Date?
    var pushedAfter: Date?
    var pushedBefore: Date?

    enum CodingKeys: String, CodingKey {
        case status, languages, tags, minStars, maxStars, minForks, maxForks
        case licenses = "license"
        case includeArchived, includeForks, starredAfter, starredBefore
        case libraryUpdatedAfter, libraryUpdatedBefore, repoCreatedAfter, repoCreatedBefore
        case pushedAfter, pushedBefore
    }

    init(
        status: RepoStatus? = nil,
        languages: [String] = [],
        tags: [String] = [],
        minStars: Int? = nil,
        maxStars: Int? = nil,
        minForks: Int? = nil,
        maxForks: Int? = nil,
        licenses: [String] = [],
        includeArchived: Bool? = nil,
        includeForks: Bool? = nil,
        starredAfter: Date? = nil,
        starredBefore: Date? = nil,
        libraryUpdatedAfter: Date? = nil,
        libraryUpdatedBefore: Date? = nil,
        repoCreatedAfter: Date? = nil,
        repoCreatedBefore: Date? = nil,
        pushedAfter: Date? = nil,
        pushedBefore: Date? = nil
    ) {
        self.status = status
        self.languages = languages
        self.tags = tags
        self.minStars = minStars
        self.maxStars = maxStars
        self.minForks = minForks
        self.maxForks = maxForks
        self.licenses = licenses
        self.includeArchived = includeArchived
        self.includeForks = includeForks
        self.starredAfter = starredAfter
        self.starredBefore = starredBefore
        self.libraryUpdatedAfter = libraryUpdatedAfter
        self.libraryUpdatedBefore = libraryUpdatedBefore
        self.repoCreatedAfter = repoCreatedAfter
        self.repoCreatedBefore = repoCreatedBefore
        self.pushedAfter = pushedAfter
        self.pushedBefore = pushedBefore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(RepoStatus.self, forKey: .status)
        languages = try container.decodeIfPresent([String].self, forKey: .languages) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        minStars = try container.decodeIfPresent(Int.self, forKey: .minStars)
        maxStars = try container.decodeIfPresent(Int.self, forKey: .maxStars)
        minForks = try container.decodeIfPresent(Int.self, forKey: .minForks)
        maxForks = try container.decodeIfPresent(Int.self, forKey: .maxForks)
        licenses = try container.decodeIfPresent([String].self, forKey: .licenses) ?? []
        includeArchived = try container.decodeIfPresent(Bool.self, forKey: .includeArchived)
        includeForks = try container.decodeIfPresent(Bool.self, forKey: .includeForks)
        starredAfter = try container.decodeIfPresent(Date.self, forKey: .starredAfter)
        starredBefore = try container.decodeIfPresent(Date.self, forKey: .starredBefore)
        libraryUpdatedAfter = try container.decodeIfPresent(Date.self, forKey: .libraryUpdatedAfter)
        libraryUpdatedBefore = try container.decodeIfPresent(Date.self, forKey: .libraryUpdatedBefore)
        repoCreatedAfter = try container.decodeIfPresent(Date.self, forKey: .repoCreatedAfter)
        repoCreatedBefore = try container.decodeIfPresent(Date.self, forKey: .repoCreatedBefore)
        pushedAfter = try container.decodeIfPresent(Date.self, forKey: .pushedAfter)
        pushedBefore = try container.decodeIfPresent(Date.self, forKey: .pushedBefore)
    }

    var hasEffectiveConditions: Bool {
        status != nil || !languages.isEmpty || !tags.isEmpty || minStars != nil || maxStars != nil
            || minForks != nil || maxForks != nil || !licenses.isEmpty || includeArchived != nil
            || includeForks != nil || starredAfter != nil || starredBefore != nil
            || libraryUpdatedAfter != nil || libraryUpdatedBefore != nil
            || repoCreatedAfter != nil || repoCreatedBefore != nil || pushedAfter != nil || pushedBefore != nil
    }
}

enum RAGRepoSortField: String, Codable, Sendable {
    case stars
    case forks
    case pushedAt
    case repoCreatedAt
    case libraryUpdatedAt
    case starredAt
}

enum RAGSortDirection: String, Codable, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

struct RAGRepoSort: Codable, Equatable, Sendable {
    var field: RAGRepoSortField
    var direction: RAGSortDirection
}

enum RAGRemoteContextResource: String, CaseIterable, Codable, Sendable {
    case githubIssues = "github_issues"
    case githubPullRequests = "github_pull_requests"
    case githubReleases = "github_releases"
    case githubContributors = "github_contributors"
    case githubCommitActivity = "github_commit_activity"
    case githubSecurityAdvisories = "github_security_advisories"
}

struct RAGRemoteContextRequest: Codable, Equatable, Sendable {
    var resource: RAGRemoteContextResource
    var query: String
    var reason: String
    var maxRepos: Int
    var perRepoLimit: Int
}

enum RAGQueryPlanConfidence: String, Codable, Sendable {
    case high
    case medium
    case needsClarification = "needs_clarification"
}

struct RAGUserVisiblePlan: Codable, Equatable, Sendable {
    var scope: String
    var chips: [String]
    var semantic: String
    /// Planner 产出的简短、面向用户的查询规划说明；它不是 provider 的推理原文。
    var planningNotes: [String]

    init(
        scope: String = "知识库",
        chips: [String] = [],
        semantic: String = "",
        planningNotes: [String] = []
    ) {
        self.scope = scope
        self.chips = chips
        self.semantic = semantic
        self.planningNotes = planningNotes
    }

    enum CodingKeys: String, CodingKey {
        case scope, chips, semantic, planningNotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? "知识库"
        chips = try container.decodeIfPresent([String].self, forKey: .chips) ?? []
        semantic = try container.decodeIfPresent(String.self, forKey: .semantic) ?? ""
        planningNotes = try container.decodeIfPresent([String].self, forKey: .planningNotes) ?? []
    }
}

/// 一轮 RAG 问答中对普通用户可见的执行步骤。
///
/// 只保存已发生的操作及其可解释摘要，不能复用 Debug payload，避免把 prompt、历史或
/// 用户可见的规划、工具操作和 provider 已公开的推理文本。
enum RAGExecutionStepKind: String, Codable, CaseIterable, Sendable {
    case planning
    case planningReasoning
    case retrieval
    case remoteContext
    case answerReasoning
    case generation
}

enum RAGExecutionStepState: String, Codable, Sendable {
    case running
    case completed
    case skipped
}

struct RAGExecutionStep: Identifiable, Codable, Equatable, Sendable {
    var kind: RAGExecutionStepKind
    var state: RAGExecutionStepState
    var details: [String]
    var summary: String?
    /// 轨迹会随会话持久化；可选值兼容此前没有耗时字段的本地 RAG 历史。
    var startedAt: Date?
    var completedAt: Date?

    var id: RAGExecutionStepKind { kind }

    init(
        kind: RAGExecutionStepKind,
        state: RAGExecutionStepState = .running,
        details: [String] = [],
        summary: String? = nil,
        startedAt: Date? = .now,
        completedAt: Date? = nil
    ) {
        self.kind = kind
        self.state = state
        self.details = details
        self.summary = summary
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    /// 运行中以当前时刻持续计时，完成后固定为真实结束时刻，供用户核验步骤耗时。
    func elapsedDuration(at now: Date = .now) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (completedAt ?? now).timeIntervalSince(startedAt))
    }
}

/// Retriever 在真实子操作完成时上报的进度；用于驱动用户可见轨迹，而非调试日志。
enum RAGRetrievalProgress: Sendable {
    case candidateSelectionCompleted(Int)
    case keywordSearchStarted
    case keywordSearchCompleted(Int)
    case semanticSearchStarted
    case semanticSearchCompleted(Int)
    case evidencePacked(hitCount: Int, bundleCount: Int)
}

struct RAGQueryPlan: Codable, Equatable, Sendable {
    var mode: RAGQueryMode
    var semanticQuery: String
    var filters: RAGRepoFilter
    var sort: RAGRepoSort?
    var candidateLimit: Int?
    var remoteContextRequests: [RAGRemoteContextRequest]
    var confidence: RAGQueryPlanConfidence
    var clarificationQuestion: String?
    var userVisiblePlan: RAGUserVisiblePlan

    enum CodingKeys: String, CodingKey {
        case mode, semanticQuery, filters, sort, candidateLimit, remoteContextRequests
        case confidence, clarificationQuestion, userVisiblePlan
    }

    init(
        mode: RAGQueryMode,
        semanticQuery: String,
        filters: RAGRepoFilter = .init(),
        sort: RAGRepoSort? = nil,
        candidateLimit: Int? = nil,
        remoteContextRequests: [RAGRemoteContextRequest] = [],
        confidence: RAGQueryPlanConfidence = .high,
        clarificationQuestion: String? = nil,
        userVisiblePlan: RAGUserVisiblePlan = .init()
    ) {
        self.mode = mode
        self.semanticQuery = semanticQuery
        self.filters = filters
        self.sort = sort
        self.candidateLimit = candidateLimit
        self.remoteContextRequests = remoteContextRequests
        self.confidence = confidence
        self.clarificationQuestion = clarificationQuestion
        self.userVisiblePlan = userVisiblePlan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(RAGQueryMode.self, forKey: .mode)
        semanticQuery = try container.decodeIfPresent(String.self, forKey: .semanticQuery) ?? ""
        filters = try container.decodeIfPresent(RAGRepoFilter.self, forKey: .filters) ?? .init()
        sort = try container.decodeIfPresent(RAGRepoSort.self, forKey: .sort)
        candidateLimit = try container.decodeIfPresent(Int.self, forKey: .candidateLimit)
        remoteContextRequests = try container.decodeIfPresent([RAGRemoteContextRequest].self, forKey: .remoteContextRequests) ?? []
        confidence = try container.decodeIfPresent(RAGQueryPlanConfidence.self, forKey: .confidence) ?? .medium
        clarificationQuestion = try container.decodeIfPresent(String.self, forKey: .clarificationQuestion)
        userVisiblePlan = try container.decodeIfPresent(RAGUserVisiblePlan.self, forKey: .userVisiblePlan) ?? .init()
    }
}

struct RAGRepoCandidate: Equatable, Sendable {
    var repo: Repo
    var status: RepoStatus
    var libraryUpdatedAt: String?
    var tagNames: [String]
}

enum RAGHitKind: String, Codable, Sendable {
    case keyword
    case vector
    case hybrid
}

/// 单次检索的不可变计算快照。排名和权重都取自融合当刻，不能从最终分数可靠倒推。
struct RAGScoreBreakdown: Codable, Equatable, Sendable {
    var hitKind: RAGHitKind
    var rrfConstant: Double
    var keywordRank: Int?
    var keywordScore: Double?
    var keywordWeight: Double
    var keywordScoreWeight: Double
    var vectorRank: Int?
    var vectorSimilarity: Double?
    var vectorWeight: Double
    var vectorScoreWeight: Double
    var sourceWeight: Double
    var preferredRepoBoost: Double
    var finalScore: Double
}

struct RAGChildHit: Equatable, Sendable {
    var chunk: RAGChunk
    /// 用于排序和证据门槛的融合分；不是可直接解释为百分比的相似度。
    var score: Double
    var kind: RAGHitKind
    /// 原始向量召回分。仅 vector / hybrid 命中有值，供引用详情如实展示语义相似度。
    var vectorSimilarity: Double? = nil
    /// 融合阶段生成的真实计算输入；引用写入会话历史后仍可精确复算。
    var scoreBreakdown: RAGScoreBreakdown? = nil
}

struct RAGSectionParent: Equatable, Sendable {
    var repoId: Int64
    var parentKey: String
    var title: String
    var content: String
    var childChunkIDs: [Int64]
}

struct RepoContextBundle: Equatable, Sendable {
    var candidate: RAGRepoCandidate
    var score: Double
    var matchedChildren: [RAGChildHit]
    var sectionParents: [RAGSectionParent]
}

struct RAGRetrievalResult: Equatable, Sendable {
    var candidates: [RAGRepoCandidate]
    var bundles: [RepoContextBundle]
    var childHits: [RAGChildHit]
}

struct RAGRemoteContextBlock: Identifiable, Equatable, Sendable {
    var id: String
    var repoId: Int64
    var resource: RAGRemoteContextResource
    var title: String
    var sourceURL: URL?
    var content: String
    var fetchedAt: Date
    var errorMessage: String?
}

/// 会话历史只保留远程上下文的审计元数据，不保存 issues / PR 正文，避免把临时网络内容变成
/// 长期知识资产。`id` 由 assistant message 与本轮 resource 组合，跨轮次不会冲突。
struct RAGRemoteContextAudit: Identifiable, Equatable, Sendable {
    var id: String
    var repoID: Int64
    var resource: RAGRemoteContextResource
    var title: String
    var sourceURL: URL?
    var fetchedAt: String
    var errorMessage: String?
}

struct RAGCitation: Identifiable, Equatable, Sendable {
    var id: UUID
    /// Prompt / 回答正文里的证据编号，形如 `S1`；与 UI 芯片、可点击 `[S1]` 一一对应。
    var marker: String
    var chunkID: Int64?
    var repoID: Int64
    var repoFullName: String
    var source: RAGChunkSource
    var sectionTitle: String
    /// 融合后的检索排序分，用于回放本轮证据排序，不能作为百分比相关度解读。
    var score: Double
    var hitKind: RAGHitKind
    /// 写入历史的原始向量相似度；keyword-only 命中保持 nil。
    var vectorSimilarity: Double?
    /// 与本轮引用绑定的融合快照；旧历史没有该字段时为 nil。
    var scoreBreakdown: RAGScoreBreakdown? = nil
    var sourceURL: URL?
}

enum RAGAnswerState: Equatable, Sendable {
    case idle
    case planning
    case needsClarification(String)
    case noKnowledgeRepos
    case noCandidates
    case noIndex
    case noRelevantChunks
    case retrieving
    case awaitingRemoteContextConfirmation
    case fetchingRemoteContext
    case generating
    case completed
    case cancelled
    case failed(String)
}
