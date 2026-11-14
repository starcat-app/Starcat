//
//  GitHubOrganizationDTO.swift
//  Starcat
//
//  用户公开组织列表的最小模型，与个人资料一起缓存；不读取私密成员关系。
//

import Foundation

/// `/users/{login}/orgs` 返回的公开组织，使用稳定 ID 保持头像更新时的视图身份。
struct GitHubOrganizationDTO: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let login: String
    let avatarUrl: String?
    let description: String?
}
