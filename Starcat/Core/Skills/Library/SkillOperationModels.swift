//
//  SkillOperationModels.swift
//  Starcat
//
//  管理操作的可评审计划、逐项结果与恢复记录。计划是快照，执行时仍需核对前提；
//  journal 只保存身份、路径、摘要和 hash，不保存文件正文或 GitHub 凭据。
//

import Foundation

/// 内容写入计划保留旧元数据，用于目录回滚后的索引与回执收敛。
struct SkillContentOperationPlan: Codable, Sendable, Identifiable {
    var id = UUID()
    var createdAt = Date().timeIntervalSince1970
    let source: SkillLibrarySource
    let entry: SkillLibraryEntry
    let revision: SkillLibraryRevision
    let incomingDirectory: String
    let fingerprint: SkillDirectoryFingerprint
    let previousEntry: SkillLibraryEntry?
    let previousReceipt: SkillLibraryReceipt?
    var kind: String { previousEntry == nil ? "importContent" : "updateContent" }

    var receipt: SkillLibraryReceipt {
        SkillLibraryReceipt(
            entryID: entry.id, revisionID: revision.id, contentDigest: fingerprint.digest,
            installedAt: revision.createdAt, fingerprint: fingerprint
        )
    }
}

enum SkillOperationStatus: String, Codable, Sendable {
    case succeeded, alreadySatisfied, conflict, failed, cancelled, needsRecovery
    var isSuccess: Bool { self == .succeeded || self == .alreadySatisfied }
}

/// 一个结果只描述一个已批准操作，批量层不得把失败项合并成成功。
struct SkillOperationResult: Codable, Sendable, Identifiable {
    var formatVersion = 1
    let id: UUID
    let entryID: UUID?
    let status: SkillOperationStatus
    let message: String?
    var isSuccess: Bool { status.isSuccess }
    var canRetry: Bool { status == .failed || status == .conflict || status == .cancelled }
}

/// DB 用于列表查询，文件 journal 才是提交中断后的恢复依据。
struct SkillOperationRecord: SkillLibraryPersistedRecord, Identifiable {
    static let databaseTableName = "skill_operations"
    let id: UUID
    let entryID: UUID?
    let kind: String
    var state: String
    let journalPath: String
    var resultJSON: String? = nil
    var createdAt = Date().timeIntervalSince1970
    var updatedAt = Date().timeIntervalSince1970

    enum CodingKeys: String, CodingKey {
        case id, kind, state
        case entryID = "entry_id"
        case journalPath = "journal_path"
        case resultJSON = "result_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var result: SkillOperationResult? {
        guard let resultJSON else { return nil }
        return try? JSONDecoder().decode(SkillOperationResult.self, from: Data(resultJSON.utf8))
    }
}

/// 阶段只在对应动作之后落盘；committing 在 rename 前落盘以覆盖两次移动之间的中断。
struct SkillContentJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case preparing, staged, committing, contentCommitted, metadataCommitted
    }
    var formatVersion = 1
    let plan: SkillContentOperationPlan
    var phase: Phase
}

/// 故障注入点只在初始化时提供，生产默认不注入；不能通过运行时 UI 关闭校验。
enum SkillOperationCheckpoint: Equatable, Sendable {
    case beforeStage, afterStage, beforeCommit, afterContentCommit, beforeReceipt, beforeMetadata, afterMetadata
}
