//
//  StarcatMCPAppOperations.swift
//  Starcat
//
//  将 App 的刷新与管理操作适配为公共命令。领域服务仍负责事务、限流和通知；
//  CLI 和 MCP 共用此入口，不在客户端重复业务判断。
//

import Foundation
import MCP

extension StarcatMCPPublicCatalog {
    /// 目录和执行器一起维护，动态 CLI 无需再为每个新增 App 操作编写命令分支。
    static let operationSpecs: [StarcatMCPPublicSpec] = [
        .init(name: "create_repo_share", summary: "Create a public repository share with the App's existing cached-summary, generation and publishing flow; returns the share URL.", properties: selector.merging(preview) { _, new in new }, permission: "write", network: "configured_ai_and_sharing", task: true),
        .init(name: "refresh_repo_health", summary: "Refresh repository health using the same latest-signal service as the App.", properties: selector.merging(preview) { _, new in new }, permission: "write", network: "github", task: true),
        .init(name: "refresh_repo_security", summary: "Refresh OpenSSF with the App's rate limiter and health follow-up.", properties: selector.merging(preview) { _, new in new }, permission: "write", network: "openssf", task: true),
        .init(name: "refresh_repo_star_history", summary: "Refresh Star history through the App's shared download and cache service.", properties: selector.merging(preview) { _, new in new }.merging(["range": string(["3m", "1y", "all"])]) { _, new in new }, permission: "write", network: "github", task: true),
        .init(name: "refresh_repo_insights", summary: "Refresh the repository insights using the App's providers, retries and access checks.", properties: selector.merging(preview) { _, new in new }, permission: "write", network: "github", task: true),
        .init(name: "refresh_trending", summary: "Fetch Trending and persist the same cache used by the App.", properties: preview.merging(["period": string(["daily", "weekly", "monthly"]), "language": string()]) { _, new in new }, permission: "write", network: "trending", task: true),
        .init(name: "refresh_discovery", summary: "Fetch the Discovery bulk snapshot through the App repository.", properties: preview, permission: "write", network: "discovery", task: true),
        .init(name: "refresh_weekly", summary: "Fetch Weekly through the App repository, including its cache fallback semantics.", properties: preview, permission: "write", network: "weekly", task: true),
        .init(name: "refresh_awesome", summary: "Refresh Awesome catalog and enabled managed sources; return individual source errors.", properties: preview, permission: "write", network: "discovery", task: true),
        .init(name: "set_awesome_sources", summary: "Update enabled Awesome source IDs through the App's subscription operation.", properties: preview.merging(["source_ids": .object(["type": .string("array"), "items": string(), "maxItems": .int(200)])]) { _, new in new }, required: ["source_ids"], permission: "write"),
        .init(name: "refresh_repo_recommendations", summary: "Refresh recommendations or load their next page in the current App service namespace.", properties: selector.merging(preview) { _, new in new }.merging(["next_page": boolean]) { _, new in new }, permission: "write", network: "recommend", task: true),
        .init(name: "scan_repo_skills", summary: "Scan repository Skill evidence through the App's shared scanner.", properties: selector.merging(preview) { _, new in new }, permission: "write", network: "github", task: true),
        .init(name: "rename_tag", summary: "Rename an existing tag by ID, retaining its repository associations.", properties: preview.merging(["id": string(), "name": string()]) { _, new in new }, required: ["id", "name"], permission: "write"),
        .init(name: "delete_tag", summary: "Delete a tag and its associations using the App repository transaction.", properties: preview.merging(["id": string()]) { _, new in new }, required: ["id"], permission: "write"),
        .init(name: "merge_tags", summary: "Merge source tag into target using the App's atomic merge transaction.", properties: preview.merging(["id": string(), "target_id": string()]) { _, new in new }, required: ["id", "target_id"], permission: "write"),
        .init(name: "save_collection", summary: "Create or update a smart collection with a structured App SmartCollectionRule JSON object.", properties: preview.merging([
            "id": string(), "name": string(), "icon": string(), "rule": .object(["type": .string("object")])
        ]) { _, new in new }, required: ["name", "rule"], permission: "write"),
        .init(name: "delete_collection", summary: "Delete a smart collection definition by ID, keeping repositories intact.", properties: preview.merging(["id": string()]) { _, new in new }, required: ["id"], permission: "write"),
        .init(name: "subscribe_release", summary: "Subscribe after priming current releases and cursor, without opening a system permission prompt.", properties: selector.merging(preview) { _, new in new }, permission: "write", network: "github", task: true),
        .init(name: "refresh_releases", summary: "Run the App's release check and deliver notifications using existing notification authorization.", properties: preview, permission: "write", network: "github", task: true),
        .init(name: "refresh_notifications", summary: "Synchronize the App's GitHub inbox.", properties: preview, permission: "write", network: "github", task: true),
        .init(name: "mark_notification_done", summary: "Mark a GitHub notification done using the App's remote mutation and local reconciliation.", properties: preview.merging(["id": string()]) { _, new in new }, required: ["id"], permission: "write", network: "github"),
        .init(name: "post_notification_comment", summary: "Post a comment to an Issue/PR thread using the same App conversation service.", properties: preview.merging(["id": string(), "body": string()]) { _, new in new }, required: ["id", "body"], permission: "write", network: "github"),
        .init(name: "set_issue_state", summary: "Close or reopen an Issue through the App's inbox service.", properties: preview.merging(["id": string(), "state": string(["open", "closed"])]) { _, new in new }, required: ["id", "state"], permission: "write", network: "github"),
        .init(name: "create_issue", summary: "Submit a GitHub Issue through the App's existing API client.", properties: selector.merging(preview) { _, new in new }.merging(["title": string(), "body": string()]) { _, new in new }, required: ["title"], permission: "write", network: "github"),
        .init(name: "list_rag_conversations", summary: "List persisted RAG conversations in the current account.", properties: pagination),
        .init(name: "get_rag_conversation", summary: "Read a persisted RAG conversation with a bounded message page.", properties: pagination.merging(["id": string()]) { _, new in new }, required: ["id"]),
        .init(name: "create_rag_conversation", summary: "Create a persisted RAG conversation; its ID can be used for later questions.", properties: preview.merging(["title": string()]) { _, new in new }, permission: "write"),
        .init(name: "delete_rag_conversation", summary: "Delete a RAG conversation with the App's answer cancellation, debug and draft cleanup.", properties: preview.merging(["id": string()]) { _, new in new }, required: ["id"], permission: "write"),
        .init(name: "rename_rag_conversation", summary: "Rename a RAG conversation, cancelling an in-flight automatic title.", properties: preview.merging(["id": string(), "title": string()]) { _, new in new }, required: ["id", "title"], permission: "write"),
        .init(name: "pin_rag_conversation", summary: "Set a conversation's pinned state using the App's ordering semantics.", properties: preview.merging(["id": string(), "pinned": boolean]) { _, new in new }, required: ["id", "pinned"], permission: "write"),
        .init(name: "ask_rag", summary: "Ask or continue a persisted conversation through the App's full RAG pipeline. Write access authorizes this request's remote context work; existing App privacy settings still apply.", properties: preview.merging(["id": string(), "question": string(), "repo_ids": ids]) { _, new in new }, required: ["id", "question"], permission: "write", network: "configured_rag_pipeline", task: true)
    ]
}

