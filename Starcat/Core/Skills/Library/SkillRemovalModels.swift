//
//  SkillRemovalModels.swift
//  Starcat
//
//  库条目移除的审核快照和恢复阶段。卸载分配与移除本机库是不同操作，
//  计划冻结全部自有分配及完整条目目录，原始来源不进入删除范围。
//

import Foundation

/// 同时保留内容回执和包含回退版本的目录指纹，不能只检查 SKILL.md 就移走整个目录。
struct SkillRemovalPlan: Codable, Sendable, Identifiable {
    var id = UUID()
    let entry: SkillLibraryEntry
    let receipt: SkillLibraryReceipt
    let fingerprint: SkillDirectoryFingerprint
    let assignments: [SkillAssignmentPlan]
    let discoveredPaths: [String]
}

/// 分配可能部分卸载成功；总体失败时仍提供逐项目标结果，不自动重建已解除的链接。
struct SkillRemovalOutcome: Sendable {
    let result: SkillOperationResult
    let assignmentResults: [SkillOperationResult]
}

/// committing 先于排他移动落盘；Trash API 返回后再次落盘，未知的中间现场保留待恢复。
struct SkillRemovalJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case prepared, committing, staged, metadataCommitted, trashed
    }
    var formatVersion = 1
    let plan: SkillRemovalPlan
    var phase: Phase
    var trashPath: String?
}

enum SkillRemovalCheckpoint: Sendable {
    case beforeMove, afterMove, beforeMetadata, afterMetadata, afterTrash
}
