//
//  ActivityRepoDetailContent.swift
//  Starcat
//
//  R-01「三场景共用架构」Activity-repo-backed 详情页 ContentView 插槽。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.2 & §5.4）
//  ────────────────────────────────────────────────────────────────────────────
//
//  Activity-repo-backed（即 ActivityCategory 是 starredRepo / language / topic 等
//  关联到具体 Repo 的活动）详情 = `RepoDetailScaffold` + `ActivityRepoDetailContent`。
//
//  本 ContentView 负责 body slot 内容：
//  - `RepoLocalSections`：Tags / Notes / Release 三段（v1.2 P0 起从 hero 下沉）
//  - `ReadmeStateView`：README WebView（含翻译入口，活动总是已 star）
//
//  R-01 v1.2 P0（2026-06-10）决策（§3.2.4 / §3.2.6）：
//  - Activity-repo-backed 路径**总是已 star**（ActivityViewModel 只对本地 starred
//    生成此类活动），所以 RepoLocalSections 总会渲染（repo.id != 0）。
//  - 视觉与 ManageDetailContent 完全一致——仅命名分离便于将来扩展（如未来想加
//    "活动 timeline" 段落，在此处独立扩展，不污染 Manage 路径）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  数据驱动
//  ────────────────────────────────────────────────────────────────────────────
//
//  入参 `repo: Repo`（已 star，从本地 DB 拿）。
//

import SwiftUI

/// Activity-repo-backed 场景详情页的 body 内容（README + 翻译）。
struct ActivityRepoDetailContent: View {

    let repo: Repo

    /// 由 Scaffold 注入：把 scroll offset 上报回去用于驱动顶部面板折叠。
    let onScrollOffset: (CGFloat) -> Void

    @Environment(ReadmeViewModel.self) private var readmeVM
    @Environment(ReadmeTranslationViewModel.self) private var translationVM
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // R-01 §3.2.4：三段在 ContentView 渲染（activity 路径总是已 star，
            // repo.id != 0 → 总会渲染三段）。
            RepoLocalSections(repo: repo)

            ReadmeStateView(
                state: readmeVM.state,
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
