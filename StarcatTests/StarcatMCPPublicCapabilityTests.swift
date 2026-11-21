//
//  StarcatMCPPublicCapabilityTests.swift
//  StarcatTests
//
//  验证公开契约的边界、默认预览和真实任务生命周期；使用可控闭包与时钟，
//  不读取用户数据库、不调用付费 AI、不触发系统授权。
//

import Foundation
import MCP
import Testing
@testable import Starcat

@MainActor
@Suite("Starcat public capabilities")
struct StarcatMCPPublicCapabilityTests {
    @Test("目录名称唯一，写入与生成默认预览，Schema 禁止未知参数")
    func catalogContract() throws {
        let specs = StarcatMCPPublicCatalog.specs
        #expect(Set(specs.map(\.name)).count == specs.count)
        #expect(specs.count >= 30)
        for spec in specs {
            #expect(["read", "write"].contains(spec.permission))
            #expect(spec.schema.objectValue?["additionalProperties"]?.boolValue == false)
            if spec.permission != "read" {
                #expect(spec.properties["dry_run"]?.objectValue?["default"]?.boolValue == true)
            }
            #expect(spec.tool.name == "starcat.\(spec.name)")
        }
    }

    @Test("默认读、默认关闭写；唯一开关覆盖全部写种类并即时生效")
    func twoPermissionBoundary() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test.public.access.\(UUID())")!)
        #expect(settings.mcpAllowWrites == false)
        #expect(throws: StarcatPublicCapabilityError.self) { try StarcatMCPAccess.requireWrite(settings) }
        settings.mcpAllowWrites = true
        try StarcatMCPAccess.requireWrite(settings)
        settings.mcpAllowWrites = false
        #expect(throws: StarcatPublicCapabilityError.self) { try StarcatMCPAccess.requireWrite(settings) }
    }

    @Test("Skill 评估仅进入 Direct 的工具目录，读与导出无网络，开始默认预览")
    func skillEvaluationCatalog() throws {
        let names: Set<String> = ["get_skill_evaluation", "export_skill_evaluation", "start_skill_evaluation"]
        let direct = StarcatMCPPublicCatalog.specs(for: .direct).filter { names.contains($0.name) }
        #expect(Set(direct.map(\.name)) == names)
        #expect(StarcatMCPPublicCatalog.specs(for: .appStore).allSatisfy { !names.contains($0.name) })
        for spec in direct where spec.name != "start_skill_evaluation" {
            #expect(spec.permission == "read")
            #expect(spec.network == "none")
        }
        let start = try #require(direct.first { $0.name == "start_skill_evaluation" })
        #expect(start.permission == "write")
        #expect(start.task)
        #expect(start.properties["dry_run"]?.objectValue?["default"] == .bool(true))
        try StarcatMCPInputValidator.validate(.object(evaluationArguments()), schema: start.schema)
        let invalidArguments: [[String: Value]] = [
            ["targets": .array([])],
            ["targets": .array([.object(["path": .string("/tmp/fixture")])])],
            ["model": .object(["provider_id": .string("fixture"), "endpoint": .string("https://example.invalid/v1"), "api_key": .string("fixture")])],
            ["destination": .string("/tmp/fixture")]
        ]
        for arguments in invalidArguments {
            let input = evaluationArguments().merging(arguments) { _, new in new }
            #expect(throws: StarcatMCPError.self) {
                try StarcatMCPInputValidator.validate(.object(input), schema: start.schema)
            }
        }
    }

    @Test("仓库 Skill 必须来自指定账号仓库的固定提交证据")
    func skillEvaluationPinnedCache() throws {
        let sha = String(repeating: "a", count: 40)
        let otherSHA = String(repeating: "b", count: 40)
        let skill = RepoSkill(
            repositoryID: 1, commitSHA: sha, directory: "notes/", name: "meeting-notes",
            summary: "", manifest: "", files: [], installationIssue: nil
        )
        let scan = RepoSkillScan(
            repositoryID: 1, commitSHA: sha, sourcePushedAt: nil, sourceBranch: "main",
            checkedAt: .now, complete: true, skills: [skill], diagnostics: [],
            manifestTotal: nil, manifestChecked: nil, version: RepoSkillScan.rulesVersion
        )
        let target: Value = .object(["repo_id": .int(1), "commit_sha": .string(sha), "skill_id": .string(skill.id)])
        let parsed = try StarcatMCPSkillEvaluationRequest(["mode": .string("security"), "targets": .array([target])])
        #expect(parsed.targets == [.repository(id: 1, commit: sha, skillID: skill.id)])
        #expect(try StarcatMCPSkillEvaluationRequest.cachedSkill(in: scan, repoID: 1, commit: sha, skillID: skill.id) == skill)
        #expect(throws: StarcatMCPError.self) {
            try StarcatMCPSkillEvaluationRequest.cachedSkill(in: scan, repoID: 2, commit: sha, skillID: skill.id)
        }
        #expect(throws: StarcatMCPError.self) {
            try StarcatMCPSkillEvaluationRequest.cachedSkill(in: scan, repoID: 1, commit: otherSHA, skillID: skill.id)
        }
        #expect(throws: StarcatMCPError.self) {
            try StarcatMCPSkillEvaluationRequest.cachedSkill(in: nil, repoID: 1, commit: sha, skillID: skill.id)
        }
        let invalidTargetLists: [[Value]] = [
            [target, target],
            [.object(["repo_id": .int(1), "commit_sha": .string("main"), "skill_id": .string(skill.id)])],
            [.object(["library_id": .string("/tmp/fixture")])],
            [.object(["repo_id": .int(1), "commit_sha": .string(sha), "skill_id": .string(skill.id), "library_id": .string(UUID().uuidString)])]
        ]
        for invalidTargets in invalidTargetLists {
            #expect(throws: StarcatMCPError.self) {
                try StarcatMCPSkillEvaluationRequest(["mode": .string("quick"), "targets": .array(invalidTargets)])
            }
        }
        #expect(throws: StarcatMCPError.self) {
            try StarcatMCPSkillEvaluationRequest(["mode": .string("similarity"), "targets": .array([target])])
        }
    }

    @Test("缓存报告及 JSON 导出限于所选仓库提交和本机 UUID")
    func skillEvaluationPinnedReports() throws {
        let sha = String(repeating: "a", count: 40)
        let repo = Repo(
            id: 1, owner: "sample", name: "meeting-notes", fullName: "sample/meeting-notes",
            description: nil, language: nil, starsCount: 0, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil, htmlUrl: "https://github.com/sample/meeting-notes",
            cloneUrl: nil, sshUrl: nil, isPrivate: false, isFork: false, isArchived: false,
            isStarred: true, pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil,
            cachedAt: nil, defaultBranch: "main"
        )
        let skill = RepoSkill(
            repositoryID: 1, commitSHA: sha, directory: "notes/", name: "meeting-notes",
            summary: "", manifest: "", files: [], installationIssue: nil
        )
        let repoTarget = SkillEvaluationTarget.repository(repo, skill)
        let libraryTarget = SkillEvaluationTarget.library(UUID())
        func cached(_ subject: SkillEvaluationSubject, version: String, stale: Bool) -> SkillEvaluationCached {
            SkillEvaluationCached(
                report: SkillEvaluationRecord(
                    id: UUID(), mode: .quick, subjects: [subject], names: [skill.name],
                    versions: [version], model: nil, createdAt: .now, state: .passed, checks: [], toolVersion: "1.0.1"
                ),
                stale: stale
            )
        }
        let exact = cached(repoTarget.identity, version: sha, stale: false)
        let previous = cached(repoTarget.identity, version: String(repeating: "b", count: 40), stale: true)
        let library = cached(libraryTarget.identity, version: "fixture-content", stale: true)
        let other = cached(.library(UUID()), version: "outside-scope", stale: false)
        let reports = StarcatMCPSkillEvaluationRequest.matchingReports(
            [exact, previous, library, other], targets: [repoTarget, libraryTarget]
        )
        #expect(reports.map { $0.report.id } == [exact.report.id, library.report.id])
        #expect(reports.map(\.stale) == [false, true])
        let data = try SkillEvaluationService.export(reports)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(sha))
        #expect(text.contains("fixture-content"))
        #expect(!text.contains("outside-scope"))
    }

    @Test("静态安全评估默认预览，显式执行只生成一个可由公共工具取消的批量句柄")
    func skillEvaluationPreviewAndTask() async throws {
        var arguments = evaluationArguments(mode: "security", count: 2)
        let request = try StarcatMCPSkillEvaluationRequest(arguments)
        let tasks = StarcatMCPTaskStore()
        var starts = 0
        let start: () throws -> Value = {
            starts += 1
            return try tasks.start(kind: "start_skill_evaluation") {
                try await Task.sleep(for: .seconds(600))
                return .null
            }
        }
        #expect(try request.model(nil, profiles: []) == nil)
        #expect(throws: StarcatMCPError.self) { try request.model(.object([:]), profiles: []) }
        let preview = try request.start(arguments: arguments, model: nil, apply: start, preview: { $0 })
        #expect(preview.objectValue?["may_download_scanner"] == .bool(true))
        #expect(preview.objectValue?["requires_model_consent"] == .bool(false))
        #expect(preview.objectValue?["targets"]?.arrayValue?.count == 2)
        #expect(starts == 0)
        arguments["dry_run"] = .bool(false)
        let handle = try request.start(arguments: arguments, model: nil, apply: start, preview: { $0 })
        let id = try #require(handle.objectValue?["task_id"]?.stringValue)
        #expect(starts == 1)
        #expect(try tasks.status(id: id).objectValue?["state"] == .string("queued"))
        #expect(try tasks.cancel(id: id).objectValue?["state"] == .string("cancelling"))
        await tasks.cancelAllAndWait()
    }

    @Test("AI 预览验证已配置端点，执行需要显式同意")
    func skillEvaluationConsent() throws {
        var arguments = evaluationArguments(mode: "rubric")
        let request = try StarcatMCPSkillEvaluationRequest(arguments)
        let endpoint = "https://example.invalid/v1"
        let profile = AIProviderProfile(
            id: "fixture", provider: .openAICompatible, baseURL: endpoint,
            models: [AIModelDescriptor(providerID: "fixture", name: "fixture-chat", capability: .chat, isEnabled: true)]
        )
        let fields: [String: Value] = ["provider_id": .string("fixture"), "endpoint": .string(endpoint), "chat": .string("fixture-chat")]
        #expect(throws: StarcatMCPError.self) {
            try request.model(.object(fields.merging(["endpoint": .string("https://other.invalid/v1")]) { _, new in new }), profiles: [profile])
        }
        let model = try request.model(.object(fields), profiles: [profile])
        #expect(model?.endpoint == endpoint)
        var applied = false
        let start: () -> Value = {
            applied = true
            return .null
        }
        let preview = try request.start(arguments: arguments, model: model, apply: start, preview: { $0 })
        #expect(preview.objectValue?["model_endpoint"] == .string(endpoint))
        #expect(preview.objectValue?["chat_model"] == .string("fixture-chat"))
        #expect(preview.objectValue?["requires_model_consent"] == .bool(true))
        arguments["dry_run"] = .bool(false)
        #expect(throws: StarcatPublicCapabilityError.self) {
            try request.start(arguments: arguments, model: model, apply: start, preview: { $0 })
        }
        #expect(!applied)
        arguments["consent"] = .bool(true)
        _ = try request.start(arguments: arguments, model: model, apply: start, preview: { $0 })
        #expect(applied)
    }

    private func evaluationArguments(mode: String = "quick", count: Int = 1) -> [String: Value] {
        [
            "mode": .string(mode),
            "targets": .array((0..<count).map { _ in .object(["library_id": .string(UUID().uuidString)]) })
        ]
    }

    @Test("仓库 Skill 文件导出使用写权限和默认预览，不接受客户端路径")
    func skillFileExportContract() throws {
        let spec = try #require(StarcatMCPPublicCatalog.specs.first { $0.name == "export_repo_skill_file" })
        #expect(spec.permission == "write")
        #expect(spec.task)
        let input: Value = .object([
            "repo_id": .int(1), "skill_id": .string("1:commit:skills/review/"), "path": .string("SKILL.md")
        ])
        try StarcatMCPInputValidator.validate(input, schema: spec.schema)
        #expect(throws: StarcatMCPError.self) {
            try StarcatMCPInputValidator.validate(.object([
                "repo_id": .int(1), "skill_id": .string("id"), "path": .string("SKILL.md"),
                "destination": .string("/tmp/client")
            ]), schema: spec.schema)
        }
    }

    @Test("System One schema 兼容 Jev state，写权限默认 dry run")
    func systemOneSchema() throws {
        let spec = try #require(StarcatMCPPublicCatalog.specs.first { $0.name == "evaluate_system_one" })
        #expect(spec.permission == "write")
        #expect(spec.schema.objectValue?["required"] == .array([.string("state"), .string("questions")]))
        for state: Value in [.string("checkout"), .object(["text": .string("demo")]), .array([.string("demo")])] {
            try StarcatMCPInputValidator.validate(.object([
                "state": state,
                "questions": .object(["q": .object(["type": .string("noul"), "instructions": .string("demo")])]),
                "dry_run": .bool(true)
            ]), schema: spec.schema)
        }
        #expect(throws: StarcatMCPError.self) {
            try StarcatMCPInputValidator.validate(.object([
                "state": .object(["text": .string("demo")]),
                "questions": .object(["q": .object(["type": .string("noul")])]),
                "model": .string("caller-model"),
                "unknown": .bool(true)
            ]), schema: spec.schema)
        }
    }

    @Test("整个 Skill 导出只接受已加载 Skill 标识，不接受本地输出路径")
    func skillArchiveExportContract() throws {
        let spec = try #require(StarcatMCPPublicCatalog.specs.first { $0.name == "export_repo_skill" })
        #expect(spec.permission == "write")
        #expect(spec.task)
        try StarcatMCPInputValidator.validate(.object([
            "repo_id": .int(1), "skill_id": .string("1:commit:skills/review/")
        ]), schema: spec.schema)
        #expect(throws: StarcatMCPError.self) {
            try StarcatMCPInputValidator.validate(.object([
                "repo_id": .int(1), "skill_id": .string("id"), "path": .string("/tmp/client.zip")
            ]), schema: spec.schema)
        }
    }

    @Test("旧本地写设置只迁移一次，不保留细分权限；旧 Star 单独授权不扩大权限")
    func oldPermissionsMigrateOnce() throws {
        for (oldLocal, oldStar, expected) in [(true, false, true), (false, true, false)] {
            let defaults = UserDefaults(suiteName: "test.public.migration.\(UUID())")!
            defaults.set(oldLocal, forKey: "settings.mcp.allowLocalWrites.v1")
            defaults.set(oldStar, forKey: "settings.mcp.allowGitHubStarWrites.v1")
            defaults.set(false, forKey: "settings.mcp.exposePrivateNotes.v1")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.mcpAllowWrites == expected)
            #expect(defaults.object(forKey: "settings.mcp.allowLocalWrites.v1") == nil)
            #expect(defaults.object(forKey: "settings.mcp.exposePrivateNotes.v1") == nil)
            settings.mcpAllowWrites = !expected
            #expect(AppSettings(defaults: defaults).mcpAllowWrites == !expected)
        }
    }

    @Test("服务端拒绝错误类型、未知参数、越界和缺少必填，不依赖 CLI 校验")
    func schemaBoundary() throws {
        let schema = try #require(StarcatMCPPublicCatalog.specs.first { $0.name == "knowledge_search" }).schema
        let valid: Value = .object(["query": .string("SQLite"), "repo_ids": .array([.int(1)])])
        try StarcatMCPInputValidator.validate(valid, schema: schema)
        for invalid: Value in [
            .object(["query": .bool(true), "repo_ids": .array([.int(1)])]),
            .object(["query": .string("SQLite"), "repo_ids": .array([.int(0)])]),
            .object(["query": .string("SQLite"), "repo_ids": .array([])]),
            .object(["query": .string("SQLite")]),
            .object(["query": .string("SQLite"), "repo_ids": .array([.int(1)]), "raw_sql": .string("no")])
        ] {
            #expect(throws: StarcatMCPError.self) {
                try StarcatMCPInputValidator.validate(invalid, schema: schema)
            }
        }
    }

    @Test("时间线组合筛选限定选项所属分组，并校验游标与分页边界")
    func activityTimelineSchema() throws {
        let spec = try #require(StarcatMCPPublicCatalog.specs.first { $0.name == "list_activity_timeline" })
        #expect(spec.permission == "read")
        #expect(spec.network == "none")
        try StarcatMCPInputValidator.validate(.object([
            "events": .array([.string("issue"), .string("pullRequest"), .string("star")]),
            "read_state": .string("unread"), "issue_state": .string("open"),
            "reasons": .array([.string("mention"), .string("review")]),
            "library_state": .string("inLibrary"), "limit": .int(2),
            "cursor": .object(["occurred_at": .string("2026-11-17T10:00:00Z"), "id": .string("n-2")])
        ]), schema: spec.schema)
        try StarcatMCPInputValidator.validate(.object(["events": .array([]), "reasons": .array([])]), schema: spec.schema)
        for invalid: Value in [
            .object(["events": .array([.string("unread")])]),
            .object(["events": .string("issue")]),
            .object(["reasons": .array([.string("star")])]),
            .object(["read_state": .string("closed")]),
            .object(["issue_state": .string("unread")]),
            .object(["library_state": .string("open")]),
            .object(["limit": .int(0)]),
            .object(["limit": .int(201)]),
            .object(["cursor": .object(["id": .string("n-2")])]),
            .object(["cursor": .object(["occurred_at": .string("time"), "id": .string("id"), "offset": .int(1)])]),
            .object(["offset": .int(0)])
        ] {
            #expect(throws: StarcatMCPError.self) {
                try StarcatMCPInputValidator.validate(invalid, schema: spec.schema)
            }
        }
    }

    @Test("公共时间线复用本地组合查询，返回混合来源、总数和可续页游标")
    func activityTimelineResults() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBUserRepoActivityRepository(database: database)
        let threads = GRDBGitHubNotificationThreadRepository(database: database)
        let timestamp = "2026-11-17T10:00:00Z"
        let records = [("n-z", "mention"), ("n-m", "team_mention"), ("n-a", "comment")].map { id, reason in
            GitHubNotificationMapper.record(
                from: GitHubNotificationThreadDTO(
                    id: id, unread: true, reason: reason, updatedAt: timestamp,
                    subject: GitHubNotificationSubjectDTO(
                        title: id, url: "https://api.github.com/repos/o/r/issues/1",
                        latestCommentUrl: nil, type: "Issue"
                    ),
                    repository: GitHubNotificationRepositoryDTO(
                        id: 1, fullName: "o/r", name: "r", owner: GitHubNotificationOwnerDTO(login: "o")
                    )
                ),
                fetchedAt: timestamp, firstSeenAt: timestamp
            )
        }
        try await threads.upsertMany(records)
        try await repository.recordSyncedStars([
            UserRepoActivityStarDraft(repoID: 1, fullName: "o/r", htmlURL: "https://github.com/o/r", occurredAt: timestamp)
        ], actor: UserRepoActivityActor(userID: 1, userName: "tester"))
        let mixed = try await StarcatMCPPublicFacade.activityTimeline([
            "events": .array([.string("issue"), .string("star")])
        ], repository: repository)
        #expect(mixed.objectValue?["total"]?.intValue == 4)
        #expect(Set(mixed.objectValue?["items"]?.arrayValue?.compactMap {
            $0.objectValue?["source"]?.stringValue
        } ?? []) == ["notification", "activity"])

        var arguments: [String: Value] = [
            "events": .array([.string("issue"), .string("star")]),
            "read_state": .string("unread"), "reasons": .array([.string("mention")]), "limit": .int(1)
        ]
        let first = try await StarcatMCPPublicFacade.activityTimeline(arguments, repository: repository)
        #expect(first.objectValue?["total"]?.intValue == 2)
        #expect(first.objectValue?["has_more"]?.boolValue == true)
        #expect(first.objectValue?["network_used"]?.boolValue == false)
        #expect(first.objectValue?["items"]?.arrayValue?.first?.objectValue?["data"]?.objectValue?["id"]?.stringValue == "n-z")
        arguments["cursor"] = try #require(first.objectValue?["next_cursor"])
        let second = try await StarcatMCPPublicFacade.activityTimeline(arguments, repository: repository)
        #expect(second.objectValue?["total"]?.intValue == 2)
        #expect(second.objectValue?["has_more"]?.boolValue == false)
        #expect(second.objectValue?["next_cursor"] == .null)
        #expect(second.objectValue?["items"]?.arrayValue?.first?.objectValue?["data"]?.objectValue?["id"]?.stringValue == "n-m")
        let empty = try await StarcatMCPPublicFacade.activityTimeline([
            "events": .array([.string("star")]), "read_state": .string("unread")
        ], repository: repository)
        #expect(empty.objectValue?["total"]?.intValue == 0)
        #expect(empty.objectValue?["items"]?.arrayValue?.isEmpty == true)
    }

    @Test("任务由 App 保留结果，完成前不能读取，过期后明确失效")
    func taskResultsAndExpiry() async throws {
        var clock = Date()
        let store = StarcatMCPTaskStore(now: { clock })
        let handle = try store.start(kind: "fixture") { .object(["answer": .int(42)]) }
        let id = try #require(handle.objectValue?["task_id"]?.stringValue)
        #expect(throws: StarcatPublicCapabilityError.self) {
            try store.result(id: id)
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(try store.status(id: id).objectValue?["state"]?.stringValue == "succeeded")
        #expect(try store.result(id: id).objectValue?["result"]?.objectValue?["answer"]?.intValue == 42)
        clock = clock.addingTimeInterval(3601)
        #expect(throws: StarcatPublicCapabilityError.self) { try store.status(id: id) }
    }

    @Test("文本翻译输入唯一且缓存与仓库隔离，不启动 WebView 或系统翻译")
    func translationRequestContract() throws {
        let input: [String: Value] = [
            "target_language": .string("zh-Hans"),
            "segments": .array([.object(["id": .string("first"), "text": .string("A useful project.")])])
        ]
        let request = try StarcatMCPPublicFacade.translationRequest(input)
        #expect(request.cacheOwner == "starcat-cli")
        #expect(request.cacheRepo.count == 64)
        #expect(request.repoId == nil)
        #expect(request.engine == .ai)
        #expect(request.sourceSegments.first?.text == "A useful project.")
        for _ in 0..<20 {
            #expect(try StarcatMCPPublicFacade.translationRequest(input).cacheRepo == request.cacheRepo)
        }
        var changed = input
        changed["segments"] = .array([.object(["id": .string("first"), "text": .string("Changed source.")])])
        #expect(try StarcatMCPPublicFacade.translationRequest(changed).cacheRepo != request.cacheRepo)
        var duplicate = input
        duplicate["segments"] = .array([
            .object(["id": .string("same"), "text": .string("First")]),
            .object(["id": .string("same"), "text": .string("Second")])
        ])
        #expect(throws: StarcatMCPError.self) { try StarcatMCPPublicFacade.translationRequest(duplicate) }
        var automatic = input
        automatic["target_language"] = .string("auto")
        #expect(throws: StarcatMCPError.self) { try StarcatMCPPublicFacade.translationRequest(automatic) }
    }

    @Test("支持取消的任务先进入 cancelling，切号等待退出后清除结果")
    func cancelAndAccountBarrier() async throws {
        let store = StarcatMCPTaskStore()
        let handle = try store.start(kind: "fixture") {
            try await Task.sleep(for: .seconds(600))
            return .null
        }
        let id = try #require(handle.objectValue?["task_id"]?.stringValue)
        #expect(try store.cancel(id: id).objectValue?["state"]?.stringValue == "cancelling")
        await store.cancelAllAndWait()
        #expect(throws: StarcatPublicCapabilityError.self) { try store.status(id: id) }
        let next = try store.start(kind: "new_account") { .null }
        #expect(next.objectValue?["task_id"]?.stringValue != id)
        await store.cancelAllAndWait()
    }

    @Test("不可取消任务明确拒绝，笔记结果按默认读权限返回，错误不伪装成功")
    func unsupportedCancellationAndPrivacy() async throws {
        let store = StarcatMCPTaskStore()
        let handle = try store.start(kind: "fixture", supportsCancellation: false) { .string("private fixture") }
        let id = try #require(handle.objectValue?["task_id"]?.stringValue)
        #expect(throws: StarcatPublicCapabilityError.self) { try store.cancel(id: id) }
        for _ in 0..<10 { await Task.yield() }
        #expect(try store.result(id: id).objectValue?["result"]?.stringValue == "private fixture")
        let failed = try store.start(kind: "failed") {
            throw StarcatPublicCapabilityError(code: "FIXTURE_FAILURE", message: "fixture")
        }
        let failedID = try #require(failed.objectValue?["task_id"]?.stringValue)
        for _ in 0..<10 { await Task.yield() }
        #expect(try store.status(id: failedID).objectValue?["state"]?.stringValue == "failed")
        #expect(try store.status(id: failedID).objectValue?["error_code"]?.stringValue == "FIXTURE_FAILURE")
    }

    @Test("切号等待已接受的普通请求退出，并拒绝切换期间的新请求与任务")
    func inFlightRequestAccountBarrier() async throws {
        let store = StarcatMCPTaskStore()
        try store.beginRequest()
        var finished = false
        let change = Task { @MainActor in
            await store.cancelAllAndWait()
            finished = true
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(!finished)
        #expect(throws: StarcatPublicCapabilityError.self) { try store.beginRequest() }
        #expect(throws: StarcatPublicCapabilityError.self) { try store.start(kind: "late") { .null } }
        store.endRequest()
        await change.value
        #expect(finished)
        try store.beginRequest()
        store.endRequest()
    }
}
