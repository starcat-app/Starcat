//
//  RepoSkill.swift
//  Starcat
//
//  仓库 Skill 的不可变证据。路径和提交参与身份，名称只用于目标文件夹，不能合并同名条目。
//

import Foundation

/// 四态筛选只消费已核实的证据；失败和过期都不等价于“不包含”。
enum RepoSkillFilter: String, CaseIterable, Codable, Sendable {
    case any, contains, absent, unknown

    func matches(_ state: RepoSkillPresence) -> Bool {
        switch self {
        case .any: true
        case .contains: state == .contains
        case .absent: state == .absent
        case .unknown: state == .unknown
        }
    }
}

enum RepoSkillPresence: String, Codable, Sendable {
    case contains, absent, unknown
}

/// 一个 Skill 目录内的固定 blob；mode 保留脚本执行位，但安装过程从不执行脚本。
struct RepoSkillFile: Identifiable, Codable, Equatable, Sendable {
    let path: String
    let sha: String
    let size: Int?
    let mode: String

    var id: String { path }
    var sizeKB: Int { max(1, ((size ?? 0) + 1_023) / 1_024) }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var folder: String { path.contains("/") ? String(path.split(separator: "/")[0]) : "" }
}

/// 目录边界及原始描述文件同时保存；预览和安装使用同一个 commit 下的文件清单。
struct RepoSkill: Identifiable, Codable, Equatable, Sendable {
    let repositoryID: Int64
    let commitSHA: String
    let directory: String
    let name: String
    let summary: String
    let manifest: String
    let files: [RepoSkillFile]
    let installationIssue: String?

    var id: String { "\(repositoryID):\(commitSHA):\(directory)" }
    var manifestPath: String { directory + "SKILL.md" }
    var sizeKB: Int { files.reduce(0) { $0 + $1.sizeKB } }
    var symbol: String { "shippingbox" }
}

/// 整仓扫描快照可重建，不参与 CloudKit 用户数据同步。
struct RepoSkillScan: Codable, Equatable, Sendable {
    /// v2：预览正文排除 frontmatter；旧缓存仍含元数据，须整体重扫。
    static let rulesVersion = 2
    let repositoryID: Int64
    let commitSHA: String
    let sourcePushedAt: String?
    let sourceBranch: String?
    let checkedAt: Date
    let complete: Bool
    let skills: [RepoSkill]
    let diagnostics: [String]
    /// 只用于扫描中的进度展示；旧缓存缺失时仍可读取 Skill 清单。
    let manifestTotal: Int?
    let manifestChecked: Int?
    let version: Int

    func isFresh(for repo: Repo, now: Date = .now) -> Bool {
        version == Self.rulesVersion && checkedAt.addingTimeInterval(86_400) > now
            // 探索卡片可能没有分支或 pushedAt；缺少字段不是“仓库已更新”的证据。
            && (repo.pushedAt == nil || sourcePushedAt == repo.pushedAt)
            && (repo.defaultBranch == nil || sourceBranch == repo.defaultBranch)
    }

    var presence: RepoSkillPresence {
        if !skills.isEmpty { return .contains }
        return complete ? .absent : .unknown
    }
}

/// 预设安装目录。Codex 等大多数 Agent 工具默认读取通用 Agents 目录，Claude Code 使用专属目录。
enum RepoSkillTargetPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case agents
    case claudeCode

    var id: Self { self }
    var directory: String { self == .agents ? "~/.agents/skills/" : "~/.claude/skills/" }
    var defaultURL: URL {
        URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
    }
}

/// 一个安装目标目录；身份使用实际路径，预设目录与自选目录不能重复发布同一份文件。
struct RepoSkillDestination: Identifiable, Hashable, Codable, Sendable {
    let preset: RepoSkillTargetPreset?
    let url: URL

    /// 目录身份是一次解析后的快照；SwiftUI 的 diff 和状态查询不能重复访问文件系统。
    /// 安装仍使用原始授权 URL，并在发布前重新解析实际目录。
    let id: String

    init(preset: RepoSkillTargetPreset?, url: URL) {
        self.preset = preset
        self.url = url
        self.id = url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }
}

/// 用户可读错误共享同一组本地化文案，技术原因保留在扫描诊断和逐项结果中。
enum RepoSkillError: LocalizedError {
    case invalidManifest, incomplete, unsupportedFiles, conflict, verification, authorization, emptyRepository

    var errorDescription: String? {
        let key = switch self {
        case .invalidManifest: "manifest"
        case .incomplete: "incomplete"
        case .unsupportedFiles: "unsupported"
        case .conflict: "conflict"
        case .verification: "verification"
        case .authorization: "authorization"
        case .emptyRepository: "empty"
        }
        return String.l10n("repo.skills.error.\(key)")
    }
}
