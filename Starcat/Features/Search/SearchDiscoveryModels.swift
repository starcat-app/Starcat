//
//  SearchDiscoveryModels.swift
//  Starcat
//
//  全局搜索智能发现的领域契约。
//
//  设计约束：
//  - 计划、证据、阶段与会话是可测试的纯模型，不持有 Provider、LLM 客户端或 SwiftUI 状态；
//  - LLM 输出只能作为待校验材料进入这些类型，代码负责封闭集合、引用和预算校验；
//  - 证据与仓库卡片分离，避免把网页资料伪装成 Repo 或把模型自报分数伪装成语义相似度。
//

import Foundation

/// 查询进入基础搜索还是智能发现链路。
enum SearchIntentRoute: Equatable, Hashable, Sendable {
    /// 关键词、明确 owner/name、GitHub URL 或 GitHub 查询语法。
    case fastPath
    /// 自然语言意图、忘名查询、需要外部证据或需要多步规划的查询。
    case smartDiscovery
}

/// Planner 生成的受控检索计划。
struct SearchDiscoveryPlan: Equatable, Hashable, Codable, Sendable {
    /// 面向诊断与 UI 的短意图描述，不进入原查询替换。
    let intentSummary: String
    /// 交给 GitHub 搜索的计划查询，服务层会去重并截断到预算上限。
    let githubQueries: [String]
    /// 交给外部搜索的计划查询，同样受预算约束。
    let webQueries: [String]
    /// “最近很火”这类辅助时效线索；true 不代表所有候选必须带新日期。
    let prefersFreshEvidence: Bool
    /// 明确时间 / 指标条件。非空时缺证据的候选不得声称满足这些条件。
    let strictConstraints: [String]
    /// Planner 不放宽用户在 Search Center 手动输入的 GitHub 筛选。
    let githubFilters: GitHubSearchFilters

    static let empty = SearchDiscoveryPlan(
        intentSummary: "",
        githubQueries: [],
        webQueries: [],
        prefersFreshEvidence: false,
        strictConstraints: [],
        githubFilters: .empty
    )

    /// 规范化只保留非空、去重后的查询，并按预算截断；调用方仍需按实际调用数计量。
    var normalized: SearchDiscoveryPlan {
        SearchDiscoveryPlan(
            intentSummary: intentSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            githubQueries: Self.normalizedQueries(githubQueries, limit: 2),
            webQueries: Self.normalizedQueries(webQueries, limit: 2),
            prefersFreshEvidence: prefersFreshEvidence,
            strictConstraints: strictConstraints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            githubFilters: githubFilters
        )
    }

    var isValid: Bool {
        let normalizedPlan = normalized
        return !normalizedPlan.intentSummary.isEmpty
            && !(normalizedPlan.githubQueries.isEmpty && normalizedPlan.webQueries.isEmpty)
    }

    private static func normalizedQueries(_ queries: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }
}

/// 证据来源只描述取得通道，不代表内容可信。
enum SearchEvidenceKind: String, Equatable, Hashable, Codable, Sendable {
    case github
    case web
    case readme
    case localNote
}

/// 智能发现可展示、可校验的一条证据。
struct SearchEvidence: Equatable, Hashable, Codable, Identifiable, Sendable {
    let id: String
    let kind: SearchEvidenceKind
    let title: String
    let url: URL?
    let snippet: String?
    let observedAt: Date

    init(
        id: String,
        kind: SearchEvidenceKind,
        title: String,
        url: URL? = nil,
        snippet: String? = nil,
        observedAt: Date = Date()
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.url = url
        self.snippet = snippet?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.observedAt = observedAt
    }

    /// 证据必须有稳定 ID、标题，以及 URL 或原文片段之一；否则不能进入候选解释。
    var isValid: Bool {
        !id.isEmpty && !title.isEmpty && (url != nil || !(snippet ?? "").isEmpty)
    }
}

/// 一轮发现的可解释诊断。正常达到上限不属于请求失败，不能点亮警告三角形。
///
/// 用户文案复用统一错误映射；底层原因经现有脱敏机制留存，只在主动展开时显示。
struct SearchDiscoveryDiagnostic: Equatable, Identifiable, Sendable {
    enum Stage: String, Equatable, Sendable {
        case planning
        case webSearch
        case githubSearch
        case verification
        case ranking

