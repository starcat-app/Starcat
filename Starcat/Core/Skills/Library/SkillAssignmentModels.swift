//
//  SkillAssignmentModels.swift
//  Starcat
//
//  分配关系与发现位置分离：只有持久回执证明自有的链接才可暂停或卸载。
//  一个物理根只保留一个分配，逻辑路径与所有可能受影响的 Agent 仍完整展示。
//

import Darwin
import Foundation

enum SkillAssignmentAction: String, Codable, CaseIterable, Sendable {
    case assign, pause, resume, uninstall
    var titleKey: String { "skills.assignment.\(rawValue)" }
}

enum SkillAssignmentState: String, Codable, Sendable { case active, paused }

/// inode 仅辅助核对当前链接，始终同时检查链接类型、链接值和路径边界。
struct SkillLinkIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64

    static func read(_ url: URL) throws -> Self {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard information.st_mode & S_IFMT == S_IFLNK else { throw SkillOperationError.ownership }
        return Self(device: information.st_dev, inode: information.st_ino)
    }
}

/// targetPath 是创建链接时解析后的物理路径，禁止用它递归删除 canonical 内容。
struct SkillAssignment: SkillLibraryPersistedRecord, Equatable, Identifiable {
    static let databaseTableName = "skill_assignments"
    var id = UUID()
    let entryID: UUID
    let target: SkillAssignmentTarget
    let targetPath: String
    let contentPath: String
    var desiredState: SkillAssignmentState
    var linkIdentity: SkillLinkIdentity?

    enum CodingKeys: String, CodingKey {
        case id
        case entryID = "entry_id"
        case target = "target_json"
        case targetPath = "target_path"
        case contentPath = "content_path"
        case desiredState = "desired_state"
        case linkIdentity = "link_identity_json"
    }
}

/// 逻辑别名先合并为物理计划；Agent 名称表示共享影响，不代表当前会话已加载。
struct SkillAssignmentTarget: Codable, Equatable, Identifiable, Sendable {
    let configuredPaths: [String]
    let resolvedParent: String
    let agentIDs: [String]
    var id: String { resolvedParent }
    var names: String { agentIDs.map(SkillAgentProfile.displayName).joined(separator: " · ") }
}

enum SkillAssignmentObservedState: String, Sendable { case linked, paused, missing, conflict }

struct SkillAssignmentObservation: Identifiable, Sendable {
    let assignment: SkillAssignment
    let state: SkillAssignmentObservedState
    var id: UUID { assignment.id }
}

struct SkillAssignmentPlan: Codable, Sendable, Identifiable {
    var id = UUID()
    let action: SkillAssignmentAction
    let entry: SkillLibraryEntry
    let target: SkillAssignmentTarget
    let previous: SkillAssignment?
    let fingerprint: SkillDirectoryFingerprint?
    var assignmentID = UUID()
}

/// prepared 仅允许清理自有临时链接；committing 表示用户已批准的目标动作可以恢复。
struct SkillAssignmentJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, committing, metadataCommitted }
    var formatVersion = 1
    let plan: SkillAssignmentPlan
    var assignment: SkillAssignment?
    var stagedIdentity: SkillLinkIdentity?
    var phase: Phase = .prepared
}
