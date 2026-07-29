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

/// Planner 只需要仓库身份，不需要 README、笔记或检索正文。显式传名字是为了让模型能
/// 正确理解 `@repo`，同时继续把真正的数据访问边界留在本地执行层。
struct RAGPlannerRepoReference: Equatable, Sendable {
    var id: Int64
    var fullName: String
}

struct RAGComposerContext: Equatable, Sendable {
    var explicitRepoIDs: [Int64] = []
    var explicitRepoReferences: [RAGPlannerRepoReference] = []
    /// 允许发送给 External Search 的仓库身份。私有仓库只有在设置页明确允许后才进入此数组；
    /// 与 Planner 的本地范围分开，避免主动联网开关意外扩大私有元数据出站范围。
    var webSearchRepoReferences: [RAGPlannerRepoReference] = []
    var explicitRepoMode: RAGExplicitRepoMode = .only
    var selectedModelID: String?
    var attachments: [RAGComposerAttachment] = []
    var pastedGitHubLinks: [RAGGitHubLinkReference] = []
    /// 只传上一条用户问题及上一轮真正引用到的仓库名，避免把整段 assistant 回答再次
    /// 发送给 Planner，又保留“继续比较它们”这类最小指代消解能力。
    var previousUserQuestion: String?
    var previousReferencedRepos: [RAGPlannerRepoReference] = []
    /// Composer 的 `globe` 开关是本轮明确联网授权。开启后 GitHub 临时上下文无需再次
    /// 确认，普通 External Search 也可以直接执行；关闭时仍保留原有 GitHub 逐项确认。
    var webSearchEnabled = false
    /// “深度思考”是用户对本轮单项目 RepoContext 的显式授权。目标仓库不由 Planner
    /// 选择，而是由本地执行层从唯一显式 repo scope 解析，避免模型扩大代码读取范围。
    var deepThinkingEnabled = false
    /// 用户可以在执行前移除 Planner 建议的远程上下文 chip。
    var disabledRemoteResources: Set<RAGRemoteContextResource> = []
}

/// 本地标准化的 RepoContext 请求。它只描述用户已经明确选择的唯一项目，不携带 XML，
/// 因此可以安全进入 Planner、执行轨迹和历史回放。
struct RAGRepoContextRequest: Codable, Equatable, Sendable {
    var repoID: Int64
    var repoFullName: String
    var reason: String
    var configuredTokenBudget: Int
}

enum RAGRepoContextOutcome: String, Codable, Equatable, Sendable {
    case success
    case featureDisabled = "feature_disabled"
    case degraded
}

/// 会话历史只保存 RepoContext 的审计元数据，不复制 `context.xml` 正文。
/// `sentTokens` 和 `wasProjected` 描述最终进入 Generator 的版本，而不是磁盘原文件。
struct RAGRepoContextSnapshot: Codable, Equatable, Sendable {
    var repoID: Int64
    var repoFullName: String
    var commitSHA: String?
    var contentHash: String?
    var configuredTokenBudget: Int
    var originalTokens: Int
    var sentTokens: Int
    var cacheHit: Bool
    var outcome: RAGRepoContextOutcome
    var wasProjected: Bool
    var projectionReason: String?
    var degradationReason: String? = nil
    var citationMarker: String?
    var preparedAt: Date
}

/// RepoContext 正文只在本轮内存态流转。历史回放必须凭 snapshot 的 commit/hash 从
/// `RepoContextStorage` 重新核验，不能把后来生成的 XML 冒充旧证据。
struct RAGRepoContextDocument: Equatable, Sendable {
    var snapshot: RAGRepoContextSnapshot
    var xml: String
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
    case guidedDiscovery = "guided_discovery"
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
    /// 普通互联网结果由 External Search Provider 提供，不会进入 GitHub Provider。
    case externalWeb = "external_web"
}

enum RAGRemoteIssueState: String, Codable, Sendable {
    case all
    case open
    case closed
}

enum RAGRemoteIssueSort: String, Codable, Sendable {
    case created
    case updated
}

struct RAGRemoteContextRequest: Codable, Equatable, Sendable {
    var resource: RAGRemoteContextResource
    var query: String
    var reason: String
    var maxRepos: Int
    var perRepoLimit: Int
    var state: RAGRemoteIssueState
    var sort: RAGRemoteIssueSort
    var order: RAGSortDirection

    init(
        resource: RAGRemoteContextResource,
        query: String,
        reason: String,
        maxRepos: Int,
        perRepoLimit: Int,
        state: RAGRemoteIssueState = .all,
        sort: RAGRemoteIssueSort = .updated,
        order: RAGSortDirection = .descending
    ) {
        self.resource = resource
        self.query = query
        self.reason = reason
        self.maxRepos = maxRepos
        self.perRepoLimit = perRepoLimit
        self.state = state
        self.sort = sort
        self.order = order
    }

