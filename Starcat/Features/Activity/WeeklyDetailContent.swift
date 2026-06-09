//
//  WeeklyDetailContent.swift
//  Starcat
//
//  R-01「三场景共用架构」Weekly 详情页 ContentView 插槽。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.2 & §5.3）
//  ────────────────────────────────────────────────────────────────────────────
//
//  Weekly 详情 = `RepoDetailScaffold` (Hero) + `WeeklyDetailContent` (body slot)
//
//  本 ContentView 负责 body slot 内容：
//  - `ReadmeStateView`：README WebView（不接翻译入口）
//
//  R-01 决策（§3.2.3）：
//  - **未 star** 时不渲染 tags / notes / release 三段；本地命中（已 star）时由
//    Scaffold 的 `heroShowsLocalSections=true` 控制 hero 渲染三段。
//  - 周刊期号入口通过 `RepoDetailViewData.trailingActions` 的 `.weeklyIssue` 由
//    Scaffold 渲染（见 RepoDetailScaffold.actionButton case `.weeklyIssue`）。
//  - 翻译入口：仅当本地命中（`repo.id != 0`）时提供，避免 ephemeral repo id=0
//    走翻译缓存造成串扰；保留与 Manage 详情页一致的翻译能力。
//
//  ────────────────────────────────────────────────────────────────────────────
//  数据驱动
//  ────────────────────────────────────────────────────────────────────────────
//
//  入参 `repo: Repo`（由 `RepoResolver` 在外层解析得到——已 star 则是本地 Repo，
//  未 star 则是 ephemeral）。
//
//  README 加载：用 `repo.htmlUrl` 拼 baseURL 走 `readmeVM.reload(repo:)`，与 Manage
//  详情页同款链路；调用方需在外层提供 ReadmeViewModel @State，避免共享 readmeVM
//  状态污染（参考 WeeklyDetailView 现有 `@State readmeVM` 模式）。
//

import SwiftUI

/// Weekly 场景详情页的 body 内容（README）。
struct WeeklyDetailContent: View {

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
            translationControl: repo.id != 0 ? ReadmeTranslationControl(
                repo: repo,
                translationVM: translationVM,
                settings: settings
            ) : nil
        ) {
            readmeVM.reload(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
        } onLogin: {
            authSession.signIn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
