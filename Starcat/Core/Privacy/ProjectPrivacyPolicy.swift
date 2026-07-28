//
//  ProjectPrivacyPolicy.swift
//  Starcat
//
//  “我的项目”公开服务门禁的单一信息源。
//
//  Private / Internal 项目可能包含仓库名称、README 和组织关系等敏感信息。任何会把
//  repo identity 发往 Starcat 公共后端、外部搜索、公开分享或 Universal Link 的入口，
//  都必须先通过这里；GitHub App 直连 GitHub 的只读请求不属于公共服务。
//

import Foundation

enum ProjectPrivacyPolicy {
    static func allowsPublicService(for repo: Repo) -> Bool {
        !repo.isPrivate
    }

    static func allowsPublicShare(for repo: Repo) -> Bool {
        allowsPublicService(for: repo)
    }

    static func allowsUniversalLink(for repo: Repo) -> Bool {
        allowsPublicService(for: repo)
    }

    static func allowsDiscoveryLookup(for repo: Repo) -> Bool {
        allowsPublicService(for: repo)
    }

    static func allowsExternalSearchContext(for repo: Repo) -> Bool {
        allowsPublicService(for: repo)
    }
}
