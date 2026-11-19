//  SkillEvaluationService.swift
//  Starcat
//
//  管理两处界面与公共工具发起的文件评估。报告按账号隔离，只有用户发起任务才下载或调用模型。

import Foundation
import MCP
import Observation

/// 给 UI、公共任务和批量失败项同一组可本地化的错误。内部路径和进程日志不进入报告。
struct SkillEvaluationFailure: LocalizedError, Sendable {
    let code: String
    init(_ code: String) { self.code = code }
    var errorDescription: String? {
        switch code {
        case "input": String.l10n("skills.evaluation.error.input")
        case "toolMissing", "toolVersion": String.l10n("skills.evaluation.error.setup")
        case "model": String.l10n("skills.evaluation.error.model")
        case "busy": String.l10n("skills.evaluation.error.busy")
        default: String.l10n("skills.evaluation.error.run")
        }
    }
}

/// MainActor 只拥有任务与账号状态。复制、文件指纹、子进程及缓存写入均离开主线程。
@MainActor @Observable
final class SkillEvaluationService {
    private(set) var revision: UInt64 = 0
    private var changingAccount = false
    private var epoch: UInt64 = 0
    private let gate: DistributionGate
    private let tasks: StarcatMCPTaskStore
    private let cache: SkillEvaluationCache
    private let defaults: UserDefaults
    private let account: () -> String
    private let providers: () -> [AIProviderProfile]
    private let readKey: (String) throws -> String?
    private let source: (SkillEvaluationTarget) throws -> SkillEvaluationSnapshotter
    private let verifyTarget: (SkillEvaluationTarget) async throws -> Void
    private var runs: [Run] = []
    private static let toolPreference = "skillEvaluation.executable"

    /// 报告沿用稳定目录身份回读旧版本，任务匹配还需要绑定仓库提交。
    private struct RunTarget: Hashable {
        let subject: SkillEvaluationSubject
        let commit: String?

        init(_ target: SkillEvaluationTarget) {
            subject = target.identity
            if case .repository(_, let skill) = target { commit = skill.commitSHA }
            else { commit = nil }
        }
    }

    /// 任务状态和结果由公共存储持有。这里保留本次会话的选择范围，供两处入口回接。
    private struct Run {
        let id: String
        let mode: SkillEvaluationMode
        let targets: Set<RunTarget>
    }

    init(gate: DistributionGate, tasks: StarcatMCPTaskStore, cache: SkillEvaluationCache = .init(),
         defaults: UserDefaults = .standard, account: @escaping () -> String,
         providers: @escaping () -> [AIProviderProfile], readKey: @escaping (String) throws -> String?,
         source: @escaping (SkillEvaluationTarget) throws -> SkillEvaluationSnapshotter,
         verifyTarget: @escaping (SkillEvaluationTarget) async throws -> Void) {
        self.gate = gate
        self.tasks = tasks
        self.cache = cache
        self.defaults = defaults
        self.account = account
        self.providers = providers
        self.readKey = readKey
        self.source = source
        self.verifyTarget = verifyTarget
    }

    /// 保留 GUI 明确选择的逻辑路径，venv 的入口可以是符号链接。每次运行仍探测真实版本。
    func setExecutable(_ url: URL) throws {
        try requireReady()
        guard url.isFileURL, url.lastPathComponent == "skillevaluator" else { throw SkillEvaluationFailure("toolMissing") }
        _ = try SkillEvaluationRunner.locate(override: url)
        defaults.set(url.path, forKey: Self.toolPreference)
    }

