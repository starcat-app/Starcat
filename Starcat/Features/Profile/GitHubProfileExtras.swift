//
//  GitHubProfileExtras.swift
//  Starcat
//
//  账户浮层专属资料模型。与 GitHubUserDTO 分离，避免非公开组织进入分享卡或导出资料。
//

import Foundation

/// 从 GitHub 成就页读取的真实勋章；等级原文来自页面，不根据活动数量推算。
struct GitHubAchievement: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let imageURL: URL
    let tier: String?
}

/// Sponsors 官方连接中的用户或组织；两种 GraphQL union 成员使用同一组最小字段。
struct GitHubSponsor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let login: String
    let avatarUrl: String?
}

/// 分别表达收到的赞助与正在赞助的账号，避免把两种关系混成同一枚徽标。
struct GitHubSponsors: Codable, Equatable, Sendable {
    let hasSponsorsListing: Bool
    let sponsors: [GitHubSponsor]
    let sponsoring: [GitHubSponsor]
}

/// 合并公开和授权列表后的结果；权限或 SSO 限制仍允许展示已取得的组织。
struct GitHubProfileOrganizations: Codable, Equatable, Sendable {
    let organizations: [GitHubOrganizationDTO]
    let accessLimited: Bool
}

/// 只暴露账户浮层需要的读取能力，测试无需实现整个 GitHub 客户端协议。
protocol GitHubProfileExtrasProviding: Sendable {
    func getProfileAchievements(login: String, forceRefresh: Bool) async throws -> [GitHubAchievement]
    func getProfileOrganizations(login: String, forceRefresh: Bool) async throws -> GitHubProfileOrganizations
    func getProfileSponsors() async throws -> GitHubSponsors
}
