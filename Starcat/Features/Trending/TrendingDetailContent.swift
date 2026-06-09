//
//  TrendingDetailContent.swift
//  Starcat
//
//  R-01「三场景共用架构」Trending 详情页 ContentView 插槽。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.2 & §5.2）
//  ────────────────────────────────────────────────────────────────────────────
//
//  Trending 详情 = `RepoDetailScaffold` (Hero + heroExtension=Contributors) + body slot
//
//  本 ContentView 同时提供两块内容：
//  - **heroExtension**：`TrendingContributorsSection`（GitHub Trending 页面顶部贡献者列）
//    跟着 hero 一起折叠收起。需要外部通过 `RepoDetailScaffold(heroExtension:)` 接入。
//  - **body slot**：`ReadmeStateView`（README WebView + 翻译入口可选）
//
//  R-01 决策（§3.2.3）：
//  - **未 star** 时不渲染 tags / notes / release 三段（Scaffold 已通过 `heroShowsLocalSections=false`
//    控制；本 ContentView 也不重复渲染这三段）。
//  - **已 star** 时由 Scaffold 的 `heroShowsLocalSections=true` 控制 hero 渲染三段；
//    本 ContentView 仍只负责 contributors + readme。
//
//  ────────────────────────────────────────────────────────────────────────────
//  数据驱动
//  ────────────────────────────────────────────────────────────────────────────
//
//  入参 `dto: StarcatRepoCardDTO`（含 trending 扩展段 contributors）+ `repo: Repo`
//  （由 RepoResolver 在外层解析得到——已 star 则是本地 Repo，未 star 则是 ephemeral）。
//
//  README 加载：通过 `repo.htmlUrl` 拼 baseURL，与 Manage 详情页同款链路。
//  翻译入口：仅当 `repo.id != 0`（本地命中）时提供，避免给 ephemeral repo 走翻译缓存
//  造成 id=0 误命中。
//

import SwiftUI
import AppKit

/// Trending 场景详情页的 body 内容（README）。
///
/// 配套提供 static helper `contributorsSection(_:)` 用于 Scaffold 的 heroExtension slot。
struct TrendingDetailContent: View {

    let repo: Repo

    /// 由 Scaffold 注入：把 scroll offset 上报回去用于驱动顶部面板折叠。
    let onScrollOffset: (CGFloat) -> Void

    @Environment(ReadmeViewModel.self) private var readmeVM
    @Environment(ReadmeTranslationViewModel.self) private var translationVM
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession

    var body: some View {
        ReadmeStateView(
            state: readmeVM.state,
            baseURL: URL(string: "\(repo.htmlUrl)/blob/HEAD"),
            owner: repo.owner,
            repo: repo.name,
            onScrollOffsetChange: onScrollOffset,
            // R-01：仅本地命中（id != 0）的 repo 才提供翻译入口。
            // 避免 ephemeral repo 用 id=0 走翻译缓存造成串扰。
            translationControl: repo.id != 0 ? ReadmeTranslationControl(
                repo: repo,
                translationVM: translationVM,
                settings: settings
            ) : nil
        ) {
            // README 重新加载：调用 reload 而非 loadTrending——R-01 后 Trending 也用
            // 解析后的 Repo（可能是本地 / ephemeral），统一走 reload 链路减少分支。
            readmeVM.reload(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
        } onLogin: {
            authSession.signIn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Trending 贡献者列（heroExtension slot 内容）

/// Trending 详情页 hero 下方的贡献者头像列。
///
/// 设计要点（与原 `RepoDetailView.trendingContributorsSection` 一致）：
/// - 头像 32pt，与 `.title3` Stars/Forks 视觉权重对齐
/// - 最多显示 6 个，溢出用 "+N"
/// - 每个头像包在 `Button { NSWorkspace.open(profileURL) }`，点击跳 GitHub profile
/// - `.help(username)` hover 显示 username
/// - 头像之间负 spacing -10 实现重叠效果
///
/// **为什么不用 `Link(destination:)`**：
/// macOS 上 `Link` 外层 `.help()` 的 NSView.toolTip 传不到 Link 内部，hover 不会
/// 弹 tooltip。详见 `RepoDetailView.swift` 的 `contributorAvatar` 注释。
///
/// **入参为什么是 `TrendingRepo.Contributor` 而非 DTO 类型**：
/// R-01 v1.2 Phase B（2026-06-10）：trending 列表 row 已经走 `TrendingRepo.asCardData(...)`
/// 转 `RepoCardViewData`，详情页也直接消费 `TrendingRepo` 模型；上游 DTO 在 ViewModel
/// 解析阶段就已被映射成 `TrendingRepo.Contributor`，本视图无需再依赖 DTO 类型。
struct TrendingContributorsSection: View {

    let contributors: [TrendingRepo.Contributor]

    var body: some View {
        if contributors.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: -10) {
                ForEach(contributors.prefix(6)) { contributor in
                    contributorAvatar(contributor)
                }
                if contributors.count > 6 {
                    Text(verbatim: "+\(contributors.count - 6)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                }
            }
            // 与 RepoMetadataHeaderView 同款 horizontal padding，对齐左右边距。
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private func contributorAvatar(_ contributor: TrendingRepo.Contributor) -> some View {
        if let profileURL = contributor.profileURL {
            Button {
                NSWorkspace.shared.open(profileURL)
            } label: {
                avatarImage(contributor)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help(contributor.username)
        } else {
            avatarImage(contributor)
                .help(contributor.username)
        }
    }

    private func avatarImage(_ contributor: TrendingRepo.Contributor) -> some View {
        AsyncImage(url: contributor.avatarURL) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Circle().fill(Color.gray.opacity(0.3))
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color(NSColor.controlBackgroundColor).opacity(0.9), lineWidth: 2)
        )
    }
}