    func profiles() -> [AIProviderProfile] {
        guard !changingAccount, gate.isAvailable(.skillManagement) else { return [] }
        return providers().filter { profile in
            guard profile.isVerifiedConfiguration, profile.provider != .localAI, profile.provider != .anthropic,
                  let parts = URLComponents(string: profile.baseURL), let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return false }
            return parts.scheme?.lowercased() == "https" || (parts.scheme?.lowercased() == "http"
                && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()))
        }
    }

    /// 缓存命中才计算当前版本。文件已经消失或变得不可读时，仍可打开明确标为过期的报告。
    func latest(targets: [SkillEvaluationTarget], mode: SkillEvaluationMode) async throws -> [SkillEvaluationCached] {
        try requireReady()
        let generation = epoch, scope = account()
        var result: [SkillEvaluationCached] = []
        for group in groups(targets, mode: mode) {
            try ensureCurrent(generation, scope)
            let previous = try await cache.records(account: scope, subjects: group.map(\.identity), mode: mode)
            guard let last = previous.first else { continue }
            var versions: [String] = []
            for item in group {
                try ensureCurrent(generation, scope)
                if let value = try? await source(item).version(of: item) { versions.append(value) }
            }
            let current = previous.first { $0.versions == versions && $0.toolVersion == SkillEvaluationRunner.version }
            result.append(.init(report: current ?? last, stale: current == nil))
        }
        try ensureCurrent(generation, scope)
        return result
    }

    /// 入口同步绑定模式、目标及所选模型。逐项运行并逐项提交，取消保留此前已提交的报告。
    func start(targets: [SkillEvaluationTarget], mode: SkillEvaluationMode,
               model: SkillEvaluationSelection?, consent: Bool) throws -> String {
        try requireReady()
        let sorted = targets.sorted { $0.identity.sortKey < $1.identity.sortKey }
        let subjects = sorted.map(\.identity)
        let selectedSubjects = Set(subjects)
        guard (1...30).contains(subjects.count), selectedSubjects.count == subjects.count,
              mode != .similarity || subjects.count >= 2 else { throw SkillEvaluationFailure("input") }
        // 一个批次从排队起占用它的完整选择。重叠条目跨模式或提交也要等执行器退出。
        let occupied = runs.contains { run in
            tasks.isActive(id: run.id) && run.targets.contains { selectedSubjects.contains($0.subject) }
        }
        guard !occupied else { throw SkillEvaluationFailure("busy") }
        _ = try selectedProfile(mode, model, consent)
        let executable = try SkillEvaluationRunner.locate(override: defaults.string(forKey: Self.toolPreference).map(URL.init(fileURLWithPath:)))
        let generation = epoch, scope = account()
        let task = try tasks.startReportingProgress(kind: "skill_evaluation", onFinish: { [weak self] _ in
            self?.revision &+= 1
        }) { [self] publish in
            var completed: [Value] = [], failures: [Value] = []
            var result: Value = .object(["report_ids": .array([]), "failures": .array([])])
            for group in groups(sorted, mode: mode) {
                try ensureCurrent(generation, scope)
                do {
                    let report = try await evaluate(group, mode, model, consent, executable, generation, scope)
                    try ensureCurrent(generation, scope)
                    try await cache.save(report, account: scope)
                    completed.append(.string(report.id.uuidString))
                    revision &+= 1
                } catch {
                    try ensureCurrent(generation, scope)
                    let failure = error as? SkillEvaluationFailure ?? SkillEvaluationFailure("input")
                    failures.append(.object(["subjects": try StarcatMCPJSON.value(group.map(\.identity)),
                                             "message": .string(failure.localizedDescription)]))
                }
                // 保存成功后即发布 ID。即使下一项被取消，共享任务仍能回读已经提交的报告。
                result = .object(["report_ids": .array(completed), "failures": .array(failures)])
                publish(result)
            }
            guard !completed.isEmpty else {
                throw StarcatPublicCapabilityError(code: "SKILL_EVALUATION_FAILED", message: Self.failureLines(failures).joined(separator: "\n"))
            }
            return result
        }
        guard let id = task.objectValue?["task_id"]?.stringValue else { throw SkillEvaluationFailure("failed") }
        let retained = tasks.retainedTaskIDs()
        runs.removeAll { !retained.contains($0.id) }
        runs.append(Run(id: id, mode: mode, targets: Set(sorted.map(RunTarget.init))))
        revision &+= 1
        return id
    }

    /// 一组比较使用一个任务目录，每个成员保留真实末级目录名，包括同名条目。
    private func evaluate(_ group: [SkillEvaluationTarget], _ mode: SkillEvaluationMode, _ model: SkillEvaluationSelection?,
                          _ consent: Bool, _ executable: URL, _ generation: UInt64, _ scope: String) async throws -> SkillEvaluationRecord {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("starcat-skill-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workspace) }
        var inputs: [SkillEvaluationInput] = []
        for (index, item) in group.enumerated() {
            try ensureCurrent(generation, scope)
            try await verifyTarget(item)
            try ensureCurrent(generation, scope)
            let parent = workspace.appendingPathComponent("source-\(index)", isDirectory: true)
            try fm.createDirectory(at: parent, withIntermediateDirectories: false)
            inputs.append(try await source(item).snapshot(item, under: parent))
        }
        try ensureCurrent(generation, scope)
        var key: String?
        if let profile = try selectedProfile(mode, model, consent) {
            key = try readKey(profile.id)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if key?.isEmpty != false {
                guard profile.provider.allowsEmptyAPIKey else { throw SkillEvaluationFailure("model") }
                key = "local-ai"
            }
        }
        let checks = try await SkillEvaluationRunner.run(executable: executable, mode: mode, inputs: inputs,
                                                        workspace: workspace, model: model, apiKey: key)
        guard !checks.isEmpty else { throw SkillEvaluationFailure("invalidReport") }
        let state: SkillEvaluationState = checks.contains { $0.state == .incomplete } ? .incomplete
            : checks.contains { $0.state == .findings } ? .findings : .passed
        return SkillEvaluationRecord(id: UUID(), mode: mode, subjects: group.map(\.identity), names: inputs.map(\.name),
                                     versions: inputs.map(\.version), model: model, createdAt: Date(), state: state,
                                     checks: checks, toolVersion: SkillEvaluationRunner.version)
    }

    /// 两次从当前设置解析，不采信客户端提交的地址作为凭据目的地。
    private func selectedProfile(_ mode: SkillEvaluationMode, _ selection: SkillEvaluationSelection?, _ consent: Bool) throws -> AIProviderProfile? {
        guard mode.requiresAI else {
            guard selection == nil else { throw SkillEvaluationFailure("model") }
            return nil
        }
        guard consent, let selection, let profile = profiles().first(where: { $0.id == selection.providerID }),
              profile.baseURL == selection.endpoint else { throw SkillEvaluationFailure("model") }
        func has(_ name: String?, _ capability: AIModelCapability) -> Bool {
            profile.models.contains { $0.isEnabled && $0.name == name && ($0.capability == capability || $0.capability == .unknown) }
        }
        guard mode.needsChat ? has(selection.chat, .chat) : selection.chat.isEmpty,
              mode.needsEmbedding ? has(selection.embedding, .embedding) : selection.embedding == nil else { throw SkillEvaluationFailure("model") }
        return profile
    }

    func activeTask(targets: [SkillEvaluationTarget], mode: SkillEvaluationMode) -> String? {
        guard let id = latestTask(targets: targets, mode: mode), tasks.isActive(id: id) else { return nil }
        return id
    }

    /// 精确选择可回接最近的任务，包括关面板期间结束的任务。过期时间沿用公共任务存储。
    func latestTask(targets: [SkillEvaluationTarget], mode: SkillEvaluationMode) -> String? {
        let selection = Set(targets.map(RunTarget.init))
        guard selection.count == targets.count,
              let run = runs.last(where: { $0.mode == mode && $0.targets == selection }),
              (try? taskState(id: run.id)) != nil else { return nil }
        return run.id
    }

    /// 筛选后的批次可以通过已记住的 ID 回接，但它运行的每个条目及提交必须仍在当前范围内。
    func matchesTask(id: String, within targets: [SkillEvaluationTarget], mode: SkillEvaluationMode) -> Bool {
        guard let run = runs.first(where: { $0.id == id }), run.mode == mode,
              run.targets.isSubset(of: Set(targets.map(RunTarget.init))) else { return false }
        return (try? taskState(id: id)) != nil
    }

    func cancel(id: String) throws { try requireTask(id); _ = try tasks.cancel(id: id) }
    func taskState(id: String) throws -> String {
        try requireTask(id)
        return try tasks.status(id: id).objectValue?["state"]?.stringValue ?? "failed"
    }

    func taskFailures(id: String) throws -> [String] {
        try requireTask(id)
        let result = try tasks.result(id: id).objectValue
        let failures = Self.failureLines(result?["result"]?.objectValue?["failures"]?.arrayValue ?? [])
        if !failures.isEmpty { return failures }
        if let error = result?["task"]?.objectValue?["error_message"]?.stringValue { return [error] }
        return []
    }

    private static func failureLines(_ failures: [Value]) -> [String] {
        failures.compactMap { failure in
            guard let value = failure.objectValue, let message = value["message"]?.stringValue else { return nil }
            let ids = value["subjects"].flatMap { try? JSONDecoder().decode([SkillEvaluationSubject].self, from: JSONEncoder().encode($0)) } ?? []
            return (ids.map(\.sortKey) + [message]).joined(separator: " · ")
        }
    }

    private func groups(_ targets: [SkillEvaluationTarget], mode: SkillEvaluationMode) -> [[SkillEvaluationTarget]] {
        guard !targets.isEmpty else { return [] }
        return mode == .similarity ? [targets.sorted { $0.identity.sortKey < $1.identity.sortKey }] : targets.map { [$0] }
    }

    private func requireReady() throws {
        try gate.requireDirect(.skillManagement)
        guard !changingAccount else { throw CancellationError() }
    }

    private func requireTask(_ id: String) throws {
        try requireReady()
        guard runs.contains(where: { $0.id == id }) else {
            throw StarcatPublicCapabilityError(code: "TASK_NOT_FOUND", message: "The task does not exist, expired, or belongs to an earlier app session.")
        }
    }

    private func ensureCurrent(_ generation: UInt64, _ scope: String) throws {
        try Task.checkCancellation()
        guard !changingAccount, generation == epoch, scope == account() else { throw CancellationError() }
    }

    /// 和公共 facade 的 cancelAllAndWait 配合。屏障从切号第一行持续到数据库确认就绪。
    func beginAccountChange() {
        changingAccount = true
        epoch &+= 1
        runs.removeAll()
        revision &+= 1
    }
    func finishAccountChange(succeeded: Bool) { changingAccount = !succeeded; revision &+= 1 }

    static func export(_ reports: [SkillEvaluationCached]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(reports)
    }
}
