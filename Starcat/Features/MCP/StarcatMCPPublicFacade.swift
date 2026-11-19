//
//  StarcatMCPPublicFacade.swift
//  Starcat
//
//  公共目录的装配适配层。复用 App 已有 Repository、Capability、Renderer 与同步服务；
//  不直读数据库文件、不访问 CLI 文件系统、不复制领域业务到传输层。
//

import CryptoKit
import Foundation
import GRDB
import MCP

/// 弱持依赖容器避免容器 → MCP facade → 容器成环；任务切号屏障由 AppDependencies 调用。
@MainActor
final class StarcatMCPPublicFacade {
    private weak var dependencies: AppDependencies?
    private weak var facade: StarcatMCPFacade?
    let tasks = StarcatMCPTaskStore()
    private var sessionChanging = false
    /// 导出只返回随机身份；分块读取 App 生成的文件，不接受客户端提供本机文件路径。
    var diagnosticExports: [String: (url: URL, createdAt: Date)] = [:]
    var agentExecutions: [String: AgentWorkspaceViewModel] = [:]

    private let database: any DatabaseManaging
    private let signedInUserID: () -> Int64?

    /// 标签查询只依赖当前身份和数据库，隔离库可以经过相同的账户校验与读取路径。
    init(database: any DatabaseManaging, signedInUserID: @escaping () -> Int64?) {
        self.database = database
        self.signedInUserID = signedInUserID
    }

    convenience init(dependencies: AppDependencies, facade: StarcatMCPFacade) {
        self.init(database: dependencies.database, signedInUserID: { [weak dependencies] in dependencies?.authSession.state.user?.id })
        self.dependencies = dependencies
        self.facade = facade
    }

    /// 整个切库窗口都拒绝新调用；仅等待任务退出后立即解锁仍会留出异步切库空隙。
    func prepareForAccountChange() async {
        sessionChanging = true
        await tasks.cancelAllAndWait()
        agentExecutions.removeAll()
        for artifact in diagnosticExports.values { try? FileManager.default.removeItem(at: artifact.url) }
        diagnosticExports.removeAll()
    }

    func finishAccountChange(succeeded: Bool) {
        sessionChanging = !succeeded
    }

    func requireReadySession() throws {
        guard !sessionChanging else {
            throw StarcatPublicCapabilityError(code: "SESSION_CHANGING", message: "The account database is changing or unavailable.")
        }
    }

    func beginRequest() throws {
        try requireReadySession()
        try tasks.beginRequest()
    }

    func endRequest() {
        tasks.endRequest()
    }

