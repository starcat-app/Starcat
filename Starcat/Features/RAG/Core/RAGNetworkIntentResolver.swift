//
//  RAGNetworkIntentResolver.swift
//  Starcat
//
//  将 Planner 的概率性联网意图与 Composer 的显式联网授权收敛为可执行计划。
//
//  为什么需要本地兜底：Planner 即使收到“最新 open issues”也可能漏掉
//  `remoteContextRequests`。若执行层完全信任该字段，Generator 会拿 README 中的旧链接
//  回答实时问题。这里不尝试理解所有自然语言，只兜底 GitHub 有稳定结构化 API 的高置信
//  场景；普通互联网查询仍由 Planner 或用户主动开启的 `globe` 开关驱动。
//

import Foundation

enum RAGNetworkIntentResolver {
    /// 合并 Planner 结果与本地确定性约束。
    ///
    /// - GitHub 实时资源即使 Planner 漏报也会补齐，并标记为必须使用实时证据。
    /// - 普通 External Search 只有 Composer 明确开启时才保留；开启后若 Planner 没有提供
    ///   查询，则使用“显式仓库名 + 原问题”构造一条受限查询。
    /// - 纯问候已在 Service 更早处短路；能力说明等工作台元问题继续走引导，不因开关开启
    ///   而产生无意义网络请求。
    static func resolve(
        question: String,
        plan originalPlan: RAGQueryPlan,
        composerContext: RAGComposerContext
    ) -> RAGQueryPlan {
        var plan = originalPlan
        let normalizedQuestion = normalized(question)
        let resources = githubResources(in: normalizedQuestion)
        let hasLiveIntent = containsAny(normalizedQuestion, terms: liveIntentTerms)

        if hasLiveIntent, !resources.isEmpty, plan.mode != .needsClarification {
            let existingResources = Set(plan.remoteContextRequests.map(\.resource))
            let state = issueState(in: normalizedQuestion)
            let maxRepos = min(max(composerContext.explicitRepoReferences.count, 1), 5)
            let keywords = githubKeywords(
                from: normalizedQuestion,
                explicitRepositories: composerContext.explicitRepoReferences.map(\.fullName)
            )
            for resource in resources where !existingResources.contains(resource) {
                plan.remoteContextRequests.append(RAGRemoteContextRequest(
                    resource: resource,
                    query: resource == .githubIssues || resource == .githubPullRequests ? keywords : "",
                    reason: String.l10n("rag.workspace.network.reason.liveGitHub"),
                    maxRepos: maxRepos,
                    perRepoLimit: 10,
                    state: state,
                    sort: .updated,
                    order: .descending
                ))
            }
            plan.requiresLiveEvidence = true
        }

        plan.remoteContextRequests = normalizedRemoteRequests(plan.remoteContextRequests)

        // 关闭通用 Web 搜索并不等于禁用 GitHub 结构化实时查询。必须在下面的早退前
        // 恢复可执行模式，否则 Planner 一旦误判为 guided_discovery，补出的 GitHub 请求
        // 仍会被 Service 当作知识库外闲聊提前终止。
        if plan.mode == .guidedDiscovery, !plan.remoteContextRequests.isEmpty {
            plan.mode = .semanticOnly
            plan.semanticQuery = question.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard composerContext.webSearchEnabled else {
            plan.webSearchRequests = []
            return plan
        }
        guard plan.mode != .needsClarification else {
            plan.webSearchRequests = []
            return plan
        }
        guard !isWorkspaceMetaQuestion(normalizedQuestion) else {
            plan.webSearchRequests = []
            return plan
        }

        // GitHub 结构化 API 已经能精确回答时不再重复调用通用搜索引擎。这样既减少延迟，
        // 也避免网页摘要与 GitHub 现场状态互相冲突。
        if plan.remoteContextRequests.isEmpty {
            plan.webSearchRequests = normalizedWebRequests(
                plan.webSearchRequests,
                composerContext: composerContext
            )
            if plan.webSearchRequests.isEmpty {
                plan.webSearchRequests = [RAGWebSearchRequest(
                    query: webQuery(question: question, composerContext: composerContext),
                    reason: String.l10n("rag.workspace.network.reason.userEnabled"),
                    maxResults: 8
                )]
            }
            if hasLiveIntent {
                plan.requiresLiveEvidence = true
            }
        } else {
            plan.webSearchRequests = []
        }

        // Planner 的 guided_discovery 代表“知识库外”。执行层补出的结构化 GitHub 请求，
        // 或用户显式开启的普通 Web 请求，都说明本轮已有合法数据路径，应继续执行而不是
        // 被旧 Planner 结论提前终止。纯社交短句已在 Planner 之前被本地短路。
        if plan.mode == .guidedDiscovery,
           !plan.remoteContextRequests.isEmpty || !plan.webSearchRequests.isEmpty {
            plan.mode = .semanticOnly
            plan.semanticQuery = question.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return plan
    }

    private static func normalizedRemoteRequests(
        _ requests: [RAGRemoteContextRequest]
    ) -> [RAGRemoteContextRequest] {
        var seen = Set<RAGRemoteContextResource>()
        return requests.compactMap { request in
            // External Web 有独立模型，不能通过 GitHub Provider 的 repo 工作项执行。
            guard request.resource != .externalWeb, seen.insert(request.resource).inserted else { return nil }
            var normalizedRequest = request
            normalizedRequest.query = String(request.query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            normalizedRequest.reason = String(request.reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            normalizedRequest.maxRepos = min(max(request.maxRepos, 1), 5)
            normalizedRequest.perRepoLimit = min(max(request.perRepoLimit, 1), 10)
            return normalizedRequest
        }.prefix(3).map { $0 }
    }

    private static func normalizedWebRequests(
        _ requests: [RAGWebSearchRequest],
        composerContext: RAGComposerContext
    ) -> [RAGWebSearchRequest] {
        var seen = Set<String>()
        return requests.compactMap { request in
            let query = sanitizedWebQuery(request.query, composerContext: composerContext)
            guard !query.isEmpty else { return nil }
            let identity = normalized(query)
            guard seen.insert(identity).inserted else { return nil }
            return RAGWebSearchRequest(
                query: query,
                reason: String(request.reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)),
                maxResults: min(max(request.maxResults, 1), 10)
            )
        }.prefix(2).map { $0 }
    }

    private static func webQuery(question: String, composerContext: RAGComposerContext) -> String {
        let repositories = composerContext.webSearchRepoReferences.map(\.fullName)
        let trimmed = sanitizedWebQuery(question, composerContext: composerContext)
        guard !repositories.isEmpty else { return trimmed }
        return String("\(repositories.joined(separator: " ")) \(trimmed)".prefix(240))
    }

    /// Planner 必须知道私有仓库身份才能维持本地 `.only` 范围，但它的自由文本 query 不能
    /// 因此绕过 External Search 的隐私开关。执行前移除所有未进入出站白名单的完整仓库名；
    /// 用户原问题也走同一清洗，避免 fallback 路径成为旁路。
    private static func sanitizedWebQuery(
        _ rawQuery: String,
        composerContext: RAGComposerContext
    ) -> String {
        let allowedIDs = Set(composerContext.webSearchRepoReferences.map(\.id))
        var query = rawQuery
        for repo in composerContext.explicitRepoReferences where !allowedIDs.contains(repo.id) {
            query = query.replacingOccurrences(
                of: repo.fullName,
                with: " ",
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        }
        return String(query
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .prefix(240))
    }

    private static func githubResources(in question: String) -> [RAGRemoteContextResource] {
        var resources: [RAGRemoteContextResource] = []
        if containsAny(question, terms: issueTerms) { resources.append(.githubIssues) }
        if containsAny(question, terms: pullRequestTerms) { resources.append(.githubPullRequests) }
        if containsAny(question, terms: releaseTerms) { resources.append(.githubReleases) }
        if containsAny(question, terms: contributorTerms) { resources.append(.githubContributors) }
        if containsAny(question, terms: commitActivityTerms) { resources.append(.githubCommitActivity) }
        if containsAny(question, terms: securityTerms) { resources.append(.githubSecurityAdvisories) }
        return resources
    }

    private static func issueState(in question: String) -> RAGRemoteIssueState {
        if containsAny(question, terms: closedTerms) { return .closed }
        if containsAny(question, terms: openTerms) { return .open }
        return .all
    }

    /// GitHub Search 的 query 只能是关键词。仓库、资源、状态与排序 qualifier 由 Provider
    /// 固定注入；这里移除常见问句噪声，避免“这个项目最新的 open issues 是什么”被当成
    /// 中文全文关键词而返回 0 条。
    private static func githubKeywords(
        from question: String,
        explicitRepositories: [String]
    ) -> String {
        var value = question
        let removable = liveIntentTerms + issueTerms + pullRequestTerms + openTerms + closedTerms + [
            "这个项目", "该项目", "这个仓库", "该仓库", "是什么", "有哪些", "什么",
            "项目", "仓库", "请", "帮我", "查看", "列出", "的",
            "this project", "this repository", "project", "repository", "repo", "what",
            "which", "show", "list", "please", "are", "is", "the", "for", "of",
        ] + explicitRepositories.map { normalized($0) }
        for term in removable.sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(of: term, with: " ", options: [.caseInsensitive])
        }
        return value
            .components(separatedBy: CharacterSet.punctuationCharacters.union(.symbols))
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func isWorkspaceMetaQuestion(_ question: String) -> Bool {
        containsAny(question, terms: [
            "你能做什么", "你的功能", "如何使用", "怎么使用", "使用帮助",
            "what can you do", "how can you help", "how to use",
        ])
    }

    private static func containsAny(_ value: String, terms: [String]) -> Bool {
        terms.contains { value.contains($0) }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let liveIntentTerms = [
        "最新", "当前", "现在", "目前", "最近", "实时", "今天", "未关闭", "已关闭",
        "latest", "current", "currently", "recent", "today", "open", "closed",
    ]
    private static let issueTerms = ["open issues", "closed issues", "issue", "issues", "工单", "问题列表"]
    private static let pullRequestTerms = ["pull request", "pull requests", "合并请求", " pr ", "prs"]
    private static let releaseTerms = ["release", "releases", "发行版", "发布版本", "最新版本"]
    private static let contributorTerms = ["contributor", "contributors", "贡献者"]
    private static let commitActivityTerms = ["commit activity", "提交活动", "提交活跃度"]
    private static let securityTerms = ["security advisory", "security advisories", "安全公告", "安全漏洞"]
    private static let openTerms = ["open issues", "open issue", "open pull", "未关闭", "开放中", "待处理"]
    private static let closedTerms = ["closed issues", "closed issue", "closed pull", "已关闭", "已解决"]
}
