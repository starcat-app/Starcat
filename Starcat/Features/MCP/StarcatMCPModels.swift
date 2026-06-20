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

