//
//  GrowthAttribution.swift
//  Starcat
//
//  非打扰式增长归因的纯文本与公开仓库链接构造入口。
//

import Foundation

/// 统一生成可复制、可公开发布的 Starcat 分享文案。
///
/// 关键约束：
/// - 私有仓库永远不生成 `starcat.ink/r/...`，避免把不可公开的仓库身份带出 App；
/// - 所有增长入口共用同一个源码仓库 URL，不在各个页面重复硬编码；
/// - builder 只拼纯文本，剪贴板交互继续由 `CopyFeedbackButton` 负责。
enum GrowthAttribution {
    static let signature = "Made with Starcat · Open source on GitHub"

    /// 返回公开仓库的 Starcat 分享页；私有仓库或非法 fullName 返回 nil。
    static func publicRepositoryURL(for repo: Repo) -> URL? {
        guard !repo.isPrivate else { return nil }
        return RepositoryDeepLink(
            fullName: repo.fullName,
            repositoryID: repo.id
        )?.publicURL
    }

    /// 仓库级分享文案：业务摘要后附公开分享页，并始终附 Starcat 开源仓库归因。
    static func repositoryShareText(
        title: String,
        details: [String],
        repo: Repo
    ) -> String {
        var lines = [title]
        lines.append(contentsOf: details.filter { !$0.isEmpty })
        if let publicURL = publicRepositoryURL(for: repo) {
            lines.append(publicURL.absoluteString)
        }
        lines.append("\(signature): \(AppWebsiteLinks.sourceRepository.absoluteString)")
        return lines.joined(separator: "\n")
    }

    /// 聚合统计没有单一仓库分享页，只附统计摘要与 Starcat 开源仓库归因。
    static func aggregateShareText(title: String, details: [String]) -> String {
        ([title] + details.filter { !$0.isEmpty } + [
            "\(signature): \(AppWebsiteLinks.sourceRepository.absoluteString)"
        ])
        .joined(separator: "\n")
    }
}
