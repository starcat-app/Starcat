//
//  Repo.swift
//  Starcat
//
//  仓库元数据，对应 docs/详细设计/01-数据库设计.md 第 2.1 节 `repos` 表。
//
//  关键约束：
//  - id 用 Int64（GitHub repo id 原生类型），与表 schema INTEGER PRIMARY KEY 一致
//  - topics 字段存 JSON 字符串，业务层用 `topicsArray` 计算属性解析；这样保持 GRDB 行映射简单
//  - 时间字段均存 ISO8601 字符串（GitHub API 直返该格式），暂不转 Date，避免时区/格式分歧
//  - is_* 字段用 Bool（GRDB 自动桥到 SQLite INTEGER 0/1）
//

import Foundation
import GRDB

/// 仓库元数据。
///
/// 该结构 1:1 映射 `repos` 表，字段顺序与 schema 保持一致以便阅读。
struct Repo: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable {

    static let databaseTableName = "repos"

    // MARK: - 标识

    /// GitHub repo ID（Int64）。
    var id: Int64

    // MARK: - 基本信息

    var owner: String
    var name: String
    /// `owner/name`，GitHub 全名，已建唯一索引。
    var fullName: String

    var description: String?
    var language: String?
    var starsCount: Int
    var forksCount: Int
    var watchersCount: Int
    /// JSON 数组字符串，如 `["ai","swift"]`。
    var topics: String?

    // MARK: - License / URL

    var license: String?
    var homepage: String?
    var htmlUrl: String
    var cloneUrl: String?
    var sshUrl: String?

    // MARK: - 状态标记

    var isPrivate: Bool
    var isFork: Bool
    var isArchived: Bool
    /// 本地视角：用户当前是否仍 star 着该 repo。取消 star 后设为 false 而非删除（保留笔记/标签）。
    var isStarred: Bool

    // MARK: - 时间字段（ISO8601）

    var pushedAt: String?
    var createdAt: String?
    var updatedAt: String?
    var starredAt: String?

    /// 本地缓存时间，与 GitHub 字段无关。
    var cachedAt: String?

    // MARK: - Codable Keys（snake_case 与表列对齐）

    enum CodingKeys: String, CodingKey {
        case id
        case owner
        case name
        case fullName = "full_name"
        case description
        case language
        case starsCount = "stars_count"
        case forksCount = "forks_count"
        case watchersCount = "watchers_count"
        case topics
        case license
        case homepage
        case htmlUrl = "html_url"
        case cloneUrl = "clone_url"
        case sshUrl = "ssh_url"
        case isPrivate = "is_private"
        case isFork = "is_fork"
        case isArchived = "is_archived"
        case isStarred = "is_starred"
        case pushedAt = "pushed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case starredAt = "starred_at"
        case cachedAt = "cached_at"
    }

    // MARK: - 派生属性

    /// 解析 topics JSON 字符串为数组；解析失败返回空数组。
    /// 不持久化此属性。
    var topicsArray: [String] {
        guard let topics, let data = topics.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
