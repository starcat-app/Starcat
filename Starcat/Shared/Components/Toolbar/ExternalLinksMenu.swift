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
//  - homepage 只对 Manage 路径有意义（trending / weekly 没有这个字段）；selection
//    为 nil 时整组隐藏 Divider，避免单独剩一条 homepage。
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
                    Text(homepage.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
