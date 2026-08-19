//
//  GitHubNotificationDTOs.swift
//  Starcat
//
//  `GET /notifications` 与选中后 `GET subject.url` 的解码模型。
//  列表 DTO 不含 actor / body；补全用松散 JSON，避免为每种 subject type 写一套 struct。
//

import Foundation

struct GitHubNotificationsListResponse: Sendable {
    let threads: [GitHubNotificationThreadDTO]
    let lastModified: String?
    let pollIntervalSeconds: Int?
    let nextPage: Int?
    let notModified: Bool
}

struct GitHubNotificationThreadDTO: Decodable, Equatable, Sendable {
    let id: String
    let unread: Bool
    let reason: String
    let updatedAt: String
    let subject: GitHubNotificationSubjectDTO
    let repository: GitHubNotificationRepositoryDTO

    var resolvedFullName: String {
        if let fullName = repository.fullName, !fullName.isEmpty {
            return fullName
        }
        if let owner = repository.owner?.login, let name = repository.name {
            return "\(owner)/\(name)"
        }
        return repository.name ?? "unknown/unknown"
    }
}

struct GitHubNotificationSubjectDTO: Decodable, Equatable, Sendable {
    let title: String
    let url: String?
    let latestCommentUrl: String?
    let type: String
}

struct GitHubNotificationRepositoryDTO: Decodable, Equatable, Sendable {
    let id: Int64?
    let fullName: String?
    let name: String?
    let owner: GitHubNotificationOwnerDTO?
}

struct GitHubNotificationOwnerDTO: Decodable, Equatable, Sendable {
    let login: String?
}

struct GitHubNotificationSubjectHydration: Equatable, Sendable {
    let htmlURL: String?
    let actorLogin: String?
    let excerpt: String?
    let createdAt: String?
}

/// Issue / PR 下的一条评论。详情页按 GitHub 会话顺序渲染 Markdown。
struct GitHubNotificationComment: Equatable, Codable, Sendable, Identifiable {
    let id: Int64
    let login: String
    let body: String
    let htmlURL: String?
    let createdAt: String?
}