    enum CodingKeys: String, CodingKey {
        case resource, query, reason, maxRepos, perRepoLimit, state, sort, order
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resource = try container.decode(RAGRemoteContextResource.self, forKey: .resource)
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        maxRepos = try container.decodeIfPresent(Int.self, forKey: .maxRepos) ?? 1
        perRepoLimit = try container.decodeIfPresent(Int.self, forKey: .perRepoLimit) ?? 5
        state = try container.decodeIfPresent(RAGRemoteIssueState.self, forKey: .state) ?? .all
        sort = try container.decodeIfPresent(RAGRemoteIssueSort.self, forKey: .sort) ?? .updated
        order = try container.decodeIfPresent(RAGSortDirection.self, forKey: .order) ?? .descending
    }
}

/// Planner 或 Composer 主动联网开关产生的普通 Web 查询。
///
/// 与 GitHub `repo × resource` 请求分开建模，是为了不让开放互联网查询伪装成某个仓库的
/// 结构化 GitHub API 请求；执行层仍会把两类结果汇总到同一个用户可见联网步骤。
struct RAGWebSearchRequest: Codable, Equatable, Identifiable, Sendable {
    var query: String
    var reason: String
    var maxResults: Int

    /// 查询经本地限制为 240 字并去重，因此可以直接作为同一轮执行轨迹里的稳定身份。
    var id: String {
        "external_web:\(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
    }

    init(query: String, reason: String, maxResults: Int = 8) {
        self.query = query
        self.reason = reason
        self.maxResults = maxResults
    }

    enum CodingKeys: String, CodingKey {
        case query, reason, maxResults
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        maxResults = try container.decodeIfPresent(Int.self, forKey: .maxResults) ?? 8
    }
}

enum RAGQueryPlanConfidence: String, Codable, Sendable {
    case high
    case medium
    case needsClarification = "needs_clarification"
}

struct RAGUserVisiblePlan: Codable, Equatable, Sendable {
    /// Scope 是产品固定标签，不接受 Planner 自行决定显示语言；运行时按 App 语言查表。
    static var defaultScope: String { String.l10n("rag.core.plan.scope.knowledge") }

    var scope: String
    var chips: [String]
    var semantic: String
    /// Planner 产出的简短、面向用户的查询规划说明；它不是 provider 的推理原文。
    var planningNotes: [String]

