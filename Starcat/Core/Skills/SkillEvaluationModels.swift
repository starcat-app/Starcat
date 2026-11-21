//  SkillEvaluationModels.swift
//  Starcat
//
//  描述两个评估入口和公共接口共享的文件检查结果。报告只保留运行器筛选过的证据。

import Foundation

/// 五种文件检查的输入不同。相似度只调用向量模型，单 Skill 去重还需对话模型。
enum SkillEvaluationMode: String, Codable, CaseIterable, Hashable, Sendable {
    case quick, security, rubric, context, similarity
    var requiresAI: Bool { self == .rubric || self == .context || self == .similarity }
    var needsEmbedding: Bool { self == .context || self == .similarity }
    var needsChat: Bool { self == .context || self == .rubric }
}

/// 用户看到并确认的非敏感配置。密钥只能在运行前从匹配的已验证配置读取。
struct SkillEvaluationSelection: Codable, Hashable, Sendable {
    let providerID: String
    let endpoint: String
    let chat: String
    let embedding: String?
}

enum SkillEvaluationState: String, Codable, CaseIterable, Hashable, Sendable {
    case passed, findings, incomplete
}

struct SkillEvaluationCheck: Codable, Hashable, Sendable {
    let id: String
    let state: SkillEvaluationState
    let score: Double?
    let details: [String]
    let harnessProfiles: [SkillEvaluationHarnessProfile]?

    init(
        id: String, state: SkillEvaluationState, score: Double?, details: [String],
        harnessProfiles: [SkillEvaluationHarnessProfile]? = nil
    ) {
        self.id = id
        self.state = state
        self.score = score
        self.details = details
        self.harnessProfiles = harnessProfiles
    }
}

/// 上游固定版本的内容规则。状态不包含真实 Agent 或安装位置的探测。
struct SkillEvaluationHarnessProfile: Codable, Identifiable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case loads, degraded
        case notLoaded = "not_loaded"
    }

    let id: String
    let status: Status
    let rules: [String]
}

/// subjects、versions 和 names 共享顺序，让同名 Skill 的报告仍然可追溯。
struct SkillEvaluationRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let mode: SkillEvaluationMode
    let subjects: [SkillEvaluationSubject]
    let names: [String]
    let versions: [String]
    let model: SkillEvaluationSelection?
    let createdAt: Date
    let state: SkillEvaluationState
    let checks: [SkillEvaluationCheck]
    let toolVersion: String
}

struct SkillEvaluationCached: Codable, Hashable, Sendable {
    let report: SkillEvaluationRecord
    let stale: Bool
}

/// 每个账号、模式、精确比较集合对应一份可重建的缓存。保留最近使用过的模型及内容版本，
/// 回读优先当前版本。每组最多八个版本，写入前检查取消且整文件原子替换。
actor SkillEvaluationCache {
    let root: URL
    init(root: URL = URL.cachesDirectory.appending(path: AppConstants.bundleIdentifier + "/skill-evaluation-v1")) {
        self.root = root
    }

    private func file(_ account: String, _ subjects: [SkillEvaluationSubject], _ mode: SkillEvaluationMode) throws -> URL {
        let key = try JSONEncoder().encode([account, mode.rawValue] + subjects.map(\.sortKey))
        return root.appendingPathComponent(SkillFilePrimitives.digest(key) + ".json")
    }

    func records(account: String, subjects: [SkillEvaluationSubject], mode: SkillEvaluationMode) throws -> [SkillEvaluationRecord] {
        let url = try file(account, subjects, mode)
        do { return try JSONDecoder().decode([SkillEvaluationRecord].self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        catch is DecodingError {
            // 无法解码的缓存可以重建。保留文件到下次评估成功，再由原子写入覆盖。
            return []
        }
    }

    func save(_ report: SkillEvaluationRecord, account: String) throws {
        let url = try file(account, report.subjects, report.mode)
        var prior = try records(account: account, subjects: report.subjects, mode: report.mode)
        prior.removeAll { $0.versions == report.versions && $0.model == report.model && $0.toolVersion == report.toolVersion }
        let data = try JSONEncoder().encode([report] + Array(prior.prefix(7)))
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
    }
}
