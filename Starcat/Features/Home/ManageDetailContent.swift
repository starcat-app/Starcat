//
//  ManageDetailContent.swift
//  Starcat
//
//  R-01「三场景共用架构」Manage 详情页 ContentView 插槽。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.2 & §5.1）
//  ────────────────────────────────────────────────────────────────────────────
//
//  Manage 详情 = `RepoDetailScaffold` (Hero) + `ManageDetailContent` (body slot)
//
//  本 ContentView 负责 body slot 内容：
//  - `RepoLocalSections`：Tags / Notes / Release 三段（v1.2 P0 起从 hero 下沉到此处）
//  - `ReadmeStateView`：README WebView + 内嵌 cacheFooter（翻译/刷新按钮）
//
//  R-01 v1.2 P0（2026-06-10）：tags / notes / release 三段从 hero 下沉到
//  ContentView，统一由 `RepoLocalSections` 渲染（带 spring 0.25s 转场动画）。
//  Manage 路径所有 repo 都已 star，三段总会渲染（repo.id != 0）。
//
//  滚动 → 折叠：把 ReadmeStateView 的 `onScrollOffsetChange` 上报到 Scaffold
//  传入的 `onScrollOffset` closure，由 Scaffold 内部换算成 collapse progress。
//
//  ────────────────────────────────────────────────────────────────────────────
//  环境依赖
//  ────────────────────────────────────────────────────────────────────────────
//
//  - `ReadmeViewModel`：README 加载状态机
//  - `ReadmeTranslationViewModel`：翻译状态机（HOM-68）
//  - `AppSettings`：翻译目标语言等
//  - `AuthSession`：未登录时 README 不能显示完整内容（私有仓库）
//

import SwiftUI

/// Manage 场景详情页的 body 内容（README + 翻译入口）。
struct ManageDetailContent: View {

    let repo: Repo

    /// 由 Scaffold 注入：把 scroll offset 上报回去用于驱动顶部面板折叠。
    let onScrollOffset: (CGFloat) -> Void

    @Environment(ReadmeViewModel.self) private var readmeVM
    @Environment(ReadmeTranslationViewModel.self) private var translationVM
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // R-01 §3.2.4：三段（tags / notes / release）从 hero 下沉到 ContentView，
            // 内置 spring 0.25s 转场（repo.id 切换时触发动画）。
            RepoLocalSections(repo: repo)

            ReadmeStateView(
                state: readmeVM.state,
                // 拼接 blob/HEAD：GitHub HTML 渲染 API 返回的相对链接是相对于仓库根目录解析的，
                // 缺少 blob/{branch} 前缀；补上后相对链接（如 README-en.md）才能正确解析为
                // https://github.com/owner/repo/blob/HEAD/README-en.md。
                baseURL: URL(string: "\(repo.htmlUrl)/blob/HEAD"),
                owner: repo.owner,
                repo: repo.name,
                onScrollOffsetChange: onScrollOffset,
                translationControl: ReadmeTranslationControl(
                    repo: repo,
                    translationVM: translationVM,
                    settings: settings
                )
            ) {
                readmeVM.reload(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
            } onLogin: {
                authSession.signIn()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