    init(
        scope: String = Self.defaultScope,
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
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? Self.defaultScope
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
    case repoContext
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
    /// 仅联网步骤使用。保持 optional，才能无损读取此前没有联网审计字段的历史轨迹。
    var remoteAuditItems: [RAGRemoteExecutionAuditItem]?
    /// 最终通过本地校验与联网门禁后的计划；optional 兼容旧会话。
    var queryPlan: RAGQueryPlan?
    /// 脱敏后的检索漏斗，不包含错误原文、Rerank 输入或分片正文。
    var retrievalSnapshot: RAGRetrievalSnapshot?
    /// Context Window 仅保存 token 数字，绝不把 Prompt 预览写入历史。
    var contextUsageSnapshot: RAGContextUsageSnapshot?
    /// RepoContext 只保存 commit/hash/token 等审计元数据，绝不保存 XML 正文。
    var repoContextSnapshot: RAGRepoContextSnapshot?

    var id: RAGExecutionStepKind { kind }

    init(
        kind: RAGExecutionStepKind,
        state: RAGExecutionStepState = .running,
        details: [String] = [],
        summary: String? = nil,
        startedAt: Date? = .now,
        completedAt: Date? = nil,
        remoteAuditItems: [RAGRemoteExecutionAuditItem]? = nil,
        queryPlan: RAGQueryPlan? = nil,
        retrievalSnapshot: RAGRetrievalSnapshot? = nil,
        contextUsageSnapshot: RAGContextUsageSnapshot? = nil,
        repoContextSnapshot: RAGRepoContextSnapshot? = nil
    ) {
        self.kind = kind
        self.state = state
        self.details = details
        self.summary = summary
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.remoteAuditItems = remoteAuditItems
        self.queryPlan = queryPlan
        self.retrievalSnapshot = retrievalSnapshot
        self.contextUsageSnapshot = contextUsageSnapshot
        self.repoContextSnapshot = repoContextSnapshot
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
    /// 供关键词 Provider 使用的高信息量字面查询；与面向 embedding 的自然语言查询分离。
    var keywordQueries: [String]
    var filters: RAGRepoFilter
    var sort: RAGRepoSort?
    var candidateLimit: Int?
    var remoteContextRequests: [RAGRemoteContextRequest]
    var webSearchRequests: [RAGWebSearchRequest]
    /// 由本地执行层根据唯一显式项目写入；Planner JSON 不拥有目标选择权。
    var repoContextRequest: RAGRepoContextRequest?
    /// 为 true 时，本地知识片段不能替代实时结果；联网失败必须明确终止而不是生成旧答案。
    var requiresLiveEvidence: Bool
    var confidence: RAGQueryPlanConfidence
    var clarificationQuestion: String?
    var fallbackQuestions: [String]
    var userVisiblePlan: RAGUserVisiblePlan
    /// 仅允许受限 DSL；模型不能借此传入任意 SQL、字段名或 Join。
    var analytics: KnowledgeBaseAnalyticsPlan?

    enum CodingKeys: String, CodingKey {
        case mode, semanticQuery, keywordQueries, filters, sort, candidateLimit, remoteContextRequests
        case webSearchRequests, repoContextRequest, requiresLiveEvidence, analytics
        case confidence, clarificationQuestion, fallbackQuestions, userVisiblePlan
    }

    init(
        mode: RAGQueryMode,
        semanticQuery: String,
        keywordQueries: [String] = [],
        filters: RAGRepoFilter = .init(),
        sort: RAGRepoSort? = nil,
        candidateLimit: Int? = nil,
        remoteContextRequests: [RAGRemoteContextRequest] = [],
        webSearchRequests: [RAGWebSearchRequest] = [],
        repoContextRequest: RAGRepoContextRequest? = nil,
        requiresLiveEvidence: Bool = false,
        confidence: RAGQueryPlanConfidence = .high,
        clarificationQuestion: String? = nil,
        fallbackQuestions: [String] = [],
        userVisiblePlan: RAGUserVisiblePlan = .init(),
        analytics: KnowledgeBaseAnalyticsPlan? = nil
    ) {
        self.mode = mode
        self.semanticQuery = semanticQuery
        self.keywordQueries = keywordQueries
        self.filters = filters
        self.sort = sort
        self.candidateLimit = candidateLimit
        self.remoteContextRequests = remoteContextRequests
        self.webSearchRequests = webSearchRequests
        self.repoContextRequest = repoContextRequest
        self.requiresLiveEvidence = requiresLiveEvidence
        self.confidence = confidence
        self.clarificationQuestion = clarificationQuestion
        self.fallbackQuestions = fallbackQuestions
        self.userVisiblePlan = userVisiblePlan
        self.analytics = analytics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(RAGQueryMode.self, forKey: .mode)
        semanticQuery = try container.decodeIfPresent(String.self, forKey: .semanticQuery) ?? ""
        // 旧会话和旧自定义 Planner Prompt 没有该字段；空数组交给 Retriever 的本地 OR 兜底。
        keywordQueries = try container.decodeIfPresent([String].self, forKey: .keywordQueries) ?? []
        filters = try container.decodeIfPresent(RAGRepoFilter.self, forKey: .filters) ?? .init()
        sort = try container.decodeIfPresent(RAGRepoSort.self, forKey: .sort)
        candidateLimit = try container.decodeIfPresent(Int.self, forKey: .candidateLimit)
        remoteContextRequests = try container.decodeIfPresent([RAGRemoteContextRequest].self, forKey: .remoteContextRequests) ?? []
        webSearchRequests = try container.decodeIfPresent([RAGWebSearchRequest].self, forKey: .webSearchRequests) ?? []
        repoContextRequest = try container.decodeIfPresent(RAGRepoContextRequest.self, forKey: .repoContextRequest)
        requiresLiveEvidence = try container.decodeIfPresent(Bool.self, forKey: .requiresLiveEvidence) ?? false
        confidence = try container.decodeIfPresent(RAGQueryPlanConfidence.self, forKey: .confidence) ?? .medium
        clarificationQuestion = try container.decodeIfPresent(String.self, forKey: .clarificationQuestion)
        fallbackQuestions = try container.decodeIfPresent([String].self, forKey: .fallbackQuestions) ?? []
        userVisiblePlan = try container.decodeIfPresent(RAGUserVisiblePlan.self, forKey: .userVisiblePlan) ?? .init()
        analytics = try container.decodeIfPresent(KnowledgeBaseAnalyticsPlan.self, forKey: .analytics)
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
    case repositoryInsights = "repository_insights"
    case repoContext = "repo_context"
}

/// Citation 的来源集合与数据库分片来源刻意分离。两个 XML 都是仓库级临时证据，
/// 不能加入 `RAGChunkSource.CaseIterable`，否则会污染索引覆盖率与检索设置。
enum RAGCitationSource: String, Codable, Equatable, Sendable {
    case readme
    case notes
    case summary
    case metadata
    case repositoryInsights = "repository_insights"
    case repoContext = "repo_context"

    init(chunkSource: RAGChunkSource) {
        self = switch chunkSource {
        case .readme: .readme
        case .notes: .notes
        case .summary: .summary
        case .metadata: .metadata
        }
    }
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
    /// 用于排序和综合检索分阈值的融合分；不是可直接解释为百分比的相似度。
    var score: Double
    var kind: RAGHitKind
    /// 原始向量召回分。仅 vector / hybrid 命中有值，供引用详情如实展示语义相似度。
    var vectorSimilarity: Double? = nil
    /// 融合阶段生成的真实计算输入；引用写入会话历史后仍可精确复算。
    var scoreBreakdown: RAGScoreBreakdown? = nil
}

/// 检索漏斗中单个候选的最终去向。只记录用户能理解的门禁结果，避免把 provider 内部细节写进会话历史。
enum RAGRetrievalTraceDisposition: String, Codable, Equatable, Sendable {
    case retained
    case sourceDisabled
    case belowVectorSimilarity
    case perRepositoryLimit
    case totalLimit
    case belowEvidenceScore
    case parentContextTokenLimit
    case evidenceTokenLimit
}

/// 候选仓库的回放摘要；仅保存语言和 star 数这类可扫描的公开元数据，不复制描述、README 或标签。
struct RAGRetrievalCandidateTrace: Identifiable, Codable, Equatable, Sendable {
    var repoID: Int64
    var fullName: String
    /// optional 保证旧会话的 `execution_trace_json` 缺少这些新字段时仍可解码。
    var language: String? = nil
    var stars: Int? = nil

    var id: Int64 { repoID }
}

/// 漏斗中可回放的分片元数据。正文始终留在 `rag_chunks`，历史轨迹只保存足以核验检索决策的身份与分数。
struct RAGRetrievalHitTrace: Identifiable, Codable, Equatable, Sendable {
    var chunkID: Int64?
    var repoID: Int64
    var repositoryName: String
    var source: RAGChunkSource
    var sectionTitle: String
    var rank: Int
    var score: Double
    var hitKind: RAGHitKind
    var vectorSimilarity: Double?
    var scoreBreakdown: RAGScoreBreakdown?
    var disposition: RAGRetrievalTraceDisposition

    var id: String {
        "\(chunkID.map(String.init) ?? "missing")-\(repoID)-\(rank)-\(disposition.rawValue)"
    }
}

/// 关键词分支实际执行的安全查询。只保存短关键词和生成后的 FTS5 表达式，
/// 不保存用户原始问题或任何分片正文，便于历史会话解释“本轮到底搜了什么”。
struct RAGKeywordQueryTrace: Codable, Equatable, Sendable {
    var terms: [String]
    var fts5Expression: String
    var usedSemanticFallback: Bool

    init(query: RAGKeywordSearchQuery) {
        terms = query.terms
        fts5Expression = query.sqliteFTS5Expression
        usedSemanticFallback = query.usedSemanticFallback
    }
}

/// 同一轮检索的逐阶段脱敏明细。它与 `RAGRetrievalSnapshot` 一起写入既有会话轨迹，
/// 让用户重开历史会话时仍能查看“哪些仓库/分片为何进入或离开漏斗”。
struct RAGRetrievalTrace: Codable, Equatable, Sendable {
    /// optional 保证升级前的历史执行轨迹仍可解码。
    var keywordQuery: RAGKeywordQueryTrace? = nil
    var candidates: [RAGRetrievalCandidateTrace]
    var keywordHits: [RAGRetrievalHitTrace]
    var semanticHits: [RAGRetrievalHitTrace]
    var fusionHits: [RAGRetrievalHitTrace]
    var finalEvidence: [RAGRetrievalHitTrace]
    var rerank: RAGRerankTrace?

    init(
        keywordQuery: RAGKeywordQueryTrace? = nil,
        candidates: [RAGRetrievalCandidateTrace] = [],
        keywordHits: [RAGRetrievalHitTrace] = [],
        semanticHits: [RAGRetrievalHitTrace] = [],
        fusionHits: [RAGRetrievalHitTrace] = [],
        finalEvidence: [RAGRetrievalHitTrace] = [],
        rerank: RAGRerankTrace? = nil
    ) {
        self.keywordQuery = keywordQuery
        self.candidates = candidates
        self.keywordHits = keywordHits
        self.semanticHits = semanticHits
        self.fusionHits = fusionHits
        self.finalEvidence = finalEvidence
        self.rerank = rerank
    }

    /// Prompt 组装发生在 Retriever 返回之后；只改写原本会进入上下文的命中，
    /// 保留父段落 token 上限的先前判定，才能在历史会话中准确说明最后一次裁剪原因。
    mutating func markEvidenceTokenLimited(chunkIDs: Set<Int64>) {
        guard !chunkIDs.isEmpty else { return }
        finalEvidence = finalEvidence.map { hit in
            guard hit.disposition == .retained,
                  let chunkID = hit.chunkID,
                  chunkIDs.contains(chunkID) else { return hit }
            var limited = hit
            limited.disposition = .evidenceTokenLimit
            return limited
        }
    }
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
    /// 最终仓库固定携带的完整 metadata:0；它不是额外 hit，也不产生 citation。
    var metadataContent: String? = nil
}

struct RAGRetrievalResult: Equatable, Sendable {
    var candidates: [RAGRepoCandidate]
    var bundles: [RepoContextBundle]
    var childHits: [RAGChildHit]
    /// 仅随当前问答内存流转，用于 Debug 解释候选为何在检索漏斗中被丢弃；不写入会话历史。
    var diagnostics: RAGRetrievalDiagnostics? = nil
    /// 不含分片正文的逐阶段轨迹；历史会话通过 `RAGRetrievalSnapshot` 保存同一份数据。
    var trace: RAGRetrievalTrace? = nil
}

/// Rerank 独立 Trace 的结构化明细。仅保留用于核对请求/响应映射的元数据与分数，
/// 不复制发送给外部服务的分片正文，避免 Debug 文件成为知识库的另一份副本。
struct RAGRerankTrace: Codable, Equatable, Sendable {
    struct InputCandidate: Codable, Equatable, Sendable {
        /// 与实际 Rerank 请求 documents/texts 数组相同的 0-based 下标。
        var inputIndex: Int
        var repositoryName: String
        var source: RAGChunkSource
        var section: String
        var preRerankScore: Double
    }

    struct ResponseResult: Codable, Equatable, Sendable {
        /// 服务响应中的原始输入下标，用于核对返回结果是否映射到正确候选。
        var inputIndex: Int
        var rerankScore: Double
    }

    struct AppliedItem: Codable, Equatable, Sendable {
        /// 最终进入后续 evidence limit 前的排序位置，从 1 开始。
        var rank: Int
        /// `nil` 表示该候选未发送给 Rerank 服务（超过候选上限），保留原融合顺序追加在末尾。
        var inputIndex: Int?
        var rerankScore: Double?
    }

    var query: String
    var model: String?
    var candidateLimit: Int?
    var inputCandidates: [InputCandidate]
    var responseResults: [ResponseResult]
    var appliedOrder: [AppliedItem]
}

/// Rerank 的执行结果。即使远端不可用也只降级排序，不能使正常 RAG 问答失败。
struct RAGRerankDiagnostics: Codable, Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable { case disabled, skipped, completed, failedFallback }
    var state: State = .disabled
    /// 协议类型仅用于解释本次调用方式；地址、Token 和候选正文不进入 Debug 文件。
    var provider: RAGRerankProvider?
    var candidateCount = 0
    var rerankedCount = 0
    var elapsedSeconds: TimeInterval = 0
    var errorDescription: String?
    /// 只在实际调用 Rerank 时写入，用于独立 Trace 按当前语言重新渲染。
    var trace: RAGRerankTrace?

    /// Rerank 独立 Trace 的用户可读正文；与检索漏斗分开，避免相同统计在两个入口重复出现。
    func debugPayload() -> String {
        switch state {
        case .disabled:
            return String.l10n("rag.workspace.debug.retrieval.rerank.disabled")
        case .skipped:
            return String(format: String.l10n("rag.workspace.debug.retrieval.rerank.skipped"), providerTitle)
        case .completed:
            return String(format: String.l10n("rag.workspace.debug.retrieval.rerank.completed"), providerTitle, candidateCount, rerankedCount, elapsedSeconds)
        case .failedFallback:
            return String(format: String.l10n("rag.workspace.debug.retrieval.rerank.failed"), providerTitle, candidateCount, errorDescription ?? String.l10n("rag.workspace.debug.retrieval.error.none"))
        }
    }

    private var providerTitle: String {
        switch provider {
        case .huggingFaceTEI: return String.l10n("rag.workspace.rerank.provider.tei")
        case .cohereCompatible: return String.l10n("rag.workspace.rerank.provider.cohere")
        case nil: return String.l10n("rag.workspace.debug.retrieval.error.none")
        }
    }
}

/// RAG 检索的可解释性快照。数值只统计分片数量，不包含分片正文，避免 Debug 导出扩大数据暴露面。
struct RAGRetrievalDiagnostics: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Equatable, Sendable {
        case completed
        case noCandidates = "no_candidates"
        case noReadyChunks = "no_ready_chunks"
        case sourcesDisabled = "sources_disabled"
        case skippedStructured = "skipped_structured"
        case noEvidence = "no_evidence"
    }

    var settings: RAGRetrievalSettings
    var candidateRepoCount: Int
    /// 实际执行的关键词查询；optional 用于兼容旧版 Debug JSON。
    var keywordQuery: RAGKeywordQueryTrace? = nil
    var keywordRawCount = 0
    var keywordSourceFilteredCount = 0
    var keywordErrorDescription: String?
    var vectorRawCount = 0
    var vectorSourceFilteredCount = 0
    var vectorSimilarityFilteredCount = 0
    var vectorErrorDescription: String?
    var fusion: RAGHybridFusionDiagnostics = .init()
    var minimumEvidenceScoreFilteredCount = 0
    /// 旧版 Debug JSON 没有该字段；保持 optional 才能继续读取历史调试文件。
    var rerank: RAGRerankDiagnostics? = nil
    var finalChildHitCount = 0
    var bundleCount = 0
    var outcome: Outcome

    func debugPayload() -> String {
        let sourceNames = settings.enabledSources
            .map(debugSourceTitle)
            .sorted()
            .joined(separator: ", ")
        let conclusion: String
        switch outcome {
        case .completed:
            conclusion = String(format: String.l10n("rag.workspace.debug.retrieval.conclusion.completedFormat"), finalChildHitCount, bundleCount)
        case .noCandidates:
            conclusion = String.l10n("rag.workspace.debug.retrieval.conclusion.noCandidates")
        case .noReadyChunks:
            conclusion = String.l10n("rag.workspace.debug.retrieval.conclusion.noReadyChunks")
        case .sourcesDisabled:
            conclusion = String.l10n("rag.workspace.debug.retrieval.conclusion.sourcesDisabled")
        case .skippedStructured:
            conclusion = String.l10n("rag.workspace.debug.retrieval.conclusion.skippedStructured")
        case .noEvidence:
            if vectorRawCount > 0, vectorSimilarityFilteredCount == vectorRawCount - vectorSourceFilteredCount {
                conclusion = String.l10n("rag.workspace.debug.retrieval.conclusion.allBelowThreshold")
            } else if keywordRawCount + vectorRawCount == 0 {
                conclusion = String.l10n("rag.workspace.debug.retrieval.conclusion.noRawHits")
            } else {
                conclusion = String.l10n("rag.workspace.debug.retrieval.conclusion.noEvidence")
            }
        }
        return """
        \(String.l10n("rag.workspace.debug.retrieval.settings.title"))
        - \(String(format: String.l10n("rag.workspace.debug.retrieval.settings.minimumSimilarityFormat"), settings.minimumVectorSimilarity))
        - \(String(format: String.l10n("rag.workspace.debug.retrieval.settings.evidenceLimitsFormat"), settings.finalEvidenceChunkLimit, settings.perRepositoryEvidenceLimit))
        - \(String(format: String.l10n("rag.workspace.debug.retrieval.settings.tokenBudgetFormat"), settings.evidenceTokenBudget))
        - \(String(format: String.l10n("rag.workspace.debug.retrieval.settings.sourcesFormat"), sourceNames.isEmpty ? String.l10n("rag.workspace.debug.retrieval.sources.none") : sourceNames))
        \(debugKeywordQuery())

        \(String.l10n("rag.workspace.debug.retrieval.funnel.title"))
        - \(String(format: String.l10n("rag.workspace.debug.retrieval.funnel.candidatesFormat"), candidateRepoCount))
        - \(String(format: String.l10n("rag.workspace.debug.retrieval.funnel.keywordFormat"), keywordRawCount, keywordSourceFilteredCount, keywordRawCount - keywordSourceFilteredCount))
        - \(String(format: String.l10n("rag.workspace.debug.retrieval.funnel.semanticFormat"), vectorRawCount, vectorSourceFilteredCount, vectorSimilarityFilteredCount, vectorRawCount - vectorSourceFilteredCount - vectorSimilarityFilteredCount))
        - \(String(format: String.l10n("rag.workspace.debug.retrieval.funnel.rankingFormat"), fusion.uniqueCount, fusion.perRepositoryLimitFilteredCount, fusion.totalLimitFilteredCount, minimumEvidenceScoreFilteredCount))
        - \(String(format: String.l10n("rag.workspace.debug.retrieval.funnel.resultFormat"), finalChildHitCount, bundleCount))
        \(debugErrorSummary())

        \(String.l10n("rag.workspace.debug.retrieval.conclusion.title"))
        \(conclusion)
        """
    }

    private func debugKeywordQuery() -> String {
        guard let keywordQuery else { return "" }
        let fallback = keywordQuery.usedSemanticFallback
            ? "\n- \(String.l10n("rag.workspace.debug.retrieval.query.semanticFallback"))"
            : ""
        return """

        \(String.l10n("rag.workspace.debug.retrieval.query.title"))
        - \(String(format: String.l10n("rag.workspace.debug.retrieval.query.termsFormat"), keywordQuery.terms.joined(separator: ", ")))
        - \(String(format: String.l10n("rag.workspace.debug.retrieval.query.ftsFormat"), keywordQuery.fts5Expression))\(fallback)
        """
    }

    private func debugSourceTitle(_ source: RAGChunkSource) -> String {
        switch source {
        case .readme: String.l10n("rag.browser.source.readme")
        case .notes: String.l10n("rag.browser.source.notes")
        case .summary: String.l10n("rag.browser.source.summary")
        case .metadata: String.l10n("rag.browser.source.metadata")
        }
    }

    private func debugErrorSummary() -> String {
        let errors = [keywordErrorDescription, vectorErrorDescription].compactMap { $0 }
        guard !errors.isEmpty else { return "" }
        return String(format: String.l10n("rag.workspace.debug.retrieval.funnel.errorsFormat"), errors.joined(separator: "\n"))
    }
}

/// 检索漏斗单分支的纯值状态。把判断从 SwiftUI View 中抽离，既能直接回归测试，
/// 也保证当前轮与历史快照使用同一套“0 命中 / 失败 / 跳过”语义。
enum RAGRetrievalBranchStatus: Equatable, Sendable {
    case completed(raw: Int, accepted: Int)
    case failed(RAGRetrievalBranchFailure)
    case skipped

