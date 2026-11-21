//
//  StarcatMCPLocalOperations.swift
//  Starcat
//
//  本机模型、Skill、缓存、设置和诊断的公共适配。所有文件属于 App 所在设备；
//  安装、卸载和导出沿用原领域服务，不解释或执行调用方提供的脚本。
//

import Foundation
import MCP

extension StarcatMCPPublicCatalog {
    static let localSpecs: [StarcatMCPPublicSpec] = [
        .init(name: "list_ai_providers", summary: "Read AI provider profiles and model metadata; credentials are never returned.", properties: [:]),
        .init(name: "configure_ai_provider", summary: "Create or update a provider after the App's connection/model verification, securely storing its key. Send api_key through JSON stdin; keys are never returned.", properties: preview.merging([
            "id": string(), "provider": string(AIServiceProvider.allCases.map(\.rawValue)),
            "display_name": string(), "base_url": string(), "api_key": string(), "enabled": boolean
        ]) { _, new in new }, required: ["provider"], permission: "write", network: "configured_provider", task: true),
        .init(name: "get_local_models", summary: "Read the App's local model catalog, installation state and download sizes.", properties: [:]),
        .init(name: "install_local_model", summary: "Install a catalog model using the App downloader and load verification.", properties: preview.merging(["id": string()]) { _, new in new }, required: ["id"], permission: "write", network: "configured_model_source", task: true),
        .init(name: "pause_local_model", summary: "Pause the App's model download, retaining partial files for resume.", properties: preview.merging(["id": string()]) { _, new in new }, required: ["id"], permission: "write"),
        .init(name: "delete_local_model", summary: "Delete a catalog model through the App's unload and shared-file coordinator.", properties: preview.merging(["id": string()]) { _, new in new }, required: ["id"], permission: "write", task: true),
        .init(name: "list_managed_skills", summary: "Read the Direct App's managed Skill library.", properties: pagination),
        .init(name: "list_skill_targets", summary: "Read supported detected Agent destinations from the Skill library. Run refresh_skills after changing installed agents.", properties: [:]),
        .init(name: "refresh_skills", summary: "Run the App's Skill recovery, Agent discovery and library reconciliation without opening a window.", properties: preview, permission: "write", task: true),
        .init(name: "set_skill_assignment", summary: "Assign, pause, resume or uninstall a managed Skill through the App's ownership-checked assignment transaction.", properties: preview.merging([
            "id": string(), "action": string(SkillAssignmentAction.allCases.map(\.rawValue)),
            "target_id": string(), "assignment_id": string()
        ]) { _, new in new }, required: ["id", "action"], permission: "write", task: true),
        .init(name: "import_skill", summary: "Import a GitHub Skill into the Direct App's managed library using its verified staging transaction.", properties: preview.merging(["repository": string(), "ref": string(), "directory": string()]) { _, new in new }, required: ["repository"], permission: "write", network: "github", task: true),
        .init(name: "update_skill", summary: "Update a managed Skill using the App's baseline/local/remote comparison and transaction.", properties: preview.merging(["id": string(), "replace_local_changes": boolean]) { _, new in new }, required: ["id"], permission: "write", network: "github", task: true),
        .init(name: "remove_skill", summary: "Remove a managed Skill with the App's assignment cleanup and ownership checks.", properties: preview.merging(["id": string()]) { _, new in new }, required: ["id"], permission: "write", task: true),
        .init(name: "check_skill_updates", summary: "Run the Direct App's managed Skill update checks.", properties: preview, permission: "write", network: "github", task: true),
        .init(name: "get_cache_statistics", summary: "Read the same README, image and archive cache statistics as Settings.", properties: [:]),
        .init(name: "clear_cache", summary: "Clear one cache category or all rebuildable caches using the App's existing cleaner.", properties: preview.merging(["scope": string(["readmes", "images", "archives", "all"])]) { _, new in new }, required: ["scope"], permission: "write", task: true),
        .init(name: "set_public_settings", summary: "Update notifications, external-search privacy and auto-tidy settings. Write authorization itself remains a Settings-only choice.", properties: preview.merging([
            "notifications_enabled": boolean, "external_search_allow_private_repos": boolean,
            "auto_tidy": .object(["type": .string("object")])
        ]) { _, new in new }, permission: "write"),
        .init(name: "export_diagnostics", summary: "Build the App's standard redacted diagnostic ZIP without a save dialog. Optional occurred_at (ISO 8601 instant) or occurred_on (YYYY-MM-DD) preserves the user's time precision. Read bytes with read_export_chunk; export expires after one hour.", properties: preview.merging([
            "description": string(), "module": string(), "occurred_at": string(), "occurred_on": string()
        ]) { _, new in new }, permission: "write", task: true),
        .init(name: "read_export_chunk", summary: "Read a base64 chunk of an App-created diagnostic export by artifact ID; paths are never accepted.", properties: [
            "id": string(), "offset": integer(0, Int.max), "limit": integer(1, 65_536)
        ], required: ["id"])
    ]
}

