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
//  关联到具体 Repo 的活动）详情 = `RepoDetailScaffold` (Hero + RepoLocalSections) +
//  `ActivityRepoDetailContent`。
//
//  本 ContentView 负责 body slot 内容：
//  - `ReadmeStateView`：README WebView（含翻译入口,活动总是已 star）
//
//  R-01 v1.5 修订（2026-06-10 下午, dong4j bug 反馈）：
//  - tags / notes / release 三段（`RepoLocalSections`）**从 ContentView 迁回 Scaffold
//    metadataPanel 内**,跟随 hero 整段折叠让位 README 阅读区;
//  - 本 ContentView 不再渲染 `RepoLocalSections`,body 仅剩 `ReadmeStateView`;
//  - Activity-repo-backed 路径**总是已 star**（ActivityViewModel 只对本地 starred
//    生成此类活动）+ 必登录,所以三段总会渲染（详见 `RepoDetailScaffold.swift`
//    文件头 v1.5 修订段）。
//
//  视觉与 ManageDetailContent 完全一致——仅命名分离便于将来扩展（如未来想加
//  "活动 timeline" 段落,在此处独立扩展,不污染 Manage 路径）。
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
    let onScrollReport: (RepoDetailScrollReport) -> Void

    @Environment(ReadmeViewModel.self) private var readmeVM
    @Environment(ReadmeTranslationViewModel.self) private var translationVM
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession

    var body: some View {
        // v1.5 修订（2026-06-10）：RepoLocalSections 已迁回 Scaffold metadataPanel,
        // 本 ContentView body 仅剩 ReadmeStateView,无需再包 VStack。
        ReadmeStateView(
            state: readmeVM.state,
            baseURL: URL(string: repo.htmlUrl).map(ReadmeWebView.repositoryContentBaseURL),
            onScrollReportChange: onScrollReport,
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