    static func resolve(
        raw: Int,
        accepted: Int,
        failure: RAGRetrievalBranchFailure?,
        outcome: RAGRetrievalDiagnostics.Outcome?
    ) -> Self {
        if let failure {
            return .failed(failure)
        }
        if outcome == .noCandidates
            || outcome == .noReadyChunks
            || outcome == .sourcesDisabled
            || outcome == .skippedStructured {
            return .skipped
        }
        return .completed(raw: raw, accepted: accepted)
    }
}

/// 可随会话持久化的安全失败分类。原始 provider 错误可能包含自托管 endpoint 或系统路径，
/// 只允许留在当前轮 Diagnostics/Debug，历史 Snapshot 仅保存这个稳定 code。
enum RAGRetrievalBranchFailure: String, Codable, Equatable, Sendable {
    case providerError = "provider_error"
}

/// “计划”面板可回放的检索结果摘要。
///
/// `RAGRetrievalDiagnostics` 仍是当前轮 Debug 事实，可能包含 provider 错误；
/// 历史会话保留数量、安全设置、分支失败分类与不含正文的检索轨迹，避免复制原始外部错误或正文。
struct RAGRetrievalSnapshot: Codable, Equatable, Sendable {
    var settings: RAGRetrievalSettings?
    var candidateRepoCount: Int
    var keywordRawCount: Int
    var keywordAcceptedCount: Int
    /// optional 保证旧会话快照仍可解码，同时让 0 命中与执行失败不再混为一谈。
    var keywordFailure: RAGRetrievalBranchFailure? = nil
    var vectorRawCount: Int
    var vectorAcceptedCount: Int
    var vectorFailure: RAGRetrievalBranchFailure? = nil
    var fusionUniqueCount: Int
    var rankingFilteredCount: Int
    var rerankState: RAGRerankDiagnostics.State?
    var rerankCandidateCount: Int
    var rerankedCount: Int
    var finalChildHitCount: Int
    var bundleCount: Int
    var outcome: RAGRetrievalDiagnostics.Outcome?
    var trace: RAGRetrievalTrace?

