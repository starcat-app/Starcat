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

    init(scope: String = "知识库", chips: [String] = [], semantic: String = "") {
        self.scope = scope
        self.chips = chips
        self.semantic = semantic
    }
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

struct RAGChildHit: Equatable, Sendable {
    var chunk: RAGChunk
    var score: Double
    var kind: RAGHitKind
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
    var score: Double
    var hitKind: RAGHitKind
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