extension StarcatMCPPublicFacade {
    /// 账号外的本机服务同样使用 read/write；渠道、文件冲突等仍由原 App 服务检查。
    func callLocalOperation(name: String, arguments: [String: Value], app: AppDependencies) async throws -> Value {
        let dryRun = arguments["dry_run"]?.boolValue ?? true
        let id = arguments["id"]?.stringValue ?? ""
        switch name {
        case "list_ai_providers":
            return try StarcatMCPJSON.value(app.settings.aiProviderProfiles)
        case "configure_ai_provider":
            guard let provider = arguments["provider"]?.stringValue.flatMap(AIServiceProvider.init(rawValue:)) else {
                throw StarcatMCPError.invalidArguments("A supported provider type is required.")
            }
            let existing = app.settings.aiProviderProfiles.first { $0.id == id }
            if !id.isEmpty, existing == nil { throw StarcatMCPError.notFound("Provider profile not found.") }
            var profile = existing ?? AIProviderProfile(provider: provider)
            profile.provider = provider
            if let value = arguments["display_name"]?.stringValue { profile.displayName = value }
            if let value = arguments["base_url"]?.stringValue { profile.baseURL = value }
            profile.isEnabled = arguments["enabled"]?.boolValue ?? profile.isEnabled
            if dryRun { return preview(name, target: .object(["id": .string(profile.id), "provider": .string(provider.rawValue), "key_returned": .bool(false)])) }
            let key = try arguments["api_key"]?.stringValue ?? KeychainManager.shared.loadAIKey(forProvider: profile.id) ?? ""
            let requestedProfile = profile
            return try tasks.start(kind: name) {
                let verified = try await AIProviderConnectionTest().verify(profile: requestedProfile, apiKey: key)
                try Task.checkCancellation()
                if existing != nil, !app.settings.aiProviderProfiles.contains(where: { $0.id == verified.id }) { throw CancellationError() }
                try KeychainManager.shared.persistAIProviderKey(key, providerID: verified.id, allowsEmpty: provider.allowsEmptyAPIKey)
                if let index = app.settings.aiProviderProfiles.firstIndex(where: { $0.id == verified.id }) {
                    app.settings.aiProviderProfiles[index] = verified
                } else { app.settings.aiProviderProfiles.append(verified) }
                return try StarcatMCPJSON.value(verified)
            }
        case "get_local_models":
            let manager = LocalAIModelManager.shared
            return .array(LocalAIModelCatalog.entries.map { entry in
                .object([
                    "id": .string(entry.id), "name": .string(entry.displayName),
                    "type": .string(entry.type.rawValue), "download_bytes": .int(Int(entry.estimatedDownloadSize)),
                    "installed": .bool(manager.installedModel(id: entry.id) != nil),
                    "state": Self.localModelState(manager.installState(for: entry.id))
                ])
            })
        case "install_local_model", "pause_local_model", "delete_local_model":
            guard let entry = LocalAIModelCatalog.entry(id: id) else { throw StarcatMCPError.notFound("Model not found in the App catalog.") }
            if dryRun { return preview(name, target: .object(["id": .string(entry.id), "download_bytes": .int(Int(entry.estimatedDownloadSize))])) }
            let manager = LocalAIModelManager.shared
            if name == "pause_local_model" {
                manager.pause(entryID: id)
                return .object(["paused": .bool(true), "id": .string(id)])
            }
            return try tasks.start(kind: name, supportsCancellation: name == "install_local_model") {
                if name == "install_local_model" { try await manager.installAndWait(entry: entry) }
                else { try await manager.deleteAndWait(entryID: id) }
                return .object(["completed": .bool(true), "id": .string(id)])
            }
        case "list_managed_skills", "list_skill_targets", "refresh_skills", "set_skill_assignment",
             "import_skill", "update_skill", "remove_skill", "check_skill_updates":
            let viewModel = SkillWorkspaceViewModel()
            let environment = try SkillLibraryEnvironment(viewModel: viewModel)
            if name == "list_skill_targets" {
                return try StarcatMCPJSON.value(await environment.assignments.targets())
            }
            if name == "set_skill_assignment" {
                guard let entryID = UUID(uuidString: id),
                      let action = SkillAssignmentAction(rawValue: arguments["action"]?.stringValue ?? "")
                else { throw StarcatMCPError.invalidArguments("A Skill entry UUID and supported action are required.") }
                let plan = try await environment.assignments.prepare(
                    entryID: entryID, action: action, targetID: arguments["target_id"]?.stringValue,
                    assignmentID: arguments["assignment_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                )
                if dryRun { return preview(name, target: try StarcatMCPJSON.value(plan)) }
                return try tasks.start(kind: name, supportsCancellation: false) {
                    let result = await environment.assignments.execute(plan)
                    guard result.isSuccess else {
                        throw StarcatPublicCapabilityError(code: "SKILL_OPERATION_FAILED", message: result.message ?? result.status.rawValue)
                    }
                    return try StarcatMCPJSON.value(result)
                }
            }
            if name == "list_managed_skills" {
                let snapshot = try await environment.store.snapshot()
                let offset = arguments["offset"]?.intValue ?? 0
                let limit = arguments["limit"]?.intValue ?? 20
                return .object([
                    "items": .array(try snapshot.entries.dropFirst(offset).prefix(limit).map { entry in
                        .object(["entry": try StarcatMCPJSON.value(entry),
                                 "assignments": .array(try snapshot.assignments.filter { $0.entryID == entry.id }.map(StarcatMCPJSON.value))])
                    }),
                    "has_more": .bool(snapshot.entries.count > offset + limit),
                    "next_offset": snapshot.entries.count > offset + limit ? .int(offset + limit) : .null
                ])
            }
            if dryRun { return preview(name, target: .object(arguments.filter { $0.key != "dry_run" })) }
            return try tasks.start(kind: name, supportsCancellation: name == "refresh_skills" || name == "check_skill_updates") {
                let result: SkillOperationResult
                switch name {
                case "refresh_skills":
                    try await environment.refreshAndWait()
                    if case .failed(let message) = viewModel.loadState {
                        throw StarcatPublicCapabilityError(code: "SKILL_SCAN_FAILED", message: message)
                    }
                    let snapshot = try await environment.store.snapshot()
                    return .object([
                        "entries": .array(try snapshot.entries.map(StarcatMCPJSON.value)),
                        "assignments": .array(try snapshot.assignments.map(StarcatMCPJSON.value)),
                        "targets": try StarcatMCPJSON.value(await environment.assignments.targets())
                    ])
                case "import_skill":
                    let request = SkillGitHubImportRequest(
                        repository: try self.nonBlank(arguments, key: "repository"),
                        ref: arguments["ref"]?.stringValue ?? "", directory: arguments["directory"]?.stringValue ?? ""
                    )
                    let prepared = try await environment.imports.prepareGitHub(request)
                    result = await environment.imports.execute(prepared)
                case "update_skill":
                    guard let entryID = UUID(uuidString: id) else { throw StarcatMCPError.invalidArguments("A Skill entry UUID is required.") }
                    let prepared = try await environment.contentUpdates.prepare(entryID: entryID)
                    result = await environment.contentUpdates.execute(prepared, replacingLocalChanges: arguments["replace_local_changes"]?.boolValue ?? false)
                case "remove_skill":
                    guard let entryID = UUID(uuidString: id) else { throw StarcatMCPError.invalidArguments("A Skill entry UUID is required.") }
                    let prepared = try await environment.removals.prepare(entryID: entryID)
                    result = await environment.removals.execute(prepared).result
                default:
                    try await environment.updates.check()
                    return .object(["completed": .bool(true)])
                }
                guard result.isSuccess else {
                    throw StarcatPublicCapabilityError(code: "SKILL_OPERATION_FAILED", message: result.message ?? result.status.rawValue)
                }
                return try StarcatMCPJSON.value(result)
            }
        case "get_cache_statistics", "clear_cache":
            let cleaner = CacheCleaner(readmeRepository: app.readmeRepository)
            if name == "get_cache_statistics" { return Self.cacheStatistics(await cleaner.loadStatistics()) }
            if dryRun { return preview(name, target: Self.cacheStatistics(await cleaner.loadStatistics())) }
            return try tasks.start(kind: name, supportsCancellation: false) {
                switch arguments["scope"]?.stringValue {
                case "readmes": await cleaner.clearReadmes()
                case "images": await cleaner.clearImageCache()
                case "archives": cleaner.clearArchives()
                case "all": await cleaner.clearAll()
                default: throw StarcatMCPError.invalidArguments("Unknown cache scope.")
                }
                return Self.cacheStatistics(await cleaner.loadStatistics())
            }
        case "set_public_settings":
            let tidy = try arguments["auto_tidy"].map { try JSONDecoder().decode(AutoTidySettings.self, from: JSONEncoder().encode($0)) }
            if dryRun { return preview(name, target: .object(arguments.filter { $0.key != "dry_run" })) }
            if let enabled = arguments["notifications_enabled"]?.boolValue { app.settings.notificationsEnabled = enabled }
            if let enabled = arguments["external_search_allow_private_repos"]?.boolValue { app.settings.externalSearchAllowPrivateRepos = enabled }
            if let tidy { app.settings.autoTidySettings = tidy }
            return try await call(name: "get_public_settings", arguments: [:])
        case "export_diagnostics":
            let options = try Self.diagnosticExportOptions(arguments)
            if dryRun { return preview(name, target: .object(["redacted": .bool(true), "retention_seconds": .int(3600)])) }
            pruneDiagnosticExports()
            let artifactID = UUID().uuidString.lowercased()
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("starcat-public-diagnostics-\(artifactID).zip")
            return try tasks.start(kind: name, supportsCancellation: false) {
                let url = try await DiagnosticBundleExporter.export(to: destination, settings: app.settings, options: options)
                self.diagnosticExports[artifactID] = (url, Date())
                let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                return .object(["artifact_id": .string(artifactID), "bytes": .int(bytes), "retention_seconds": .int(3600)])
            }
        case "read_export_chunk":
            pruneDiagnosticExports()
            guard let artifact = diagnosticExports[id] else { throw StarcatMCPError.notFound("Export expired or unavailable.") }
            let offset = arguments["offset"]?.intValue ?? 0
            let handle = try FileHandle(forReadingFrom: artifact.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: arguments["limit"]?.intValue ?? 65_536) ?? Data()
            let total = try artifact.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return .object([
                "data_base64": .string(data.base64EncodedString()), "offset": .int(offset),
                "next_offset": .int(offset + data.count), "eof": .bool(offset + data.count >= total)
            ])
        default: throw StarcatMCPError.unsupported("Unknown local operation: \(name)")
        }
    }

    /// 公共导出与窗口使用同一时间精度；无效日期在接受任务前拒绝，不静默忽略用户线索。
    static func diagnosticExportOptions(_ arguments: [String: Value]) throws -> DiagnosticExportOptions {
        var options = DiagnosticExportOptions(description: arguments["description"]?.stringValue ?? "",
                                              module: arguments["module"]?.stringValue ?? "")
        if let value = arguments["occurred_at"] {
            // 共享 formatter 用于带小数秒的事件；公共输入同样允许标准的不带小数秒形式。
            guard let text = value.stringValue,
                  let date = ISO8601DateFormatter.shared.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
                throw StarcatMCPError.invalidArguments("occurred_at must be an ISO 8601 instant.")
            }
            options.occurredAt = date
        }
        if let value = arguments["occurred_on"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard options.occurredAt == nil, let text = value.stringValue,
                  let date = formatter.date(from: text), formatter.string(from: date) == text else {
                throw StarcatMCPError.invalidArguments("occurred_on must be YYYY-MM-DD and cannot be combined with occurred_at.")
            }
            options.occurredOn = text
        }
        return options
    }

    static func cacheStatistics(_ statistics: CacheStatistics) -> Value {
        .object([
            "readme_count": .int(statistics.readmeCount), "readme_bytes": .int(Int(statistics.readmeBytes)),
            "image_bytes": .int(Int(statistics.imageDiskBytes)), "archive_count": .int(statistics.archiveCount),
            "archive_bytes": .int(Int(statistics.archiveBytes))
        ])
    }

    /// 目录状态使用稳定 DTO；不把 Swift 枚举调试描述或内部文件信息作为公共契约。
    static func localModelState(_ state: LocalAIInstallState) -> Value {
        switch state {
        case .idle: .object(["status": .string("idle")])
        case .preparing: .object(["status": .string("preparing")])
        case .downloading(let progress, let completed, let total, let speed):
            .object(["status": .string("downloading"), "progress": .double(progress),
                     "completed_bytes": .int(Int(completed)), "total_bytes": .int(Int(total)),
                     "bytes_per_second": speed.map(Value.double) ?? .null])
        case .failed(let message), .loadFailed(let message), .deleteFailed(let message):
            .object(["status": .string("failed"), "message": .string(message)])
        case .loading: .object(["status": .string("loading")])
        case .deleting: .object(["status": .string("deleting")])
        case .installed: .object(["status": .string("installed")])
        }
    }

    /// 导出沿用任务的一小时保留周期；只删除本实例登记的文件，切号也会统一清理。
    func pruneDiagnosticExports() {
        let expired = diagnosticExports.filter { Date().timeIntervalSince($0.value.createdAt) > 3600 }
        for (id, artifact) in expired {
            try? FileManager.default.removeItem(at: artifact.url)
            diagnosticExports.removeValue(forKey: id)
        }
    }
}