    init(result: RAGRetrievalResult) {
        guard let diagnostics = result.diagnostics else {
            settings = nil
            candidateRepoCount = result.candidates.count
            keywordRawCount = 0
            keywordAcceptedCount = 0
            keywordFailure = nil
            vectorRawCount = 0
            vectorAcceptedCount = 0
            vectorFailure = nil
            fusionUniqueCount = result.childHits.count
            rankingFilteredCount = 0
            rerankState = nil
            rerankCandidateCount = 0
            rerankedCount = 0
            finalChildHitCount = result.childHits.count
            bundleCount = result.bundles.count
            outcome = nil
            trace = result.trace
            return
        }

        let rerank = diagnostics.rerank
        settings = diagnostics.settings
        candidateRepoCount = diagnostics.candidateRepoCount
        keywordRawCount = diagnostics.keywordRawCount
        keywordAcceptedCount = max(diagnostics.keywordRawCount - diagnostics.keywordSourceFilteredCount, 0)
        keywordFailure = diagnostics.keywordErrorDescription == nil ? nil : .providerError
        vectorRawCount = diagnostics.vectorRawCount
        vectorAcceptedCount = max(
            diagnostics.vectorRawCount
                - diagnostics.vectorSourceFilteredCount
                - diagnostics.vectorSimilarityFilteredCount,
            0
        )
        vectorFailure = diagnostics.vectorErrorDescription == nil ? nil : .providerError
        fusionUniqueCount = diagnostics.fusion.uniqueCount
        rankingFilteredCount = diagnostics.fusion.perRepositoryLimitFilteredCount
            + diagnostics.fusion.totalLimitFilteredCount
            + diagnostics.minimumEvidenceScoreFilteredCount
        rerankState = rerank?.state
        rerankCandidateCount = rerank?.candidateCount ?? 0
        rerankedCount = rerank?.rerankedCount ?? 0
        finalChildHitCount = diagnostics.finalChildHitCount
        bundleCount = diagnostics.bundleCount
        outcome = diagnostics.outcome
        trace = result.trace
    }
}

/// 用户点击后会恢复本轮仓库范围并直接发送。仓库 ID 必须随消息持久化，不能只保存一段
/// 看似带上下文、实际在历史会话中已经失去作用域的问题文本。
struct RAGSuggestedQuestionAction: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var question: String
    var repoIDs: [Int64]
    var explicitRepoMode: RAGExplicitRepoMode