        var titleKey: String {
            switch self {
            case .planning: return "search.discovery.phase.planning"
            case .webSearch: return "search.scope.web"
            case .githubSearch: return "search.footer.source.github"
            case .verification: return "search.discovery.phase.verifying"
            case .ranking: return "search.discovery.phase.ranking"
            }
        }
    }

    enum Kind: Equatable, Sendable {
        case failure
        case limit
    }

    let id = UUID()
    let stage: Stage
    let kind: Kind
    let message: String
    var context: String? = nil
    var recovery: String? = nil
    var technicalDetail: String? = nil
    var statusCode: Int? = nil

    var isFailure: Bool { kind == .failure }

    var impactKey: String {
        "search.discovery.diagnostic.impact.\(stage.rawValue)"
    }

    /// 不直接显示 Error.localizedDescription，避免把传输细节或模型原文当成用户提示。
    static func failure(stage: Stage, error: Error, context: String? = nil) -> Self {
        let mappedError: Error
        switch error {
        case SearchIntentRouterError.missingPlannerCredential,
             RepositoryDiscoveryError.missingPlannerCredential,
             RepositoryDiscoveryError.missingRankerCredential:
            mappedError = AIClientError.missingAPIKey
        case SearchIntentRouterError.invalidPlan, RepositoryDiscoveryError.invalidRankerResponse(_):
            mappedError = NetworkError.decodingError(underlying: error)
        case SearchIntentRouterError.timeout:
            mappedError = URLError(.timedOut)
        default:
            mappedError = error
        }
        // 统一错误模板会把 operation 放进用户句子，须传可读步骤，不能泄露内部操作 ID。
        let service: String? = switch stage {
        case .githubSearch, .verification: "GitHub"
        case .planning, .ranking: "AI"
        case .webSearch: nil
        }
        let presentation = UserFacingError.map(
            mappedError,
            operation: String.l10n(stage.titleKey),
            service: service
        )
        var technicalDetail = presentation.diagnosticSummary
        if case RepositoryDiscoveryError.invalidRankerResponse(let detail) = error {
            technicalDetail = "Ranker response validation failed: \(detail)"
        }
        let diagnostic = Self(
            stage: stage,
            kind: .failure,
            message: presentation.message,
            context: context,
            recovery: presentation.recovery,
            technicalDetail: technicalDetail,
            statusCode: presentation.statusCode
        )
        diagnostic.record()
        return diagnostic
    }

    static func unavailable(stage: Stage) -> Self {
        let diagnostic = Self(
            stage: stage,
            kind: .failure,
            message: String.l10n("search.discovery.diagnostic.unavailable"),
            recovery: String.l10n("error.user.aiProvider.recovery.modelsSettings")
        )
        diagnostic.record()
        return diagnostic
    }

    static func limit(stage: Stage) -> Self {
        Self(
            stage: stage,
            kind: .limit,
            message: String.l10n(stage == .verification
                ? "search.discovery.diagnostic.verificationLimit"
                : "search.discovery.diagnostic.rankingLimit"),
            recovery: String.l10n("search.discovery.diagnostic.continue")
        )
    }

    /// 每次真实失败只记一次；缓存结果重复展示时不会生成新的失败证据。
    private func record() {
        DiagnosticLogStore.shared.enqueue(DiagnosticEvent(
            level: .warning,
            category: "search",
            operation: "search.discovery.\(stage.rawValue)",
            message: "Repository discovery step failed",
            statusCode: statusCode,
            underlying: technicalDetail,
            operationID: id.uuidString,
            phase: stage.rawValue,
            outcome: .failed,
            impact: .degraded
        ))
    }
}

/// 发现链路对一个仓库候选的增量解释，不覆盖关键词 / 语义分数。
struct SearchDiscoveryAnnotation: Equatable, Hashable, Codable, Sendable {
    /// 检索命中或 API 核验不代表经过模型相关性筛选，必须与真正的匹配理由分开。
    enum Kind: String, Codable, Sendable {
        case modelMatch
        case githubSearch
        case githubVerification
    }

