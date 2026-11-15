//
//  SkillLibraryItem.swift
//  Starcat
//
//  本机库发布给工作台的不可执行读模型。来源、条目和物理位置分别保留身份，
//  同名或同内容都不意味着同一条目；这里不授予任何文件写权限。
//

import Foundation

/// 是否由 Starcat 拥有内容，不能从目录名、Agent 名称或是否存在链接推断。
enum SkillLibraryManagementKind: String, Codable, Sendable {
    case managed
    case external
}

/// 一个物理位置可以被多个 Agent 共同读取，显示可见性证据而非“已加载”承诺。
struct SkillLibraryLocationSummary: Identifiable, Equatable, Sendable {
    let path: String
    let agentNames: [String]
    var resolvedPath: String? = nil
    var state: SkillLibraryLocationState = .present
    var isShared: Bool { agentNames.count > 1 }
    var id: String { path }
}

/// 列表快照按持久 entryID 识别条目；正文和文件只在选中项读取后填充。
struct SkillLibraryItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let summary: String
    let managementKind: SkillLibraryManagementKind
    let source: String?
    let locations: [SkillLibraryLocationSummary]
    var diagnostic: String? = nil
    var hasUpdate = false
    var revision: String? = nil
    var markdown: String? = nil
    var files: [String] = []
    var updateState: SkillUpdateState = .neverChecked
    var updateMessage: String?
    var updateCheckedAt: TimeInterval?
}
