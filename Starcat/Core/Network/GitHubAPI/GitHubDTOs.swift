//
//  GitHubDTOs.swift
//  Starcat
//
//  GitHub REST API 响应解码 DTO。
//
//  设计约束：
//  - DTO 与数据库模型分离：DTO 字段名跟 GitHub 走（snake_case 自动转 camelCase），
//    数据库模型字段名跟我们 schema 走；二者通过显式 mapper 转换，互不污染
//  - 时间字段保持 String（ISO8601 原文），不在 DTO 里 Date 化，避免时区/格式纠结
//  - 不解码所有 GitHub 字段，只解码我们当前用到的——降低破坏性变更风险
//

import Foundation

// MARK: - User

/// `GET /user` 响应（也用于 starred_repos 里的 owner 嵌套字段）。
struct GitHubUserDTO: Decodable, Equatable {
    let id: Int64
    let login: String
    let name: String?
    let avatarUrl: String?
}

// MARK: - License

struct GitHubLicenseDTO: Decodable, Equatable {
    let key: String?
    let name: String?
    let spdxId: String?
}

// MARK: - Repo

/// 仓库元数据 DTO。
///
/// 注意字段映射：
/// - `stargazersCount` → 数据库 `stars_count`
/// - `fork` → 数据库 `is_fork`
/// - `archived` → 数据库 `is_archived`
/// - `private` 是 Swift 关键字，需要用 `isPrivate` 并显式 CodingKey
struct GitHubRepoDTO: Decodable, Equatable {
    let id: Int64
    let name: String
    let fullName: String
    let owner: GitHubUserDTO
    let description: String?
    let language: String?
    let stargazersCount: Int
    let forksCount: Int
    let watchersCount: Int
    let topics: [String]?
    let license: GitHubLicenseDTO?
    let homepage: String?
    let htmlUrl: String
    let cloneUrl: String?
    let sshUrl: String?
    let isPrivate: Bool
    let fork: Bool
    let archived: Bool
    let pushedAt: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case fullName
        case owner
        case description
        case language
        case stargazersCount
        case forksCount
        case watchersCount
        case topics
        case license
        case homepage
        case htmlUrl
        case cloneUrl
        case sshUrl
        // `private` 在 JSON 里就是 "private"，避免 Swift 关键字
        case isPrivate = "private"
        case fork
        case archived
        case pushedAt
        case updatedAt
        case createdAt
    }
}

// MARK: - Starred wrapper

/// 当请求头带 `Accept: application/vnd.github.star+json` 时，GitHub 返回
/// `{ "starred_at": "...", "repo": { ...full repo... } }` 而不是裸 Repo。
struct StarredRepoDTO: Decodable, Equatable {
    let starredAt: String
    let repo: GitHubRepoDTO
}