    let kind: Kind
    /// Ranker 给出的简短理由，必须由服务层校验只陈述已核验事实。
    let reason: String
    /// 只能引用本轮输入给 Ranker 的证据 ID。
    let evidenceIDs: [String]
    /// 每轮内的重排位置；0 表示第一。
    let rank: Int?

    init(
        reason: String,
        evidenceIDs: [String],
        rank: Int? = nil,
        kind: Kind = .modelMatch
    ) {
        self.kind = kind
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.evidenceIDs = evidenceIDs
        self.rank = rank
    }

    func referencesOnly(_ evidence: [SearchEvidence]) -> Bool {
        let availableIDs = Set(evidence.map(\.id))
        return Set(evidenceIDs).isSubset(of: availableIDs)
    }
}

/// 智能发现阶段。状态文案在 UI 层做本地化，领域层只表达进度。
enum SearchDiscoveryPhase: Equatable, Hashable, Sendable {
    case routing
    case planning
    case searching
    case extractingCandidates
    case verifyingRepositories
    case ranking
    case completed
    case failed(String)
}

extension SearchDiscoveryPhase {
    /// UI 只需要一个稳定的“是否失败”信号，不暴露错误字符串给状态机判断。
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// 一轮智能发现的资源上限。预算由服务层集中扣减，避免各 Provider 自行放大请求。
struct SearchDiscoveryBudget: Equatable, Hashable, Sendable {
    let timeoutSeconds: TimeInterval
    let maxWebQueries: Int
    let maxGitHubQueries: Int
    let maxLLMCalls: Int
    let maxVerifiedRepositories: Int
    let maxRankedCandidates: Int

    static let firstRound = SearchDiscoveryBudget(
        timeoutSeconds: 15,
        maxWebQueries: 2,
        maxGitHubQueries: 2,
        maxLLMCalls: 3,
        maxVerifiedRepositories: 5,
        maxRankedCandidates: 20
    )

    var isValid: Bool {
        timeoutSeconds > 0
            && maxWebQueries >= 0
            && maxGitHubQueries >= 0
            && maxLLMCalls > 0
            && maxVerifiedRepositories > 0
            && maxRankedCandidates > 0
    }
}

/// 搜索会话中的一轮智能发现状态。generation 与 round 共同拒绝旧轮迟到响应。
struct SearchDiscoverySession: Equatable, Hashable, Sendable {
    let generation: UUID
    let round: Int
    let phase: SearchDiscoveryPhase
    let plan: SearchDiscoveryPlan?
    let evidence: [SearchEvidence]
    let usedLLMCalls: Int
    let usedWebQueries: Int
    let usedGitHubQueries: Int

    init(
        generation: UUID,
        round: Int,
        phase: SearchDiscoveryPhase = .routing,
        plan: SearchDiscoveryPlan? = nil,
        evidence: [SearchEvidence] = [],
        usedLLMCalls: Int = 0,
        usedWebQueries: Int = 0,
        usedGitHubQueries: Int = 0
    ) {
        self.generation = generation
        self.round = max(1, round)
        self.phase = phase
        self.plan = plan
        self.evidence = evidence
        self.usedLLMCalls = max(0, usedLLMCalls)
        self.usedWebQueries = max(0, usedWebQueries)
        self.usedGitHubQueries = max(0, usedGitHubQueries)
    }

    func canUseLLM(in budget: SearchDiscoveryBudget) -> Bool {
        usedLLMCalls < budget.maxLLMCalls
    }

    func canRunWebQuery(in budget: SearchDiscoveryBudget) -> Bool {
        usedWebQueries < budget.maxWebQueries
    }

    func canRunGitHubQuery(in budget: SearchDiscoveryBudget) -> Bool {
        usedGitHubQueries < budget.maxGitHubQueries
    }

    func isCurrent(generation candidateGeneration: UUID, round candidateRound: Int) -> Bool {
        generation == candidateGeneration && round == candidateRound
    }
}