    init(
        id: UUID = UUID(),
        question: String,
        repoIDs: [Int64] = [],
        explicitRepoMode: RAGExplicitRepoMode = .only
    ) {
        self.id = id
        self.question = question
        self.repoIDs = repoIDs
        self.explicitRepoMode = explicitRepoMode
    }
}

/// 不进入 Generator 的本地终止回答。用于纯闲聊引导和“没有任何可用证据”等路径，保证
/// UI 仍能展示明确反馈及可点击下一问，同时不让模型在空上下文中补写事实。
struct RAGTerminalResponse: Equatable, Sendable {
    var answer: String
    var suggestedActions: [RAGSuggestedQuestionAction]
}

/// 联网请求在执行前必须解析到确定的 `repo × resource`。这既是确认 UI 的最小授权单元，
/// 也是 Provider 防止把一个模糊请求扩散到任意候选仓库的边界。
struct RAGResolvedRemoteWorkItem: Identifiable, Equatable, Sendable {
    var id: String
    var candidate: RAGRepoCandidate
    var request: RAGRemoteContextRequest
}

enum RAGRemoteContextOutcome: String, Codable, Sendable {
    case success
    case empty
    case failed
}

enum RAGRemoteTransport: String, Codable, Sendable {
    case network
    case cache
}

