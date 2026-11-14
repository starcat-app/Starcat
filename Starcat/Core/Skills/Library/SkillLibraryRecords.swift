//
//  SkillLibraryRecords.swift
//  Starcat
//
//  本机 Skill 库的持久身份。数据库不依赖 GitHub 账号，
//  来源、条目、版本和发现位置分别建模，不根据名称或内容 hash 合并所有权。
//

import Foundation
import GRDB

/// UUID 统一存成文本，使回执、外键及诊断中的身份与数据库一致。
protocol SkillLibraryPersistedRecord: Codable, FetchableRecord, PersistableRecord, Sendable {}

extension SkillLibraryPersistedRecord {
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}

enum SkillLibrarySourceKind: String, Codable, Sendable {
    case local, github
}

/// ref 只是版本选择，不参与来源唯一键；来源子目录参与身份。
struct SkillLibrarySource: SkillLibraryPersistedRecord, Equatable, Identifiable {
    static let databaseTableName = "skill_sources"
    var id = UUID()
    let kind: SkillLibrarySourceKind
    let canonicalLocator: String
    let subdirectory: String
    var defaultRef: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, subdirectory
        case canonicalLocator = "canonical_locator"
        case defaultRef = "default_ref"
    }
}

/// 扫描消失时仍保留条目身份；后续重新发现可继续关联用户元数据。
struct SkillLibraryEntry: SkillLibraryPersistedRecord, Equatable, Identifiable {
    static let databaseTableName = "skill_entries"
    var id = UUID()
    var sourceID: UUID? = nil
    var manifestName: String
    var summary: String
    var managementKind: SkillLibraryManagementKind
    var currentRevisionID: UUID? = nil
    var trackingRef: String? = nil
    var diagnostic: String? = nil
    var createdAt: TimeInterval = Date().timeIntervalSince1970
    var updatedAt: TimeInterval = Date().timeIntervalSince1970

    enum CodingKeys: String, CodingKey {
        case id, summary, diagnostic
        case sourceID = "source_id"
        case manifestName = "manifest_name"
        case managementKind = "management_kind"
        case currentRevisionID = "current_revision_id"
        case trackingRef = "tracking_ref"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// 完整内容基线与上游 commit 分开保存，仓库其他目录变更不等于此 Skill 更新。
struct SkillLibraryRevision: SkillLibraryPersistedRecord, Equatable, Identifiable {
    static let databaseTableName = "skill_revisions"
    var id = UUID()
    let entryID: UUID
    let contentDigest: String
    let manifestDigest: String
    let upstreamCommit: String?
    var createdAt: TimeInterval = Date().timeIntervalSince1970

    enum CodingKeys: String, CodingKey {
        case id
        case entryID = "entry_id"
        case contentDigest = "content_digest"
        case manifestDigest = "manifest_digest"
        case upstreamCommit = "upstream_commit"
        case createdAt = "created_at"
    }
}

/// complete／missing 才允许确认旧位置消失；失败、取消和超预算必须保留旧快照。
enum SkillScanCoverage: String, Codable, Sendable {
    case notScanned, complete, missing, inaccessible, unavailable, partial, cancelled, unsupported

    var confirmsAbsence: Bool { self == .complete || self == .missing }
}

enum SkillLibraryRootScope: String, Codable, Sendable {
    case global, managed
}

/// 一个发现根可服务多个 Agent；共享根不是多份安装。
struct SkillLibraryRoot: SkillLibraryPersistedRecord, Equatable, Identifiable {
    static let databaseTableName = "skill_roots"
    var id = UUID()
    let configuredPath: String
    var resolvedPath: String? = nil
    var agentIDs: [String]
    let scope: SkillLibraryRootScope
    var coverage: SkillScanCoverage = .notScanned
    var diagnostic: String? = nil
    var lastSuccessAt: TimeInterval? = nil

    enum CodingKeys: String, CodingKey {
        case id, scope, coverage, diagnostic
        case configuredPath = "configured_path"
        case resolvedPath = "resolved_path"
        case agentIDs = "agent_ids_json"
        case lastSuccessAt = "last_success_at"
    }
}

enum SkillLibraryLocationKind: String, Codable, Sendable {
    case directory, symbolicLink
}

enum SkillLibraryLocationState: String, Codable, Sendable {
    case present, missing, stale
}

/// lexicalPath 解释工具入口，resolvedPath 用于物理去重，两者不能互相替代。
struct SkillLibraryLocation: SkillLibraryPersistedRecord, Equatable, Identifiable {
    static let databaseTableName = "skill_locations"
    var id = UUID()
    let entryID: UUID
    let rootID: UUID
    let lexicalPath: String
    var resolvedPath: String
    var kind: SkillLibraryLocationKind
    var scanState: SkillLibraryLocationState = .present
    var lastSeenGeneration: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind
        case entryID = "entry_id"
        case rootID = "root_id"
        case lexicalPath = "lexical_path"
        case resolvedPath = "resolved_path"
        case scanState = "scan_state"
        case lastSeenGeneration = "last_seen_generation"
    }
}

/// 一次 GRDB read 内取得全部关系，UI 不会看到一半新、一半旧的计数。
struct SkillLibrarySnapshot: Sendable {
    let sources: [SkillLibrarySource]
    let entries: [SkillLibraryEntry]
    let revisions: [SkillLibraryRevision]
    let roots: [SkillLibraryRoot]
    let locations: [SkillLibraryLocation]
    var assignments: [SkillAssignment] = []
}

/// 私有库回执只描述受管基线；读到回执本身并不授予修改外部路径的权限。
struct SkillLibraryReceipt: Codable, Equatable, Sendable {
    var formatVersion = 1
    let entryID: UUID
    let revisionID: UUID
    let contentDigest: String
    let installedAt: TimeInterval
    let fingerprint: SkillDirectoryFingerprint
}