    /// 输入结构由 Registry 校验；此处继续验证 selector、账号范围和每次执行的真实权限。
    func call(name: String, arguments: [String: Value]) async throws -> Value {
        try requireReadySession()
        switch name {
        case "get_tag_graph", "list_repos_by_tags":
            return try await tagGraphRead(name, arguments: arguments)
        default: break
        }
        guard let app = dependencies else { throw StarcatMCPError.unsupported("App services are unavailable.") }
        if StarcatMCPPublicCatalog.specs.first(where: { $0.name == name })?.permission == "write" {
            try StarcatMCPAccess.requireWrite(app.settings)
        }
        if name == "list_agent_runs" || StarcatMCPPublicCatalog.agentSpecs.contains(where: { $0.name == name }) {
            return try await callAgentOperation(name: name, arguments: arguments, app: app)
        }
        let limit = arguments["limit"]?.intValue ?? 20
        let offset = arguments["offset"]?.intValue ?? 0
        let dryRun = arguments["dry_run"]?.boolValue ?? true
        switch name {
        case "get_public_settings":
            return .object([
                "channel": .string(DistributionChannel.current.rawValue),
                "signed_in": .bool(app.authSession.state.user != nil),
                "companion_enabled": .bool(CompanionConfiguration.shared.isEnabled),
                "contract_version": .int(3),
                "read": .bool(true), "write": .bool(app.settings.mcpAllowWrites),
                "notifications_enabled": .bool(app.settings.notificationsEnabled),
                "external_search_allow_private_repos": .bool(app.settings.externalSearchAllowPrivateRepos),
                "auto_tidy": try StarcatMCPJSON.value(app.settings.autoTidySettings),
                "secrets_included": .bool(false)
            ])
        case "list_ai_providers", "configure_ai_provider", "get_local_models", "install_local_model", "pause_local_model", "delete_local_model",
             "get_cache_statistics", "clear_cache", "list_managed_skills", "import_skill", "update_skill",
             "remove_skill", "check_skill_updates", "set_public_settings", "export_diagnostics", "read_export_chunk":
            return try await callLocalOperation(name: name, arguments: arguments, app: app)
        case "get_task_status":
            return try tasks.status(id: arguments["task_id"]?.stringValue ?? "")
        case "get_task_result":
            return try tasks.result(id: arguments["task_id"]?.stringValue ?? "")
        case "cancel_task":
            try requireLocalWrites(app)
            let id = arguments["task_id"]?.stringValue ?? ""
            if dryRun { return preview(name, target: try tasks.status(id: id)) }
            return try tasks.cancel(id: id)
        case "get_sync_status":
            return syncStatus(app.syncManager)
        default:
            break
        }

        guard app.authSession.state.user != nil else {
            throw StarcatPublicCapabilityError(code: "AUTH_REQUIRED", message: "Sign in to Starcat first.")
        }
        switch name {
        case "get_repo_health":
            let repo = try await resolve(arguments, app: app)
            guard let snapshot = try await app.repoHealthRepository.snapshot(for: repo.id) else { return cached(nil) }
            return cached(.object([
                "repo_id": .int(Int(repo.id)), "overall_score": .double(snapshot.overallScore),
                "grade": .string(snapshot.grade), "maintenance_score": .double(snapshot.maintenanceScore),
                "popularity_score": .double(snapshot.popularityScore), "quality_score": .double(snapshot.qualityScore),
                "security_score": .double(snapshot.securityScore), "computed_at": .string(snapshot.computedAt),
                "stale_after": .string(snapshot.staleAfter), "fetch_status": .string(snapshot.fetchStatus.rawValue)
            ]))
        case "get_repo_security":
            let repo = try await resolve(arguments, app: app)
            guard let record = try await app.openSSFScoreRepository.record(for: repo.id) else { return cached(nil) }
            return cached(.object([
                "repo_id": .int(Int(repo.id)), "score": record.aggregateScore.map(Value.double) ?? .null,
                "fetch_status": .string(record.fetchStatus.rawValue), "fetched_at": .string(record.fetchedAt),
                "score_date": record.scoreDate.map(Value.string) ?? .null
            ]))
        case "get_repo_star_history":
            let repo = try await resolve(arguments, app: app)
            let points = try await app.repoStarHistoryRepository.points(repoId: repo.id)
            return try page(points, limit: limit, offset: offset)
        case "get_repo_insights":
            let repo = try await resolve(arguments, app: app)
            guard let dataset = arguments["dataset"]?.stringValue.flatMap(RepositoryInsightsDataset.init(rawValue:)) else {
                throw StarcatMCPError.invalidArguments("Unknown insight dataset.")
            }
            let range = arguments["range"]?.stringValue.flatMap(RepositoryInsightsRangeKey.init(rawValue:)) ?? .all
            let entry = try await app.repositoryInsightsCache.load(repoId: repo.id, dataset: dataset, range: range, as: Value.self)
            return cached(entry?.value)
        case "list_releases":
            if hasSelector(arguments) {
                let repo = try await resolve(arguments, app: app)
                return try page(await app.releaseRepository.fetch(forRepo: repo.id, limit: offset + limit + 1), limit: limit, offset: offset)
            }
            let rows = try await app.releaseRepository.fetchTimeline(limit: limit + 1, offset: offset)
            let values = try rows.map { row in
                Value.object(["repo": try StarcatMCPJSON.value(MCPRepoDTO(repo: row.repo)), "release": try StarcatMCPJSON.value(row.release)])
            }
            return pageValues(values, limit: limit, offset: offset, alreadyOffset: true)
        case "list_release_subscriptions":
            return try page(await app.releaseSubscriptionRepository.fetchAll(), limit: limit, offset: offset)
        case "list_notifications":
            let rows = try await app.githubNotificationThreadRepository.fetchAll(limit: offset + limit + 1)
            return pageValues(rows.map(Self.notification), limit: limit, offset: offset)
        case "list_activity_timeline":
            return try await Self.activityTimeline(arguments, repository: app.userRepoActivityRepository)
        case "get_notification":
            guard let record = try await app.githubNotificationThreadRepository.fetch(id: arguments["id"]?.stringValue ?? "") else {
                throw StarcatMCPError.notFound("Notification not found.")
            }
            return Self.notification(record)
        case "list_collections":
            return try page(await app.smartCollectionRepository.fetchAll(), limit: limit, offset: offset)
        case "list_languages":
            let scope = arguments["scope"]?.stringValue == "knowledge" ? SemanticIndexScope.knowledge : .starred
            let source = DatabaseRepositoryReadCapabilitySource(repository: app.repoRepository, scope: scope)
            let repos = try await source.list()
            let counts = Dictionary(grouping: repos, by: { $0.language ?? "" }).mapValues(\.count)
            return .array(counts.keys.sorted().map { .object(["language": .string($0), "count": .int(counts[$0] ?? 0)]) })
        case "list_trending":
            let period = arguments["period"]?.stringValue.flatMap(TrendingPeriod.init(rawValue:)) ?? .daily
            let language = TrendingLanguage(arguments["language"]?.stringValue ?? "")
            let rows = await app.trendingRepository.cachedTrending(since: period, language: language)
            let values = rows.map { row in
                Value.object([
                    "repo_id": .int(Int(row.ghRepoId)), "full_name": .string(row.fullName), "url": .string(row.url.absoluteString),
                    "description": row.description.map(Value.string) ?? .null,
                    "language": row.language.map(Value.string) ?? .null, "stars": .int(row.starsCount),
                    "stars_in_period": .int(row.starsInPeriod), "source": .string("trending")
                ])
            }
            var output = pageValues(values, limit: limit, offset: offset).objectValue ?? [:]
            output["cache_hit"] = .bool(await app.trendingRepository.lastRefreshedAt(since: period, language: language) != nil)
            return .object(output)
        case "list_discovery":
            let snapshot = await app.discoveryRepository.cachedBulk()
            let query = arguments["query"]?.stringValue ?? ""
            let rows = (snapshot?.repos ?? []).filter { query.isEmpty || $0.fullName.localizedCaseInsensitiveContains(query) }
            return try page(rows, limit: limit, offset: offset, cacheHit: snapshot != nil)
        case "list_weekly":
            let snapshot = await app.weeklyBulkRepository.cachedBulk()
            let query = arguments["query"]?.stringValue ?? ""
            let language = arguments["language"]?.stringValue
            let rows = (snapshot?.items ?? []).filter { row in
                (query.isEmpty || row.fullName.localizedCaseInsensitiveContains(query))
                    && (language == nil || row.card.language == language)
            }
            let values = rows.map { row in
                Value.object([
                    "repo": repositoryCard(row.card),
                    "sources": .array(row.sourceTypes.map { .string($0.rawValue) }),
                    "first_event_at": .string(row.firstEventAt), "latest_event_at": .string(row.latestEventAt),
                    "available": .bool(row.isAvailable)
                ])
            }
            var output = pageValues(values, limit: limit, offset: offset).objectValue ?? [:]
            output["cache_hit"] = .bool(snapshot != nil)
            return .object(output)
        case "list_awesome_sources":
            let sources = await app.awesomeRepository.sources()
            return pageValues(sources.map { source in
                .object([
                    "id": .string(source.id), "name": .string(source.displayName), "repo": .string(source.repoFullName),
                    "url": .string(source.repoURL.absoluteString), "enabled": .bool(source.isEnabled),
                    "available": .bool(source.isAvailable), "repository_count": .int(source.githubRepoCount),
                    "resource_count": .int(source.resourceEntryCount)
                ])
            }, limit: limit, offset: offset)
        case "list_awesome_repos":
            let page = await app.awesomeRepository.repositoryPage(sourceID: arguments["source_id"]?.stringValue, limit: limit + 1, offset: offset)
            let values = page.repositories.map { row in
                Value.object([
                    "repo_id": .int(Int(row.id)), "full_name": .string(row.fullName),
                    "description": row.description.map(Value.string) ?? .null, "language": row.language.map(Value.string) ?? .null,
                    "stars": .int(row.stars), "evidence": .array(row.evidence.map(awesomeEvidence))
                ])
            }
            return pageValues(values, limit: limit, offset: offset, alreadyOffset: true)
        case "list_awesome_resources":
            let rows = await app.awesomeRepository.resources(sourceID: arguments["source_id"]?.stringValue)
            return pageValues(rows.map { row in
                .object([
                    "id": .string(row.id), "title": .string(row.title), "url": .string(row.url.absoluteString),
                    "description": row.description.map(Value.string) ?? .null, "evidence": awesomeEvidence(row.evidence)
                ])
            }, limit: limit, offset: offset)
        case "list_knowledge_chunks":
            let repo = try await resolve(arguments, app: app, scope: .knowledge)
            let includeNotes = arguments["include_private_notes"]?.boolValue ?? false
            let rows = try await app.ragChunkRepository.fetchKnowledgeChunks(repoId: repo.id)
            let visible = rows.filter { includeNotes || $0.source != .notes }
            let values = visible.map { chunk in
                Value.object([
                    "id": .int(Int(chunk.id ?? 0)), "repo_id": .int(Int(chunk.repoId)),
                    "source": .string(chunk.source.rawValue), "title": .string(chunk.title),
                    "section_path": .string(chunk.sectionPath), "content": .string(chunk.content),
                    "embedding_state": .string(chunk.embeddingStatus.rawValue)
                ])
            }
            return pageValues(values, limit: limit, offset: offset)
        case "list_daily_radar_catalog", "list_daily_radar":
            return await radarPage(name, arguments: arguments, app: app)
        case "get_daily_radar_report":
            let id = arguments["id"]?.stringValue ?? ""
            guard !id.contains("/"), !id.contains("?"), !id.contains("#"), id != ".", id != ".." else {
                throw StarcatMCPError.invalidArguments("A report identifier is required.")
            }
            let parameters = [
                URLQueryItem(name: "language", value: arguments["language"]?.stringValue),
                URLQueryItem(name: "fallback", value: "false"),
                URLQueryItem(name: "revision", value: arguments["revision"]?.stringValue)
            ]
            let entry = await app.dailyRadarRepository.cached(
                DailyRadarReport.self, path: "/api/v1/daily-radar/reports/\(id)", parameters: parameters
            )
            return cached(entry.map { radarReport($0.value) })
        case "get_repo_recommendations":
            let repo = try await resolve(arguments, app: app)
            let scope = await app.recommendationContextService.currentServiceScope()
            guard let snapshot = await app.recommendationContextService.cachedSnapshot(repoID: repo.id, serviceScope: scope) else {
                return cached(nil)
            }
            var result = try page(snapshot.items, limit: limit, offset: offset).objectValue ?? [:]
            result["model_version"] = snapshot.modelVersion.map(Value.string) ?? .null
            result["upstream_has_more"] = .bool(snapshot.hasMore)
            result["upstream_next_offset"] = snapshot.nextOffset.map(Value.int) ?? .null
            result["stale"] = .bool(snapshot.freshness() == .stale)
            return .object(result)
        case "get_repo_skills":
            let repo = try await resolve(arguments, app: app)
            guard let scan = try await app.repoSkillStore.cachedScan(for: repo) else { return cached(nil) }
            return cached(.object([
                "repo_id": .int(Int(repo.id)), "commit_sha": .string(scan.commitSHA),
                "complete": .bool(scan.complete), "fresh": .bool(scan.isFresh(for: repo)),
                "skills": .array(scan.skills.map { skill in
                    .object([
                        "id": .string(skill.id), "name": .string(skill.name), "summary": .string(skill.summary),
                        "directory": .string(skill.directory), "manifest": .string(skill.manifest),
                        "file_count": .int(skill.files.count), "size_kb": .int(skill.sizeKB),
                        "files": .array(skill.files.map { .object([
                            "path": .string($0.path), "sha": .string($0.sha),
                            "size": $0.size.map(Value.int) ?? .null
                        ]) })
                    ])
                })
            ]))
        case "export_repo_skill_file", "export_repo_skill":
            let repo = try await resolve(arguments, app: app)
            guard let skill = try await app.repoSkillStore.cachedScan(for: repo)?.skills.first(where: {
                $0.id == arguments["skill_id"]?.stringValue
            }) else {
                throw StarcatMCPError.notFound("Loaded Skill not found; use get_repo_skills first.")
            }
            let file = skill.files.first { $0.path == arguments["path"]?.stringValue }
            if name == "export_repo_skill_file", file == nil {
                throw StarcatMCPError.notFound("Loaded Skill file not found; use get_repo_skills first.")
            }
            let filename = file?.name ?? "\(skill.name).zip"
            if dryRun {
                return preview(name, target: .object([
                    "skill_id": .string(skill.id), "filename": .string(filename),
                    "path": file.map { .string($0.path) } ?? .null,
                    "sha": file.map { .string($0.sha) } ?? .null
                ]))
            }
            pruneDiagnosticExports()
            let exporter = RepoSkillExporter(downloader: app.repoSkillStore.downloader(for: repo))
            return try tasks.start(kind: name) {
                let artifact: URL
                if let file {
                    artifact = try await exporter.export(file: file, skill: skill, repo: repo)
                } else {
                    artifact = try await exporter.export(skill: skill, repo: repo)
                }
                do {
                    try Task.checkCancellation()
                    let bytes = try artifact.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    let artifactID = UUID().uuidString.lowercased()
                    self.diagnosticExports[artifactID] = (artifact, Date())
                    return .object([
                        "artifact_id": .string(artifactID), "filename": .string(filename),
                        "bytes": .int(bytes), "retention_seconds": .int(3600)
                    ])
                } catch {
                    try? FileManager.default.removeItem(at: artifact)
                    throw error
                }
            }
        case "get_repo_library_state", "set_repo_library_state":
            let repo = try await resolve(arguments, app: app)
            let before = try await app.repoNoteRepository.fetchLibraryState(repoId: repo.id)
            if name == "get_repo_library_state" {
                return .object(["repo_id": .int(Int(repo.id)), "state": .string(before.rawValue)])
            }
            try requireLocalWrites(app)
            guard let state = arguments["state"]?.stringValue.flatMap(LibraryState.init(rawValue:)) else {
                throw StarcatMCPError.invalidArguments("A valid library state is required.")
            }
            let target: Value = .object([
                "repo_id": .int(Int(repo.id)), "before": .string(before.rawValue), "after": .string(state.rawValue)
            ])
            if dryRun { return preview(name, target: target) }
            try await app.repoNoteRepository.updateLibraryState(repoId: repo.id, state: state)
            let stored = try await app.repoNoteRepository.fetchLibraryState(repoId: repo.id)
            return .object([
                "repo_id": .int(Int(repo.id)), "state": .string(stored.rawValue), "applied": .bool(stored == state)
            ])
        case "get_repo_translation":
            let repo = try await resolve(arguments, app: app)
            guard let language = arguments["target_language"]?.stringValue.flatMap(ReadmeTranslationLanguage.init(rawValue:)) else {
                throw StarcatMCPError.invalidArguments("A translation language is required.")
            }
            let translation = try await app.readmeTranslationService.cachedTranslation(
                owner: repo.owner, repo: repo.name, targetLanguage: language,
                mode: arguments["mode"]?.stringValue.flatMap(ReadmeTranslationMode.init(rawValue:)) ?? .segmented,
                engine: arguments["engine"]?.stringValue.flatMap(ReadmeTranslationEngine.init(rawValue:)) ?? .ai
            )
            return cached(try translation.map(StarcatMCPJSON.value))
        case "start_translation":
            let request = try Self.translationRequest(arguments)
            if dryRun {
                return preview(name, target: .object([
                    "target_language": .string(request.targetLanguage.rawValue),
                    "segment_count": .int(request.sourceSegments.count), "engine": .string("ai"),
                    "may_consume_ai_quota": .bool(true), "repository_cache_modified": .bool(false)
                ]))
            }
            return try tasks.start(kind: name) {
                let existing = try await app.readmeTranslationService.cachedTranslation(
                    owner: request.cacheOwner, repo: request.cacheRepo,
                    targetLanguage: request.targetLanguage, mode: request.mode, engine: .ai
                )
                do {
                    return try StarcatMCPJSON.value(await app.readmeTranslationService.translate(
                        request: request, cached: existing
                    ))
                } catch ReadmeTranslationError.alreadyInTargetLanguage {
                    return .object(["already_in_target_language": .bool(true), "generated": .bool(false)])
                }
            }
        case "list_ai_models":
            let models = app.settings.aiProviderProfiles.flatMap { profile in
                profile.models.map { model in
                    Value.object([
                        "provider_id": .string(profile.id), "provider": .string(profile.provider.rawValue),
                        "provider_enabled": .bool(profile.isEnabled), "provider_verified": .bool(profile.isVerifiedConfiguration),
                        "model_id": .string(model.id), "model": .string(model.name),
                        "enabled": .bool(model.isEnabled), "capability": .string(model.capability.rawValue)
                    ])
                }
            }
            return pageValues(models, limit: limit, offset: offset)
        case "get_diagnostic_health":
            let snapshot = await DiagnosticLogStore.shared.snapshot()
            return .object([
                "storage": .object(snapshot.health.mapValues(Value.int)),
                "raw_logs_included": .bool(false), "network_used": .bool(false)
            ])
        case "knowledge_search":
            return try await knowledgeSearch(arguments, app: app)
        case "start_note_draft":
            let repo = try await resolve(arguments, app: app)
            let includeNotes = arguments["include_private_notes"]?.boolValue ?? false
            if dryRun {
                return preview(name, target: .object([
                    "repo_id": .int(Int(repo.id)), "includes_private_notes": .bool(includeNotes),
                    "may_consume_ai_quota": .bool(true), "note_saved": .bool(false)
                ]))
            }
            // 沿用 App 的就绪检查、README 预处理和生成器；草稿不能绕过笔记的确认写入。
            try app.repoAIInsightService.ensureNoteGenerationReady()
            return try tasks.start(kind: name) {
                let provider = RepoNoteAIReadmeProvider(repository: app.readmeRepository, readmeAPI: app.readmeAPI)
                let markdown = try await provider.markdown(for: repo)
                let prepared = ReadmePreprocessor.process(
                    markdown: markdown, maxLength: ReadmePreprocessor.defaultMaxLength
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prepared.isEmpty else { throw AIClientError.emptyResponse }
                var existingNote = ""
                if includeNotes {
                    existingNote = try await app.repoNoteRepository.find(repoId: repo.id)?.content ?? ""
                }
                let draft = try await app.repoAIInsightService.generateNoteDraft(
                    readmeMarkdown: prepared, existingNote: existingNote, onDelta: { _ in }
                )
                guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIClientError.emptyResponse
                }
                return .object([
                    "repo_id": .int(Int(repo.id)), "draft_markdown": .string(draft),
                    "includes_private_notes": .bool(includeNotes), "note_saved": .bool(false)
                ])
            }
        case "start_summary", "start_tag_suggestions":
            let repo = try await resolve(arguments, app: app)
            if dryRun { return preview(name, target: try StarcatMCPJSON.value(MCPRepoDTO(repo: repo))) }
            guard let facade else { throw StarcatMCPError.unsupported("AI services unavailable.") }
            return try tasks.start(kind: name, supportsCancellation: false) {
                if name == "start_summary" {
                    return try StarcatMCPJSON.value(await facade.generateRepoSummary(
                        repoID: repo.id, owner: nil, name: nil, allowExternalContext: false
                    ))
                }
                let generation = try await app.repoAIInsightService.generateInsight(
                    for: repo, includeSummary: false, includeTags: true, allowExternalContext: false
                )
                guard generation.tagErrorMessage == nil else {
                    throw StarcatPublicCapabilityError(code: "AI_GENERATION_FAILED", message: "Tag suggestion generation failed.")
                }
                return .object([
                    "repo_id": .int(Int(repo.id)), "suggestions": try StarcatMCPJSON.value(generation.insight.suggestedTags),
                    "applied": .bool(false)
                ])
            }
        case "start_sync":
            try requireLocalWrites(app)
            if dryRun { return preview(name, target: syncStatus(app.syncManager)) }
            guard let userID = app.authSession.state.user?.id else { throw StarcatMCPError.unsupported("Sign in first.") }
            guard !app.syncManager.isSyncing, !tasks.hasActive(kind: name) else {
                throw StarcatPublicCapabilityError(code: "TASK_CONFLICT", message: "Stars synchronization is already running.")
            }
            let force = arguments["force"]?.boolValue ?? false
            return try tasks.start(kind: name) {
                app.syncManager.performFullSync(userID: userID, force: force, trigger: .manual)
                do {
                    while app.syncManager.isSyncing {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try Task.checkCancellation()
                    if case .failed = app.syncManager.state {
                        throw StarcatPublicCapabilityError(code: "SYNC_FAILED", message: "Stars synchronization failed.")
                    }
                    if case .rateLimited = app.syncManager.state {
                        throw StarcatPublicCapabilityError(code: "RATE_LIMITED", message: "GitHub rate limit reached.")
                    }
                    return self.syncStatus(app.syncManager)
                } catch {
                    await app.syncManager.cancelAndWait()
                    throw error
                }
            }
        case "start_knowledge_index":
            try requireLocalWrites(app)
            let repo: Repo?
            if hasSelector(arguments) { repo = try await resolve(arguments, app: app, scope: .knowledge) }
            else { repo = nil }
            if dryRun {
                return preview(name, target: .object([
                    "scope": .string(repo == nil ? "knowledge" : "repository"),
                    "repo_id": repo.map { .int(Int($0.id)) } ?? .null,
                    "may_use_network": .bool(true), "may_consume_embedding_quota": .bool(true)
                ]))
            }
            guard !tasks.hasActive(kind: name) else {
                throw StarcatPublicCapabilityError(code: "TASK_CONFLICT", message: "A public Knowledge index task is already running.")
            }
            // withExclusiveWork 使用独立 Task；首版不假称父任务取消即可中断它。
            return try tasks.start(kind: name, supportsCancellation: false) {
                if let repo { try await app.knowledgeRAGIndexBuilder.rebuildRepository(repo) }
                else { try await app.knowledgeRAGIndexBuilder.rebuildKnowledgeBase() }
                return .object(["completed": .bool(true), "scope": .string(repo == nil ? "knowledge" : "repository")])
            }
        case "mark_release_read":
            try requireLocalWrites(app)
            let id = Int64(arguments["release_id"]?.intValue ?? 0)
            let isRead = arguments["is_read"]?.boolValue ?? true
            guard let record = try await app.releaseRepository.find(id: id) else {
                throw StarcatMCPError.notFound("Cached Release not found.")
            }
            _ = try await resolve(["repo_id": .int(Int(record.repoId))], app: app)
            let target: Value = .object([
                "release_id": .int(Int(id)), "repo_id": .int(Int(record.repoId)),
                "before": .bool(record.isRead), "is_read": .bool(isRead)
            ])
            if dryRun { return preview(name, target: target) }
            try await app.releaseRepository.markRead(releaseId: id, isRead: isRead)
            guard let stored = try await app.releaseRepository.find(id: id), stored.isRead == isRead else {
                throw StarcatPublicCapabilityError(code: "WRITE_VERIFICATION_FAILED", message: "Release read state could not be verified.")
            }
            return .object(["applied": .bool(true), "release": try StarcatMCPJSON.value(stored)])
        case "unsubscribe_release", "set_release_notifications":
            try requireLocalWrites(app)
            let repo = try await resolve(arguments, app: app)
            guard let subscription = try await app.releaseSubscriptionRepository.find(repoId: repo.id) else {
                throw StarcatMCPError.notFound("Release subscription not found.")
            }
            if dryRun { return preview(name, target: try StarcatMCPJSON.value(subscription)) }
            if name == "unsubscribe_release" { try await app.releaseSubscriptionRepository.unsubscribe(repoId: repo.id) }
            else { try await app.releaseSubscriptionRepository.setNotifyEnabled(repoId: repo.id, enabled: arguments["enabled"]?.boolValue ?? false) }
            return try StarcatMCPJSON.value(await app.releaseSubscriptionRepository.find(repoId: repo.id))
        case "export_repositories":
            guard let user = app.authSession.state.user else { throw StarcatMCPError.unsupported("Sign in first.") }
            let library = arguments["scope"]?.stringValue == "knowledge"
            let source = DatabaseRepositoryReadCapabilitySource(repository: app.repoRepository, scope: library ? .knowledge : .starred)
            let repos = try await source.list()
            let selected = Array(repos.prefix(limit))
            let html = arguments["format"]?.stringValue == "html"
            let content: String
            if library {
                content = html ? LibraryHTMLRenderer.render(repos: selected, user: user) : LibraryMarkdownRenderer.render(repos: selected, user: user)
            } else {
                content = html ? StarredHTMLRenderer.render(repos: selected, user: user) : StarredMarkdownRenderer.render(repos: selected, user: user)
            }
            return .object([
                "format": .string(html ? "html" : "markdown"), "content": .string(content),
                "count": .int(selected.count), "total": .int(repos.count),
                "truncated": .bool(selected.count < repos.count), "private_notes_included": .bool(false),
                "file_owner": .string("cli_device")
            ])
        default:
            return try await callAppOperation(name: name, arguments: arguments, app: app)
        }
    }

    /// 通用文本使用内容寻址的独立缓存，不能借调用方输入覆盖仓库 README 的 DOM 对齐结果。
    static func translationRequest(_ arguments: [String: Value]) throws -> ReadmeTranslationRequest {
        guard let language = arguments["target_language"]?.stringValue.flatMap(ReadmeTranslationLanguage.init(rawValue:)),
              language != .auto, let values = arguments["segments"]?.arrayValue else {
            throw StarcatMCPError.invalidArguments("Explicit language and text segments are required.")
        }
        let segments = try values.map { value -> ReadmeSourceSegment in
            guard let id = value.objectValue?["id"]?.stringValue,
                  let text = value.objectValue?["text"]?.stringValue,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StarcatMCPError.invalidArguments("Translation segments require non-empty IDs and text.")
            }
            return ReadmeSourceSegment(id: id, text: text)
        }
        guard !segments.isEmpty, Set(segments.map(\.id)).count == segments.count else {
            throw StarcatMCPError.invalidArguments("Translation segment IDs must be unique.")
        }
        let source = segments.map(\.text).joined(separator: "\n\n")
        // JSON 对象的键顺序默认不稳定；排序后再散列，避免相同文本随机错过缓存。
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(segments)).map { String(format: "%02x", $0) }.joined()
        return ReadmeTranslationRequest(
            cacheOwner: "starcat-cli", cacheRepo: digest, sourceHtml: source,
            sourceSegments: segments, targetLanguage: language, mode: .segmented, engine: .ai
        )
    }

    private func hasSelector(_ arguments: [String: Value]) -> Bool {
        ["repo_id", "owner", "name"].contains { arguments[$0] != nil }
    }

    func resolve(_ arguments: [String: Value], app: AppDependencies, scope: SemanticIndexScope = .all) async throws -> Repo {
        let source = DatabaseRepositoryReadCapabilitySource(repository: app.repoRepository, scope: scope)
        return try await RepositoryReadCapabilityExecutor(source: source).get(
            RepositoryCapabilitySelector(
                repoID: arguments["repo_id"]?.intValue.map(Int64.init),
                owner: arguments["owner"]?.stringValue, name: arguments["name"]?.stringValue
            )
        )
    }

    private func requireLocalWrites(_ app: AppDependencies) throws {
        try app.entitlementGate.requirePro(.mcpService)
        try StarcatMCPAccess.requireWrite(app.settings)
    }

    func preview(_ name: String, target: Value) -> Value {
        .object(["operation": .string(name), "dry_run": .bool(true), "applied": .bool(false), "target": target])
    }

    private func cached(_ value: Value?) -> Value {
        .object(["cache_hit": .bool(value != nil), "network_used": .bool(false), "data": value ?? .null])
    }

    private func page<T: Encodable>(_ rows: [T], limit: Int, offset: Int, cacheHit: Bool = true) throws -> Value {
        var output = pageValues(try rows.map(StarcatMCPJSON.value), limit: limit, offset: offset).objectValue ?? [:]
        output["cache_hit"] = .bool(cacheHit)
        return .object(output)
    }

    private func pageValues(_ rows: [Value], limit: Int, offset: Int, alreadyOffset: Bool = false) -> Value {
        let available = alreadyOffset ? rows : Array(rows.dropFirst(offset))
        let hasMore = available.count > limit
        return .object([
            "items": .array(Array(available.prefix(limit))), "limit": .int(limit), "offset": .int(offset),
            "has_more": .bool(hasMore), "next_offset": hasMore ? .int(offset + limit) : .null,
            "network_used": .bool(false)
        ])
    }

    /// 一次调用固定读取一个账户的数据库。分页边界以全量计数为准，最后一页没有游标。
    private func tagGraphRead(_ name: String, arguments: [String: Value]) async throws -> Value {
        guard let userID = signedInUserID() else {
            throw StarcatPublicCapabilityError(code: "AUTH_REQUIRED", message: "Sign in to Starcat first.")
        }
        let changing = StarcatPublicCapabilityError(code: "SESSION_CHANGING", message: "The account database is changing.")
        guard database.currentUserId == userID else { throw changing }
        let reader = database.writer
        let limit = arguments["limit"]?.intValue ?? 20
        let offset = arguments["offset"]?.intValue ?? 0
        var result: [String: Value]
        let matching: Int
        if name == "get_tag_graph" {
            let graph = try await reader.read { try TagGraphQuery.snapshot(in: $0) }
            let edges = graph.visibleEdges(minimum: arguments["min_shared_repos"]?.intValue ?? 1)
            matching = edges.count
            result = ["nodes": try StarcatMCPJSON.value(graph.nodes),
                      "edges": try StarcatMCPJSON.value(Array(edges.dropFirst(offset).prefix(limit))),
                      "total_edges": .int(graph.edges.count), "matching_edges": .int(matching)]
        } else {
            let ids = Set(arguments["tag_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let page = try await reader.read { try RepoTagIntersection.page(in: $0, tagIDs: ids, limit: limit, offset: offset) }
            matching = page.total
            result = ["items": try StarcatMCPJSON.value(page.items.map(MCPRepoDTO.init(repo:))), "total": .int(matching)]
        }
        try requireReadySession()
        guard signedInUserID() == userID, database.currentUserId == userID else { throw changing }
        let hasMore = offset < matching && matching - offset > limit
        result["limit"] = .int(limit)
        result["offset"] = .int(offset)
        result["has_more"] = .bool(hasMore)
        result["next_offset"] = hasMore ? .int(offset + limit) : .null
        result["network_used"] = .bool(false)
        return .object(result)
    }

    /// 公共查询只读取本地缓存，不改变 GUI 筛选，也不启动远端状态补全。
    static func activityTimeline(
        _ arguments: [String: Value],
        repository: any UserRepoActivityRepositoryProtocol
    ) async throws -> Value {
        let filter = GitHubNotificationFilter(
            eventTypes: Set(arguments["events"]?.arrayValue?.compactMap {
                $0.stringValue.flatMap(GitHubNotificationSegment.init(rawValue:))
            } ?? []),
            readState: arguments["read_state"]?.stringValue.flatMap(GitHubNotificationSegment.init(rawValue:)) ?? .all,
            issueState: arguments["issue_state"]?.stringValue.flatMap(GitHubNotificationSegment.init(rawValue:)) ?? .all,
            reasons: Set(arguments["reasons"]?.arrayValue?.compactMap {
                $0.stringValue.flatMap(GitHubNotificationSegment.init(rawValue:))
            } ?? []),
            libraryState: arguments["library_state"]?.stringValue.flatMap(GitHubNotificationSegment.init(rawValue:)) ?? .all
        )
        let cursor = arguments["cursor"]?.objectValue.map {
            GitHubInboxTimelineCursor(occurredAt: $0["occurred_at"]?.stringValue ?? "", id: $0["id"]?.stringValue ?? "")
        }
        let limit = arguments["limit"]?.intValue ?? 20
        let page = try await repository.fetchPage(filter: filter, cursor: cursor, limit: limit)
        let total = try await repository.timelineCount(filter: filter)
        let items = page.rows.map { row -> Value in
            let data: Value
            let source: String
            switch row {
            case .notification(let record, _):
                source = "notification"
                data = notification(record)
            case .activity(let item):
                source = "activity"
                data = .object([
                    "id": .string(item.record.id), "kind": .string(item.record.kind.rawValue),
                    "repo_id": .int(Int(item.record.repoId)), "repository": .string(item.record.fullName),
                    "url": .string(item.record.htmlUrl)
                ])
            }
            return .object(["source": .string(source), "occurred_at": .string(row.occurredAt), "data": data])
        }
        let nextCursor: Value = page.hasMore ? page.rows.last.map {
            .object(["occurred_at": .string($0.occurredAt), "id": .string($0.id)])
        } ?? .null : .null
        return .object([
            "items": .array(items), "limit": .int(limit), "total": .int(total),
            "has_more": .bool(page.hasMore), "next_cursor": nextCursor, "network_used": .bool(false)
        ])
    }

    private static func notification(_ record: GitHubNotificationThreadRecord) -> Value {
        .object([
            "id": .string(record.id), "repository": .string(record.repositoryFullName),
            "title": .string(record.subjectTitle), "type": .string(record.subjectType),
            "unread": .bool(record.unread), "source": .string(record.sourceKind),
            "number": record.subjectNumber.map(Value.int) ?? .null,
            "issue_state": record.issueState.map(Value.string) ?? .null,
            "excerpt": record.excerpt.map { .string(String($0.prefix(16_384))) } ?? .null,
            "url": record.htmlUrl.map(Value.string) ?? .null,
            "hydrated_at": record.hydratedAt.map(Value.string) ?? .null
        ])
    }

    /// 缓存查询复用 UI 的完整 query 与服务命名空间，不扫描磁盘寻找其它语言或账号缓存。
    private func radarPage(_ name: String, arguments: [String: Value], app: AppDependencies) async -> Value {
        let query = DailyRadarQuery(
            category: arguments["category"]?.stringValue, period: arguments["period"]?.stringValue ?? "daily",
            language: arguments["language"]?.stringValue ?? "en", fallback: arguments["fallback"]?.boolValue ?? false,
            dateFrom: arguments["date_from"]?.stringValue, dateTo: arguments["date_to"]?.stringValue,
            catalogRevision: arguments["catalog_revision"]?.stringValue, cursor: arguments["cursor"]?.stringValue,
            limit: arguments["limit"]?.intValue ?? 20
        )
        if name == "list_daily_radar_catalog" {
            guard let entry = await app.dailyRadarRepository.cached(
                DailyRadarCatalog.self, path: "/api/v1/daily-radar/catalog", parameters: query.catalogParameters
            ) else { return cached(nil) }
            return cached(.object([
                "catalog_revision": .string(entry.value.catalogRevision),
                "categories": .array(entry.value.categories.map {
                    .object(["id": .string($0.id), "title": .string($0.title), "period": .string($0.period)])
                }),
                "available_languages": .array(entry.value.availableLanguages.map(Value.string))
            ]))
        }
        guard let entry = await app.dailyRadarRepository.cached(
            DailyRadarPage.self, path: "/api/v1/daily-radar/reports", parameters: query.parameters
        ) else { return cached(nil) }
        return cached(.object([
            "catalog_revision": .string(entry.value.catalogRevision), "items": .array(entry.value.items.map(radarReport)),
            "total": .int(entry.value.total), "next_cursor": entry.value.nextCursor.map(Value.string) ?? .null
        ]))
    }

    private func radarReport(_ report: DailyRadarReport) -> Value {
        .object([
            "id": .string(report.id), "revision": .string(report.revision), "category": .string(report.category),
            "edition_date": .string(report.editionDate), "title": .string(report.title), "summary": .string(report.summary),
            "language": .string(report.contentLanguage), "markdown": report.markdown.map(Value.string) ?? .null,
            "source_url": report.source.map { .string($0.url.absoluteString) } ?? .null
        ])
    }

    /// 来源卡片不持有当前账号的收藏状态，只投影公开元数据，不能把临时 Repo 的 false 当真实状态。
    private func repositoryCard(_ card: StarcatRepoCardDTO) -> Value {
        .object([
            "repo_id": .int(Int(card.ghRepoId)), "full_name": .string(card.fullName),
            "description": card.description.map(Value.string) ?? .null,
            "language": card.language.map(Value.string) ?? .null,
            "github_stars": .int(card.stars), "forks": .int(card.forks),
            "url": .string((card.htmlUrl ?? GitHubURLs.repo(owner: card.owner, repo: card.repo)).absoluteString)
        ])
    }

    private func awesomeEvidence(_ evidence: AwesomeEntryEvidence) -> Value {
        .object([
            "source_id": .string(evidence.source.id), "title": .string(evidence.entryTitle),
            "section": .array(evidence.sectionPath.map(Value.string)),
            "source_url": .string((evidence.sourceAnchorURL ?? evidence.source.repoURL).absoluteString)
        ])
    }

    private func syncStatus(_ manager: SyncManager) -> Value {
        let state: String
        switch manager.state {
        case .idle: state = "idle"
        case .syncing: state = "running"
        case .completed: state = "succeeded"
        case .failed: state = "failed"
        case .rateLimited: state = "rate_limited"
        }
        return .object([
            "state": .string(state), "is_syncing": .bool(manager.isSyncing),
            "processed": manager.progress.map { .int($0.current) } ?? .null,
            "total": manager.progress?.total.map(Value.int) ?? .null,
            "page": manager.progress.map { .int($0.currentPage) } ?? .null
        ])
    }

    /// 私有笔记未获授权时整体排除该来源，连引用和 diagnostics 都不返回，避免事后删正文的漏网路径。
    private func knowledgeSearch(_ arguments: [String: Value], app: AppDependencies) async throws -> Value {
        let repoIDs = Array(Set(arguments["repo_ids"]?.arrayValue?.compactMap(\.intValue).map(Int64.init) ?? [])).sorted()
        for id in repoIDs { _ = try await resolve(["repo_id": .int(Int(id))], app: app, scope: .knowledge) }
        let includeNotes = arguments["include_private_notes"]?.boolValue ?? false
        let executor = try app.makeMCPKnowledgeSearchExecutor(includePrivateNotes: includeNotes)
        let result = try await executor.execute(.init(
            query: arguments["query"]?.stringValue ?? "", repositoryScopeIDs: repoIDs,
            explicitRepoIDs: repoIDs, explicitMode: .only, maxRepositories: 30
        ))
        let evidence = result.evidenceBlocks.map { block in
            Value.object([
                "marker": .string(block.marker), "repository": .string(block.repositoryName),
                "section": .string(block.sectionTitle), "content": .string(block.content),
                "chunk_ids": .array(block.chunkIDs.sorted().map { .int(Int($0)) })
            ])
        }
        return .object([
            "evidence": .array(evidence), "citations": .array(result.citations.map { citation in
                .object([
                    "marker": .string(citation.marker), "repository": .string(citation.repoFullName),
                    "repo_id": citation.repoID.map { .int(Int($0)) } ?? .null,
                    "chunk_id": citation.chunkID.map { .int(Int($0)) } ?? .null,
                    "section": .string(citation.sectionTitle), "source": .string(citation.source.rawValue),
                    "source_url": citation.sourceURL.map { .string($0.absoluteString) } ?? .null
                ])
            }),
            "limitations": .array(result.limitations.map(Value.string)),
            "repo_ids": .array(repoIDs.map { .int(Int($0)) }), "private_notes_included": .bool(includeNotes),
            "answer_generated": .bool(false)
        ])
    }
}
