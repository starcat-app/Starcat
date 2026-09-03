//
//  ToolbarRepoSelection.swift
//  Starcat
//
//  顶部 toolbar 上「当前选中 repo」的统一适配模型。
//
//  存在意义（W12 toolbar 专项 PR-1）：
//  - Manage / Trending / Weekly / Activity 四个场景的选中项分属四套数据模型
//    （`Repo` / `TrendingRepo` / `WeeklyFeedItem` / `ActivityItem.repo`），但
//    它们派发到 toolbar 的「在 GitHub 打开」「复制 clone URL」菜单时**所需字段相同**——
//    只要 owner / name / htmlUrl + 可选 clone URL / homepage 就够。
//  - 把这层提取为 `ToolbarRepoSelection` 后，`ExternalLinksMenu` 不再
//    需要环境注入 `HomeViewModel`，纯粹靠入参渲染，单测/Preview 也更容易构造。
//
//  关键约束：
//  - 字段值在构造时就已经计算好（含 https / git URL 的兜底拼接），渲染层零计算。
//  - `isStarred` 由调用方在派发时通过 `StarredRegistry.contains(ghRepoId:)` 派生；
//    不在本类型内部再访问 registry，避免「同一选中 toolbar 渲两遍读两次 registry」。
//  - Trending / Weekly 等 ephemeral 源没有 `Repo` 对象，但 owner/name 一定有，所以 issues /
//    pulls / releases 这些"纯拼 URL"的菜单项依然能正常工作。
//

import Foundation

/// 顶部 toolbar 消费的选中项最小模型。
///
/// 不实现 `Identifiable`：该值仅作为渲染参数随 SwiftUI body 重算重新构造，无需稳定 id。
struct ToolbarRepoSelection: Equatable {

    /// GitHub `owner` 段（如 `apple`）。
    let owner: String

    /// GitHub `repo` 段（如 `swift`）。
    let name: String

    /// 完整 `owner/name`，避免 toolbar 各处重复拼接。
    let fullName: String

    /// 仓库主页（GitHub repo URL）。
    ///
    /// Manage 路径优先用 `Repo.htmlUrl`；Trending / Weekly 自带 `htmlUrl?` 字段，
    /// 缺失时由本类型按 `owner/name` 兜底拼成 `https://github.com/...`。
    let htmlUrl: URL?

    /// `https` 协议 clone URL（如 `https://github.com/apple/swift.git`）。
    /// Manage 优先用 `Repo.cloneUrl`；trending / weekly 无该字段时按规则兜底拼。
    let cloneHTTPS: String

    /// `git` 协议 clone URL（如 `git@github.com:apple/swift.git`）。
    /// Manage 优先用 `Repo.sshUrl`；trending / weekly 同样按规则兜底。
    let cloneSSH: String

    /// 用户自定义 homepage（GitHub repo 设置里填的"Website"）。
    ///
    /// **2026-06-12 修订**：之前注释写「仅 Manage 路径有这个字段；trending / weekly 一律 nil」是
    /// R-01 v1.2 初版状态，R-05（2026-06-11）trending-api enricher 已拉满 10 字段含 homepage，
    /// `TrendingRepo.homepage` / `WeeklyFeedItem.card.homepage` 都已可信透传 —— 不能再写死 nil。
    /// 现在 4 个工厂方法都应该尽量传递 homepage 真值,只有真没有时才 nil。
    let homepage: URL?

    /// 是否已 star。由调用方按 `StarredRegistry.contains(ghRepoId:)` 计算，
    /// 用于 toolbar 上 star/unstar 按钮的视觉态判定。**本类型不主动访问 registry**。
    let isStarred: Bool

    // MARK: - 工厂

    /// 从已 star 的本地 `Repo` 构造（Manage 路径）。
    ///
    /// 路径选择：优先取 API 同步回来的 `cloneUrl` / `sshUrl`；缺失时按 GitHub 规则
    /// 兜底拼，避免历史缓存里少字段时菜单按钮失踪。
    static func from(repo: Repo, isStarred: Bool) -> ToolbarRepoSelection {
        ToolbarRepoSelection(
            owner: repo.owner,
            name: repo.name,
            fullName: repo.fullName,
            htmlUrl: URL(string: repo.htmlUrl),
            cloneHTTPS: nonEmpty(repo.cloneUrl) ?? defaultHTTPS(owner: repo.owner, name: repo.name),
            cloneSSH: nonEmpty(repo.sshUrl) ?? defaultSSH(owner: repo.owner, name: repo.name),
            homepage: RepoExternalLinks.homepage(repo),
            isStarred: isStarred
        )
    }

    /// 从 Trending 列表项构造（trending 没有 cloneUrl，全部走兜底拼接）。
    ///
    /// **2026-06-12 修订**：之前 `homepage: nil` 写死 —— 是 R-01 v1.2 初版「trending 模型暂无
    /// homepage 字段」的过时假设，R-05（2026-06-11）trending-api enricher 已经透传 homepage
    /// 到 `TrendingRepo.homepage`，这里再写死 nil 会让 Trending 详情页 toolbar「在 GitHub 打开」
    /// 菜单永远显不出 Homepage 子项。改为直接透传。
    static func from(trending: TrendingRepo, isStarred: Bool) -> ToolbarRepoSelection {
        ToolbarRepoSelection(
            owner: trending.owner,
            name: trending.name,
            fullName: trending.fullName,
            htmlUrl: trending.url,
            cloneHTTPS: defaultHTTPS(owner: trending.owner, name: trending.name),
            cloneSSH: defaultSSH(owner: trending.owner, name: trending.name),
            homepage: trending.homepage,
            isStarred: isStarred
        )
    }

    /// 从 Weekly 多来源聚合 feed 项构造。
    static func from(weekly: WeeklyFeedItem, isStarred: Bool) -> ToolbarRepoSelection {
        ToolbarRepoSelection(
            owner: weekly.owner,
            name: weekly.name,
            fullName: weekly.fullName,
            htmlUrl: weekly.url,
            cloneHTTPS: defaultHTTPS(owner: weekly.owner, name: weekly.name),
            cloneSSH: defaultSSH(owner: weekly.owner, name: weekly.name),
            homepage: weekly.card.homepage,
            isStarred: isStarred
        )
    }

    // MARK: - Helpers

    /// 把空串 / 纯空白当 nil 处理，匹配本地 DB 历史脏数据。
    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func defaultHTTPS(owner: String, name: String) -> String {
        "https://github.com/\(owner)/\(name).git"
    }

    private static func defaultSSH(owner: String, name: String) -> String {
        "git@github.com:\(owner)/\(name).git"
    }
}