enum RAGRemoteExecutionStatus: String, Codable, Sendable {
    case pending
    case running
    case succeeded
    case empty
    case failed
    case skipped
}

/// 普通用户可见、可随会话回放的最小联网审计。严禁写入 token、请求头和响应正文。
struct RAGRemoteExecutionAuditItem: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var repoFullName: String
    var resource: RAGRemoteContextResource
    var querySummary: String
    var requestURL: URL?
    var status: RAGRemoteExecutionStatus
    var transport: RAGRemoteTransport?
    var httpStatusCode: Int?
    var resultCount: Int?
    var errorMessage: String?
    var startedAt: Date?
    var completedAt: Date?
    /// External Search 使用；GitHub 项继续由 repo + resource 表达来源。
    var providerName: String? = nil
    /// 只保存标题与公开 URL，禁止写入网页正文或 Provider 原始响应。
    var resultPreviews: [RAGRemoteResultPreview] = []

    enum CodingKeys: String, CodingKey {
        case id, repoFullName, resource, querySummary, requestURL, status, transport
        case httpStatusCode, resultCount, errorMessage, startedAt, completedAt
        case providerName, resultPreviews
    }

    /// 旧会话 execution trace 没有 Provider 和结果预览；缺失时必须按空值恢复，不能让
    /// 整条历史执行轨迹因新增审计字段而解码失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        repoFullName = try container.decode(String.self, forKey: .repoFullName)
        resource = try container.decode(RAGRemoteContextResource.self, forKey: .resource)
        querySummary = try container.decodeIfPresent(String.self, forKey: .querySummary) ?? ""
        requestURL = try container.decodeIfPresent(URL.self, forKey: .requestURL)
        status = try container.decode(RAGRemoteExecutionStatus.self, forKey: .status)
        transport = try container.decodeIfPresent(RAGRemoteTransport.self, forKey: .transport)
        httpStatusCode = try container.decodeIfPresent(Int.self, forKey: .httpStatusCode)
        resultCount = try container.decodeIfPresent(Int.self, forKey: .resultCount)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName)
        resultPreviews = try container.decodeIfPresent([RAGRemoteResultPreview].self, forKey: .resultPreviews) ?? []
    }

    init(
        id: String,
        repoFullName: String,
        resource: RAGRemoteContextResource,
        querySummary: String,
        requestURL: URL?,
        status: RAGRemoteExecutionStatus,
        transport: RAGRemoteTransport?,
        httpStatusCode: Int?,
        resultCount: Int?,
        errorMessage: String?,
        startedAt: Date?,
        completedAt: Date?,
        providerName: String? = nil,
        resultPreviews: [RAGRemoteResultPreview] = []
    ) {
        self.id = id
        self.repoFullName = repoFullName
        self.resource = resource
        self.querySummary = querySummary
        self.requestURL = requestURL
        self.status = status
        self.transport = transport
        self.httpStatusCode = httpStatusCode
        self.resultCount = resultCount
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.providerName = providerName
        self.resultPreviews = resultPreviews
    }
}

