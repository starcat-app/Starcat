//
//  StarcatMCPModels.swift
//  Starcat
//
//  MCP Service 对外返回的数据模型。
//
//  这些 DTO 是 Starcat 内部数据库模型与 MCP structuredContent 之间的边界：
//  - 不直接把 GRDB Record 暴露给 agent，避免把未来内部字段改名变成外部协议破坏；
//  - 字段保持 snake_case，方便非 Swift agent 直接消费；
//  - 只包含只读上下文，写入类能力后续单独设计审批 / audit。
//

import Foundation

/// MCP 对外暴露的 repo 摘要。
struct MCPRepoDTO: Codable, Sendable {
    let id: Int64
    let owner: String
    let name: String
    let full_name: String
    let description: String?
    let language: String?
    let stars_count: Int
    let forks_count: Int
    let watchers_count: Int
    let topics: [String]
    let license: String?
    let homepage: String?
    let html_url: String
    let clone_url: String?
    let ssh_url: String?
    let is_private: Bool
    let is_fork: Bool
    let is_archived: Bool
    let is_starred: Bool
    let pushed_at: String?
    let created_at: String?
    let updated_at: String?
    let starred_at: String?
    let cached_at: String?
    let owner_avatar: String?
    let subscribers_count: Int?
    let default_branch: String?
    let open_issues_count: Int?

    init(repo: Repo) {
        self.id = repo.id
        self.owner = repo.owner
        self.name = repo.name
        self.full_name = repo.fullName
        self.description = repo.description
        self.language = repo.language
        self.stars_count = repo.starsCount
        self.forks_count = repo.forksCount
        self.watchers_count = repo.watchersCount
        self.topics = repo.topicsArray
        self.license = repo.license
        self.homepage = repo.homepage
        self.html_url = repo.htmlUrl
        self.clone_url = repo.cloneUrl
        self.ssh_url = repo.sshUrl
        self.is_private = repo.isPrivate
        self.is_fork = repo.isFork
        self.is_archived = repo.isArchived
        self.is_starred = repo.isStarred
        self.pushed_at = repo.pushedAt
        self.created_at = repo.createdAt
        self.updated_at = repo.updatedAt
        self.starred_at = repo.starredAt
        self.cached_at = repo.cachedAt
        self.owner_avatar = repo.ownerAvatar
        self.subscribers_count = repo.subscribersCount
        self.default_branch = repo.defaultBranch
        self.open_issues_count = repo.openIssuesCount
    }
}

/// MCP 搜索结果。
struct MCPRepoSearchResult: Codable, Sendable {
    let query: String?
    let total: Int
    let limit: Int
    let repos: [MCPRepoDTO]
}

/// MCP 语义搜索结果。
struct MCPSemanticSearchResult: Codable, Sendable {
    struct Hit: Codable, Sendable {
        let repo: MCPRepoDTO
        let score: Double
        let display_score: Double
        let tier: Int
        let reason: String

        init(hit: SemanticSearchHit) {
            self.repo = MCPRepoDTO(repo: hit.repo)
            self.score = hit.score
            self.display_score = hit.displayScore
            self.tier = hit.tier
            self.reason = hit.reason
        }
    }

    let query: String
    let total: Int
    let limit: Int
    let hits: [Hit]
}

/// MCP README 读取结果。
struct MCPReadmeResult: Codable, Sendable {
    let repo: MCPRepoDTO
    let rendered_html: String?
    let markdown: String?
    let cached_at: String?
    let etag: String?
    let last_modified: String?
}

/// MCP 标签 DTO。
struct MCPTagDTO: Codable, Sendable {
    let id: String
    let name: String
    let color: String?
    let icon: String?
    let sort_order: Int
    let is_preset: Bool
    let parent_id: String?
    let created_at: String
    let updated_at: String

    init(tag: Tag) {
        self.id = tag.id
        self.name = tag.name
        self.color = tag.color
        self.icon = tag.icon
        self.sort_order = tag.sortOrder
        self.is_preset = tag.isPreset
        self.parent_id = tag.parentId
        self.created_at = tag.createdAt
        self.updated_at = tag.updatedAt
    }
}

/// MCP 私有笔记 DTO。只在用户显式开启 `mcpExposePrivateNotes` 后返回。
struct MCPRepoNoteDTO: Codable, Sendable {
    let repo_id: Int64
    let content: String?
    let status: String
    let is_ai_generated: Bool
    let edited_at: String?

    init(note: RepoNote) {
        self.repo_id = note.repoId
        self.content = note.content
        self.status = note.status
        self.is_ai_generated = note.isAIGenerated
        self.edited_at = note.editedAt
    }
}

/// MCP 对外暴露的缓存 AI 摘要。
///
/// 不直接编码完整 `RepoAIInsight`，避免外部 Agent 依赖内部 UI、External Search 或
/// RepoContext 诊断字段。这里仅保留稳定的正文、模型与生成时间契约。
struct MCPRepoSummaryDTO: Codable, Sendable {
    let repo_id: Int64
    let one_liner: String
    let summary_markdown: String
    let model: String
    let generated_at: String

    init(repoID: Int64, insight: RepoAIInsight) {
        self.repo_id = repoID
        self.one_liner = insight.oneLiner
        self.summary_markdown = insight.summaryMarkdown ?? insight.summary
        self.model = insight.model
        self.generated_at = insight.generatedAt
    }
}

/// Agent 一次读取单仓上下文的聚合结果。
///
/// 私有笔记关闭时返回 `private_notes_exposed = false` 和 `note = nil`，而不是让整个
/// context 请求失败；这样 Agent 仍能读取 repo、标签和摘要，同时明确知道缺失原因。
struct MCPRepoContextDTO: Codable, Sendable {
    let repo: MCPRepoDTO
    let tags: [MCPTagDTO]
    let private_notes_exposed: Bool
    let note: MCPRepoNoteDTO?
    let summary: MCPRepoSummaryDTO?
}

/// MCP 当前能力快照。只暴露权限状态，不包含 Local API Key 或其它凭据。
struct MCPCapabilitiesDTO: Codable, Sendable {
    let server_version: String
    let loopback_only: Bool
    let private_notes_read: Bool
    let local_writes: Bool
    let batch_writes: Bool
    let destructive_writes: Bool
    let ai_summary_generation: Bool
}

/// 摘要生成工具的稳定返回值。
struct MCPRepoSummaryGenerationResult: Codable, Sendable {
    let repo: MCPRepoDTO
    let summary: MCPRepoSummaryDTO
    let persisted: Bool
}
