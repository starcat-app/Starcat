//
//  StarcatMCPSkillEvaluationOperations.swift
//  Starcat
//
//  将公共 selector 解析为评估服务的受管目标。公共适配层不扫描仓库、
//  不运行评估器，也不接受 App 设备上的文件路径或可执行文件参数。
//

import Foundation
import MCP

/// 公共参数只描述精确目标；仓库 Skill ID 必须来自相同提交的账号缓存。
struct StarcatMCPSkillEvaluationRequest {
    enum Target: Hashable {
        case library(UUID)
        case repository(id: Int64, commit: String, skillID: String)
    }

    let mode: SkillEvaluationMode
    let targets: [Target]

    init(_ arguments: [String: Value]) throws {
        guard let mode = arguments["mode"]?.stringValue.flatMap(SkillEvaluationMode.init(rawValue:)),
              let values = arguments["targets"]?.arrayValue,
              (1...30).contains(values.count), mode != .similarity || values.count >= 2 else {
            throw StarcatMCPError.invalidArguments("Provide a supported mode and 1–30 targets; similarity requires at least two.")
        }
        let targets = try values.enumerated().map { index, value -> Target in
            let fields = value.objectValue ?? [:]
            if fields.count == 1, let id = fields["library_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                return .library(id)
            }
            if fields.count == 3, let repoID = fields["repo_id"]?.intValue, repoID > 0,
               let commit = fields["commit_sha"]?.stringValue?.lowercased(), commit.utf8.count == 40,
               commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
               let skillID = fields["skill_id"]?.stringValue, !skillID.isEmpty {
                return .repository(id: Int64(repoID), commit: commit, skillID: skillID)
            }
            throw StarcatMCPError.invalidArguments("arguments.targets[\(index)]: provide library_id or repo_id, commit_sha and skill_id.")
        }
        guard Set(targets).count == targets.count else {
            throw StarcatMCPError.invalidArguments("arguments.targets: duplicate Skill targets.")
        }
        self.mode = mode
        self.targets = targets
    }

    /// 只有扫描快照、仓库和所选条目均匹配固定提交才交给共享服务。
    static func cachedSkill(in scan: RepoSkillScan?, repoID: Int64, commit: String, skillID: String) throws -> RepoSkill {
        guard let scan, scan.repositoryID == repoID, scan.commitSHA == commit,
              let skill = scan.skills.first(where: {
                  $0.id == skillID && $0.repositoryID == repoID && $0.commitSHA == commit
              }) else {
            throw StarcatMCPError.notFound("Skill evidence for that commit is unavailable; use get_repo_skills to read known IDs.")
        }
        return skill
    }

    /// UI 可以展示其他版本的旧报告；公共调用显式绑定仓库 commit，因此过滤掉其他版本。
    static func matchingReports(_ reports: [SkillEvaluationCached], targets: [SkillEvaluationTarget]) -> [SkillEvaluationCached] {
        let subjects = Set(targets.map(\.identity))
        let commits = Dictionary(targets.compactMap { target -> (SkillEvaluationSubject, String)? in
            guard case .repository(_, let skill) = target else { return nil }
            return (target.identity, skill.commitSHA)
        }, uniquingKeysWith: { first, _ in first })
        return reports.filter { cached in
            let report = cached.report
            guard !report.subjects.isEmpty, report.subjects.count == report.versions.count else { return false }
            return zip(report.subjects, report.versions).allSatisfy { subject, version in
                subjects.contains(subject) && (commits[subject].map { $0 == version } ?? true)
            }
        }
    }

    /// 模型引用绑定用户确认的端点，并由共享服务再次核验可用模型、端点和凭据。
    func model(_ value: Value?, profiles: [AIProviderProfile]) throws -> SkillEvaluationSelection? {
        guard mode.requiresAI else {
            guard value == nil else { throw StarcatMCPError.invalidArguments("Static modes do not accept a model.") }
            return nil
        }
        let fields = value?.objectValue ?? [:]
        let chat = fields["chat"]?.stringValue
        let embedding = fields["embedding"]?.stringValue
        guard let providerID = fields["provider_id"]?.stringValue,
              let profile = profiles.first(where: { $0.id == providerID }),
              fields["endpoint"]?.stringValue == profile.baseURL,
              mode.needsChat == (chat != nil), mode.needsEmbedding == (embedding != nil),
              chat.map({ name in
                  profile.models.contains { $0.isEnabled && $0.name == name && [.chat, .unknown].contains($0.capability) }
              }) ?? true,
              embedding.map({ name in
                  profile.models.contains { $0.isEnabled && $0.name == name && [.embedding, .unknown].contains($0.capability) }
              }) ?? true else {
            throw StarcatMCPError.invalidArguments("Select enabled models and the current endpoint from one configured provider.")
        }
        return SkillEvaluationSelection(providerID: providerID, endpoint: profile.baseURL, chat: chat ?? "", embedding: embedding)
    }

