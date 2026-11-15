//
//  GitHubOrganizationDTO.swift
//  Starcat
//
//  GitHub 组织的最小模型；公开列表与当前用户授权列表使用相同的响应字段。
//

import Foundation

/// 组织是否公开取决于查询端点；私有成员关系仅由账户浮层持有，不写回公开个人资料 DTO。
struct GitHubOrganizationDTO: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let login: String
    let avatarUrl: String?
    let description: String?
}