extension StarcatMCPPublicFacade {
    /// 只适配参数和返回值；耗时服务由 App 持有任务，断开终端后仍可查询结果。
    func callAppOperation(name: String, arguments: [String: Value], app: AppDependencies) async throws -> Value {
        let dryRun = arguments["dry_run"]?.boolValue ?? true
        let id = arguments["id"]?.stringValue ?? ""
        switch name {
        case "get_code_analysis", "prepare_codeflow", "index_codebase_memory":
            return try await callCodeGraphOperation(name: name, arguments: arguments, app: app)
        case "create_repo_share":
            let repo = try await resolve(arguments, app: app)
            if dryRun { return preview(name, target: .object(["repository": .string(repo.fullName), "public_link": .bool(true)])) }
            try app.entitlementGate.requirePro(.aiSummary, usesLocalOnly: app.settings.isSummaryTaskResolvedToLocalAI)
            return try tasks.start(kind: name) {
                let store = RepoShareTaskStore()
                let url = try await store.createAndWait(repo: repo, operations: app.makeRepoShareOperations())
                return .object(["url": .string(url), "repo_id": .int(Int(repo.id))])
            }
        case "refresh_repo_health", "refresh_repo_security", "refresh_repo_star_history", "refresh_repo_insights", "refresh_repo_recommendations", "scan_repo_skills", "subscribe_release":
            let repo = try await resolve(arguments, app: app)
            if dryRun { return preview(name, target: .object(["repo_id": .int(Int(repo.id)), "repository": .string(repo.fullName)])) }
            return try tasks.start(kind: name) {
                switch name {
                case "refresh_repo_health":
                    _ = try await app.repoHealthService.refreshWithLatestSignals(repo: repo)
                case "refresh_repo_security":
                    _ = try await app.openSSFScoreService.refresh(repo: repo)
                case "refresh_repo_star_history":
                    let range = arguments["range"]?.stringValue.flatMap(StarHistoryRange.init(rawValue:)) ?? .all
                    _ = try await app.repoStarHistoryRepository.refresh(repo: repo, range: range, forceRefresh: true)
                case "refresh_repo_insights":
                    let model = RepositoryInsightsViewModel(
                        provider: DefaultRepositoryLocalInsightsProvider(
                            releaseRepository: app.releaseRepository,
                            healthRepository: app.repoHealthRepository,
                            openSSFRepository: app.openSSFScoreRepository,
                            insightsCache: app.repositoryInsightsCache
                        ),
                        remoteProvider: app.repositoryRemoteInsightsProvider,
                        remoteAccessProvider: app.repositoryRemoteInsightsAccessProvider
                    )
                    let accepted = await model.refreshOperation(repo: repo, isAuthenticated: true)
                    let sections = [
                        "activity": Self.insightsStatus(model.activityState),
                        "release_cadence": Self.insightsStatus(model.releaseCadenceState),
                        "commits": Self.insightsStatus(model.commitActivityState),
                        "contributors": Self.insightsStatus(model.contributorsState),
                        "community": Self.insightsStatus(model.remoteCommunityState),
                        "security": Self.insightsStatus(model.securityAdvisoriesState),
                        "recent_activity": Self.insightsStatus(model.recentActivityState)
                    ]
                    return .object([
                        "repo_id": .int(Int(repo.id)), "refresh_accepted": .bool(accepted),
                        "completed": .bool(accepted && !sections.values.contains(where: { ["failed", "generating", "loading"].contains($0) })),
                        "sections": .object(sections.mapValues(Value.string))
                    ])
                case "refresh_repo_recommendations":
                    let service = app.recommendationContextService
                    let scope = await service.currentServiceScope()
                    if arguments["next_page"]?.boolValue == true,
                       let current = await service.cachedSnapshot(repoID: repo.id, serviceScope: scope) {
                        return try StarcatMCPJSON.value(await service.refreshNextPage(repoID: repo.id, currentSnapshot: current))
                    }
                    return try StarcatMCPJSON.value(await service.refresh(repoID: repo.id, serviceScope: scope))
                case "scan_repo_skills":
                    _ = try await app.repoSkillStore.detect(repo, force: true)
                default:
                    try await app.releaseMonitor.subscribe(repo: repo)
                }
                return .object(["completed": .bool(true), "repo_id": .int(Int(repo.id))])
            }
        case "refresh_trending", "refresh_discovery", "refresh_weekly", "refresh_awesome", "refresh_releases", "refresh_notifications":
            if dryRun { return preview(name, target: .object([:])) }
            return try tasks.start(kind: name) {
                switch name {
                case "refresh_trending":
                    let period = arguments["period"]?.stringValue.flatMap(TrendingPeriod.init(rawValue:)) ?? .daily
                    let language = TrendingLanguage(arguments["language"]?.stringValue ?? "")
                    _ = try await app.trendingRepository.fetchTrending(since: period, language: language)
                case "refresh_discovery":
                    _ = try await app.discoveryRepository.fetchBulk(ignoresCache: true)
                case "refresh_weekly":
                    _ = try await app.weeklyBulkRepository.fetchBulk()
                case "refresh_awesome":
                    _ = try await app.awesomeRepository.refreshCatalog(policy: .force)
                    let failures = await app.awesomeRepository.refreshEnabledEntries(policy: .force)
                    return .object(["source_errors": .object(failures.mapValues(Value.string)), "completed": .bool(failures.isEmpty)])
                case "refresh_releases":
                    let report = await app.releaseMonitor.runOnce()
                    await app.releaseNotificationService.dispatch(report.notifications)
                    return .object([
                        "new_release_count": .int(report.newReleasesByRepo.values.reduce(0, +)),
                        "repository_errors": .object(Dictionary(uniqueKeysWithValues: report.perRepoErrors.map { (String($0.key), Value.string($0.value.localizedDescription)) }))
                    ])
                default:
                    guard !app.githubNotificationInboxService.isSyncing else {
                        throw StarcatPublicCapabilityError(code: "SYNC_BUSY", message: "Notification synchronization is already running.")
                    }
                    await app.githubNotificationInboxService.sync()
                    if let message = app.githubNotificationInboxService.lastErrorMessage {
                        throw StarcatPublicCapabilityError(code: "SYNC_FAILED", message: message)
                    }
                }
                return .object(["completed": .bool(true)])
            }
        case "set_awesome_sources":
            let sourceIDs = Set(arguments["source_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            if dryRun { return preview(name, target: .array(sourceIDs.sorted().map(Value.string))) }
            try await app.awesomeRepository.updateSubscriptions(enabledSourceIDs: sourceIDs)
            return .object(["completed": .bool(true)])
        case "rename_tag", "delete_tag", "merge_tags":
            guard let tag = try await app.tagRepository.find(id: id) else { throw StarcatMCPError.notFound("Tag not found.") }
            if name == "merge_tags" {
                guard let target = try await app.tagRepository.find(id: arguments["target_id"]?.stringValue ?? ""), target.id != id else {
                    throw StarcatMCPError.invalidArguments("Choose a different existing target tag.")
                }
            }
            if dryRun { return preview(name, target: try StarcatMCPJSON.value(tag)) }
            let affectedRepoIDs = try await app.repoTagRepository.fetchAllTagIDsByRepo().filter { $0.value.contains(id) }.map(\.key)
            let management = TagManagementViewModel(tagRepository: app.tagRepository, repoTagRepository: app.repoTagRepository)
            if name == "rename_tag" {
                _ = await management.update(tag, name: try nonBlank(arguments, key: "name"), color: tag.color, icon: tag.icon)
            } else if name == "delete_tag" {
                await management.delete(ids: [id])
            } else {
                let targetID = arguments["target_id"]?.stringValue ?? ""
                await management.merge(sources: [id, targetID], into: targetID)
            }
            if let message = management.errorMessage {
                throw StarcatPublicCapabilityError(code: "TAG_OPERATION_FAILED", message: message)
            }
            for repoID in affectedRepoIDs {
                NotificationCenter.default.post(name: .repoTagsDidChange, object: nil, userInfo: ["repoId": repoID])
            }
            return .object(["completed": .bool(true), "id": .string(id)])
        case "save_collection":
            guard let ruleValue = arguments["rule"] else { throw StarcatMCPError.invalidArguments("A structured rule is required.") }
            let rule = try JSONDecoder().decode(SmartCollectionRule.self, from: JSONEncoder().encode(ruleValue))
            let collectionID = id.isEmpty ? UUID().uuidString.lowercased() : id
            let existing = try await app.smartCollectionRepository.find(id: collectionID)
            if !id.isEmpty, existing == nil { throw StarcatMCPError.notFound("Collection not found.") }
            let sortOrder: Int
            if let existing { sortOrder = existing.sortOrder }
            else { sortOrder = try await app.smartCollectionRepository.count() }
            let now = ISO8601DateFormatter.shared.string(from: Date())
            let collection = UserSmartCollection(
                id: collectionID, name: try nonBlank(arguments, key: "name"),
                icon: arguments["icon"]?.stringValue ?? existing?.icon ?? "line.3.horizontal.decrease.circle",
                color: existing?.color, ruleJSON: try SmartCollectionRule.encode(rule),
                sortOrder: sortOrder, createdAt: existing?.createdAt ?? now, updatedAt: now
            )
            if dryRun { return preview(name, target: try StarcatMCPJSON.value(collection)) }
            if existing == nil { try await app.smartCollectionRepository.create(collection) }
            else { try await app.smartCollectionRepository.update(collection) }
            return try StarcatMCPJSON.value(collection)
        case "delete_collection":
            guard let collection = try await app.smartCollectionRepository.find(id: id) else { throw StarcatMCPError.notFound("Collection not found.") }
            if dryRun { return preview(name, target: try StarcatMCPJSON.value(collection)) }
            try await app.smartCollectionRepository.delete(id: id)
            return .object(["completed": .bool(true), "id": .string(id)])
        case "mark_notification_done", "post_notification_comment", "set_issue_state":
            guard let record = try await app.githubNotificationThreadRepository.fetch(id: id) else { throw StarcatMCPError.notFound("Notification not found.") }
            if dryRun { return preview(name, target: .object(["id": .string(record.id), "repository": .string(record.repositoryFullName)])) }
            if name == "mark_notification_done" { try await app.githubNotificationInboxService.markThreadDone(id: id) }
            else if name == "set_issue_state" { try await app.githubNotificationInboxService.updateIssueState(threadId: id, state: arguments["state"]?.stringValue ?? "") }
            else { try await app.githubNotificationInboxService.postComment(threadId: id, body: try nonBlank(arguments, key: "body")) }
            return .object(["completed": .bool(true), "id": .string(id)])
        case "create_issue":
            let repo = try await resolve(arguments, app: app)
            let title = try nonBlank(arguments, key: "title")
            if dryRun { return preview(name, target: .object(["repository": .string(repo.fullName), "title": .string(title)])) }
            let issue = try await app.apiClient.createRepoIssue(owner: repo.owner, repo: repo.name, title: title, body: arguments["body"]?.stringValue)
            return .object(["number": .int(issue.number), "title": .string(issue.title), "url": .string("https://github.com/\(repo.fullName)/issues/\(issue.number)")])
        default:
            return try await callRAGOperation(name: name, arguments: arguments, app: app)
        }
    }

    /// JSON Schema 限制长度；领域字符串还需拒绝全空白值，避免操作“成功”却没有效果。
    func nonBlank(_ arguments: [String: Value], key: String) throws -> String {
        guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw StarcatMCPError.invalidArguments("\(key) must not be blank.")
        }
        return value
    }

    /// 保留原页面的分区失败/生成中语义，不能把“刷新函数已返回”投影成所有数据成功。
    static func insightsStatus<Content: Equatable & Sendable>(_ state: RepositoryRemoteInsightsSectionState<Content>) -> String {
        switch state {
        case .idle: "idle"
        case .loading: "loading"
        case .content: "content"
        case .stale: "stale"
        case .generating: "generating"
        case .unavailable: "unavailable"
        case .failed: "failed"
        }
    }

    static func insightsStatus<Content: Equatable & Sendable>(_ state: RepositoryInsightsSectionState<Content>) -> String {
        switch state {
        case .idle: "idle"
        case .loading: "loading"
        case .content: "content"
        case .empty: "empty"
        case .unavailable: "unavailable"
        case .failed: "failed"
        }
    }
}