    /// 预览只回显受管引用及网络范围，真正启动只调用一次 App 服务。
    func start(
        arguments: [String: Value],
        model: SkillEvaluationSelection?,
        apply: () throws -> Value,
        preview: (Value) -> Value
    ) throws -> Value {
        if arguments["dry_run"]?.boolValue ?? true {
            return preview(.object([
                "mode": .string(mode.rawValue), "targets": arguments["targets"] ?? .array([]),
                "requires_model_consent": .bool(mode.requiresAI),
                "model_provider_id": model.map { .string($0.providerID) } ?? .null,
                "model_endpoint": model.map { .string($0.endpoint) } ?? .null,
                "chat_model": model.flatMap { $0.chat.isEmpty ? nil : .string($0.chat) } ?? .null,
                "embedding_model": model?.embedding.map(Value.string) ?? .null,
                "may_download_repo_blobs": .bool(targets.contains {
                    if case .repository = $0 { return true }
                    return false
                }),
                "may_download_scanner": .bool(mode == .security)
            ]))
        }
        guard !mode.requiresAI || arguments["consent"]?.boolValue == true else {
            throw StarcatPublicCapabilityError(code: "CONSENT_REQUIRED", message: "Confirm sending the selected Skill evaluation data to the configured model endpoint.")
        }
        return try apply()
    }
}

extension StarcatMCPPublicFacade {
    /// 缓存读取与执行共用 selector，在启动前重查切号与写入状态以覆盖异步缓存读取窗口。
    func callSkillEvaluation(name: String, arguments: [String: Value], app: AppDependencies) async throws -> Value {
        try DistributionGate().requireDirect(.skillManagement)
        let request = try StarcatMCPSkillEvaluationRequest(arguments)
        var targets: [SkillEvaluationTarget] = []
        // 批量常来自同一个仓库，单次请求只解码一次扫描快照。
        var repositories: [Int64: (repo: Repo, scan: RepoSkillScan?)] = [:]
        for target in request.targets {
            switch target {
            case .library(let id):
                targets.append(.library(id))
            case .repository(let id, let commit, let skillID):
                guard app.authSession.state.user != nil else {
                    throw StarcatPublicCapabilityError(code: "AUTH_REQUIRED", message: "Sign in to Starcat first.")
                }
                let evidence: (repo: Repo, scan: RepoSkillScan?)
                if let loaded = repositories[id] {
                    evidence = loaded
                } else {
                    let repo = try await resolve(["repo_id": .int(Int(id))], app: app)
                    evidence = (repo, try await app.repoSkillStore.cachedScan(for: repo))
                    repositories[id] = evidence
                }
                let skill = try StarcatMCPSkillEvaluationRequest.cachedSkill(
                    in: evidence.scan, repoID: evidence.repo.id, commit: commit, skillID: skillID
                )
                targets.append(.repository(evidence.repo, skill))
            }
        }
        try requireReadySession()
        let service = app.skillEvaluation
        if name == "start_skill_evaluation" {
            try StarcatMCPAccess.requireWrite(app.settings)
            let model = try request.model(arguments["model"], profiles: request.mode.requiresAI ? service.profiles() : [])
            return try request.start(arguments: arguments, model: model, apply: {
                let id = try service.start(
                    targets: targets, mode: request.mode, model: model, consent: arguments["consent"]?.boolValue == true
                )
                return try tasks.status(id: id)
            }, preview: { preview(name, target: $0) })
        }

        let reports = try await service.latest(targets: targets, mode: request.mode)
        try requireReadySession()
        let matching = StarcatMCPSkillEvaluationRequest.matchingReports(reports, targets: targets)
        var output: [String: Value] = ["cache_hit": .bool(!matching.isEmpty), "network_used": .bool(false)]
        if name == "export_skill_evaluation" {
            output["format"] = .string("json")
            output["content"] = .string(String(decoding: try SkillEvaluationService.export(matching), as: UTF8.self))
        } else {
            output["reports"] = try StarcatMCPJSON.value(matching)
        }
        return .object(output)
    }
}
