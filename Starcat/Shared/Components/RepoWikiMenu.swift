//
//  RepoWikiMenu.swift
//  Starcat
//
//  Repo 详情页统一的外部 Wiki 下拉入口。
//
//  设计约束：
//  - 组件挂在 RepoDetailScaffold，Manage / Trending / Weekly / Activity 四类详情页共用。
//  - Wiki 是公开阅读能力，不依赖 GitHub 登录，也不依赖当前 repo 是否已 Star。
//  - 请求中、未收录、服务错误都不占 UI 空间；只有服务端确认 indexed 才显示菜单。
//  - `.task(id:)` 在切换 repo 时自动取消旧请求并重跑，避免旧结果串到新详情页。
//

import SwiftUI

/// 详情页 Hero action 区的 Wiki 下拉菜单。
struct RepoWikiMenu: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @State private var links: [WikiLink] = []

    var body: some View {
        Group {
            if !links.isEmpty {
                Menu {
                    ForEach(links) { link in
                        Link(destination: link.url) {
                            Label(link.title, systemImage: "arrow.up.right.square")
                        }
                    }
                } label: {
                    Label("wiki.menu.title", systemImage: "book.pages")
                        .font(.body)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("wiki.menu.help"))
            }
        }
        .task(id: repo.fullName) {
            await loadLinks()
        }
    }

    /// 每次 repo 变化先清掉旧菜单，随后查询单仓库状态；失败只记日志并保持隐藏。
    private func loadLinks() async {
        links = []
        do {
            let items = try await dependencies.wikiAPI.fetchStatus(owner: repo.owner, repo: repo.name)
            guard !Task.isCancelled else { return }
            links = RepoWikiMenuState.make(items: items)
        } catch is CancellationError {
            // SwiftUI 切换 repo 的正常取消，不记录成网络错误。
        } catch {
            AppLog.network.warning(
                "Wiki lookup failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
