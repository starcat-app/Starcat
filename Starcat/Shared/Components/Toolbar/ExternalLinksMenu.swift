//
//  ExternalLinksMenu.swift
//  Starcat
//
//  顶部 toolbar 「在 GitHub 打开」下拉菜单。
//
//  原归属：`RepoListView.externalLinksMenu(repo:)`（仅 Manage 路径，闭包内直接读
//  `viewModel.selectedRepo`）。W12 toolbar 专项 PR-1 抽出到本组件，由调用方传入
//  `ToolbarRepoSelection`，让 Trending / Weekly / Activity 也能直接复用。
//
//  关键约束：
//  - 主操作（primaryAction）= 打开 repo 主页；菜单内的 issues / pulls / releases /
//    homepage 都是辅助跳转，按 GitHub 子页面规则纯字符串拼，所以 trending /
//    weekly 这种没有本地 Repo 对象的场景也能用。
//  - homepage 现在 4 场景都可能有值：Manage 走 Repo.homepage / Trending 走
//    TrendingRepo.homepage（R-05 起 trending-api enricher 已拉满）/ Weekly 走
//    WeeklyFeedItem.card.homepage / Activity-repo-backed 走本地 Repo.homepage。
//    selection 没拼出有效 URL 时整组隐藏 Divider，避免单独剩一条 homepage。
//  - **Homepage Button label 必须只放一个 Label，不要追加 Text(homepage.absoluteString)**：
//    SwiftUI Menu Button 的 label slot 收多视图时会竖排，导致 ① house 图标相对整块
//    内容居中而错位（Manage 图 1 表现）② 长 URL 撑出大空隙（Activity 图 2 表现）。
//    dong4j 2026-06-12 验收要求菜单项**不展示 URL**，跳转目标由 Tooltip 化或
//    primaryAction 配合 hover 状态展示，菜单项纯粹保留语义入口。
//

import SwiftUI
import AppKit

/// 顶部 toolbar 「在 GitHub 打开」菜单。
///
/// `selection` 由调用方按当前页面选中项构造；nil 时菜单整组隐藏（toolbar 调用方
/// 在外层自己 `if let selection { ... }`，本组件不再做 nil 守卫，让职责更纯）。
struct ExternalLinksMenu: View {

    let selection: ToolbarRepoSelection

    var body: some View {
        Menu {
            Button {
                if let issues = RepoExternalLinks.issues(owner: selection.owner, name: selection.name) {
                    NSWorkspace.shared.open(issues)
                }
            } label: {
                Label("externalLinks.issues", systemImage: "exclamationmark.bubble")
            }

            Button {
                if let pulls = RepoExternalLinks.pulls(owner: selection.owner, name: selection.name) {
                    NSWorkspace.shared.open(pulls)
                }
            } label: {
                Label("externalLinks.pullRequests", systemImage: "arrow.triangle.pull")
            }

            Button {
                if let releases = RepoExternalLinks.releases(owner: selection.owner, name: selection.name) {
                    NSWorkspace.shared.open(releases)
                }
            } label: {
                Label("externalLinks.releases", systemImage: "tag.circle")
            }

            if let homepage = selection.homepage {
                Divider()
                Button {
                    NSWorkspace.shared.open(homepage)
                } label: {
                    Label("externalLinks.homepage", systemImage: "house")
                }
            }
        } label: {
            ToolbarIcon("safari")
                .accessibilityLabel("externalLinks.openOnGithub")
        } primaryAction: {
            if let url = selection.htmlUrl {
                NSWorkspace.shared.open(url)
            }
        }
        .help("externalLinks.hint")
    }
}
