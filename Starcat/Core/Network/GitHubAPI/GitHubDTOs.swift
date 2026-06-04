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
///
/// 注意字段可选性：
/// - `/user` 端点返回全部字段
/// - `/user/starred` 嵌套的 `owner` 只返回 id/login/avatar_url
/// 所以 followers/following/publicRepos 必须可选，否则嵌套 owner 解码失败。
struct GitHubUserDTO: Decodable, Equatable {
    let id: Int64
    let login: String
    let name: String?
    let avatarUrl: String?

    // MARK: - 用户统计（仅 /user 端点返回）

    /// 公开仓库数。
    let publicRepos: Int?
    /// 粉丝数。
    let followers: Int?
    /// 关注数。
    let following: Int?
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

struct GitHubSubscriptionDTO: Codable, Equatable {
    let subscribed: Bool
    let ignored: Bool
    let reason: String?
    let createdAt: String?
    let url: String?
    let repositoryUrl: String?
}

struct GitHubSubscriptionRequestDTO: Encodable {
    let subscribed: Bool
    let ignored: Bool
}

// MARK: - Release（HOM-47）

/// `GET /repos/{owner}/{repo}/releases` 单条响应。
///
/// 字段映射：
/// - GitHub `id`：Release 全局唯一 id（与 tag_name 不同，tag 可重命名 / 删除重建）
/// - GitHub `assets`：资产数组（dmg / pkg / zip 等）
/// - 不解码 `author` / `tarball_url` / `zipball_url`：MVP 不展示，少一份解码负担
struct GitHubReleaseDTO: Decodable, Equatable {
    let id: Int64
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let prerelease: Bool
    let draft: Bool
    let publishedAt: String?
    let createdAt: String?
    let assets: [GitHubReleaseAssetDTO]?
}

/// Release 单个资产（一个可下载的构件）。
struct GitHubReleaseAssetDTO: Decodable, Equatable {
    let id: Int64
    let name: String
    let contentType: String?
    let size: Int
    let browserDownloadUrl: String
    let downloadCount: Int
    let createdAt: String?
}