/// 联网审计中的最小结果预览。正文只进入本轮 Prompt，不随会话长期保存。
struct RAGRemoteResultPreview: Codable, Equatable, Identifiable, Sendable {
    var title: String
    var url: URL
    var providerName: String?

    var id: String { url.absoluteString }
}

struct RAGRemoteContextBlock: Identifiable, Equatable, Sendable {
    var id: String
    /// GitHub 临时上下文绑定仓库；普通 Web 搜索没有 repo 外键，因此保持 nil 且不写入
    /// `rag_message_remote_contexts`，只持久化脱敏 execution trace。
    var repoId: Int64?
    var resource: RAGRemoteContextResource
    var title: String
    var sourceURL: URL?
    var content: String
    var fetchedAt: Date
    var errorMessage: String?
    var outcome: RAGRemoteContextOutcome = .success
    var transport: RAGRemoteTransport = .network
    var httpStatusCode: Int? = nil
    var resultCount: Int = 0
    var requestURL: URL? = nil
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var providerName: String? = nil
    var querySummary: String? = nil
    var resultPreviews: [RAGRemoteResultPreview] = []
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
    /// 仅用于 UI 语义色；当前回答直接取检索候选，历史回答由仓库表联表补齐。
    /// 仓库被删除或没有主语言时保持 nil，引用 chip 回退原有稳定色盘。
    var repoLanguage: String? = nil
    var source: RAGCitationSource
    var sectionTitle: String
    /// 融合后的检索排序分，用于回放本轮分片排序，不能作为百分比相关度解读。
    var score: Double
    var hitKind: RAGHitKind
    /// 写入历史的原始向量相似度；keyword-only 命中保持 nil。
    var vectorSimilarity: Double?
    /// 与本轮引用绑定的融合快照；旧历史没有该字段时为 nil。
    var scoreBreakdown: RAGScoreBreakdown? = nil
    var sourceURL: URL?

    init(
        id: UUID,
        marker: String,
        chunkID: Int64?,
        repoID: Int64,
        repoFullName: String,
        repoLanguage: String? = nil,
        source: RAGCitationSource,
        sectionTitle: String,
        score: Double,
        hitKind: RAGHitKind,
        vectorSimilarity: Double?,
        scoreBreakdown: RAGScoreBreakdown? = nil,
        sourceURL: URL?
    ) {
        self.id = id
        self.marker = marker
        self.chunkID = chunkID
        self.repoID = repoID
        self.repoFullName = repoFullName
        self.repoLanguage = repoLanguage
        self.source = source
        self.sectionTitle = sectionTitle
        self.score = score
        self.hitKind = hitKind
        self.vectorSimilarity = vectorSimilarity
        self.scoreBreakdown = scoreBreakdown
        self.sourceURL = sourceURL
    }

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
