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
//  Manage 详情 = `RepoDetailScaffold` (Hero + RepoLocalSections) + `ManageDetailContent` (body slot)
//
//  本 ContentView 负责 body slot 内容：
//  - `ReadmeStateView`：README WebView + 内嵌 cacheFooter（翻译/刷新按钮）
//
//  R-01 v1.5 修订（2026-06-10 下午, dong4j bug 反馈）：
//  - tags / notes / release 三段（`RepoLocalSections`）**从 ContentView 迁回 Scaffold
//    metadataPanel 内**,跟随 hero 整段折叠让位 README 阅读区;
//  - 本 ContentView 不再渲染 `RepoLocalSections`,body 仅剩 `ReadmeStateView`;
//  - 4 场景的三段调用 100% 同构,Scaffold 内置消除重复(详见 `RepoDetailScaffold.swift`
//    文件头 v1.5 修订段)。
//
//  R-01 v2.1 修订（2026-06-11 晚, dong4j bug 反馈「右下角多了一个一模一样的刷新图标」）：
//  - 撤销 P0-E（2026-06-10）的「Scaffold overlay 浮动刷新按钮」设计 §3.2.9。
//  - 原 §3.2.9 给 Scaffold 加 `onRefresh:` 入参,Manage 详情通过它在 bottomTrailing
//    overlay 出一个浮动 `SyncIconButton` 触发 `viewModel.reloadItems(forceRefresh: true)`;
//    但 `ReadmeStateView.cacheFooter` **始终**也渲染一个同款 `SyncIconButton`(只刷
//    README) → Manage 视觉上同位置叠两个一样的图标,用户分不清职责差异,反馈为 bug。
//  - 修复方向(dong4j 选 A:合并):cacheFooter 内那个按钮在 Manage 场景**同时**刷
//    README + reloadItems。本 ContentView 注入 `HomeViewModel`,onRetry 闭包先发
//    `readmeVM.reload(...)`(内部 fire-and-forget Task),再 `Task { await viewModel.reloadItems }`,
//    两个动作并行不阻塞 UI。Trending / Activity / Weekly 的 ContentView 不变(本来就只
//    刷 README,符合各自语义)。
//  - 关键约束:① cacheFooter 按钮 tooltip 仍是 `readme.refresh`,文案没改——避免影响
//    其他 3 个共用 `ReadmeStateView` 的场景;Manage 场景下事实上扩展到「整页刷新」是
//    合理的(用户在详情页点刷新自然期望全刷),不引入额外按钮分裂 UI。② Scaffold 同步
//    删除 `onRefresh` 参数 + overlay,详见 `RepoDetailScaffold.swift` 文件头 v2.1 修订段。
//
//  滚动 → 折叠：把 ReadmeStateView 的 `onScrollReportChange` 上报到 Scaffold
//  传入的 `onScrollReport` closure,由 Scaffold 内部换算成 collapse progress,
//  Scaffold 的 metadataPanel（含 hero + RepoLocalSections）整段同步折叠。
//
//  ────────────────────────────────────────────────────────────────────────────
//  环境依赖
//  ────────────────────────────────────────────────────────────────────────────
//
//  - `ReadmeViewModel`：README 加载状态机
//  - `ReadmeTranslationViewModel`：翻译状态机（HOM-68）
//  - `AppSettings`：翻译目标语言等
//  - `AuthSession`：未登录时 README 不能显示完整内容（私有仓库）
//  - `HomeViewModel`：v2.1 起 onRetry 内调 `reloadItems(forceRefresh: true)` 用
//

import SwiftUI

/// Manage 场景详情页的 body 内容（README + 翻译入口）。
struct ManageDetailContent: View {

    let repo: Repo

    /// 由 Scaffold 注入：把 scroll offset 上报回去用于驱动顶部面板折叠。
    let onScrollReport: (RepoDetailScrollReport) -> Void

    @Environment(ReadmeViewModel.self) private var readmeVM
    @Environment(ReadmeTranslationViewModel.self) private var translationVM
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession
    /// v2.1（2026-06-11）：onRetry 闭包同时刷 README + 整个 repo 视图数据(缓存 repo +
    /// tags + notes + release 计数等)。详见文件头 v2.1 修订段。
    @Environment(HomeViewModel.self) private var viewModel

    var body: some View {
        // v1.5 修订（2026-06-10）：RepoLocalSections 已迁回 Scaffold metadataPanel,
        // 本 ContentView body 仅剩 ReadmeStateView,无需再包 VStack。
        ReadmeStateView(
            state: readmeVM.state,
            contentScope: .manage(repoId: repo.id),
            // 统一构造带末尾 `/` 的目录 URL，避免 WebKit 把 HEAD 当文件名后丢掉分支段。
            baseURL: URL(string: repo.htmlUrl).map(ReadmeWebView.repositoryContentBaseURL),
            onScrollReportChange: onScrollReport,
            translationControl: ReadmeTranslationControl(
                repo: repo,
                translationVM: translationVM,
                settings: settings
            )
        ) {
            // v2.1（2026-06-11）：Manage 场景下「刷新」=「刷 README + 重拉 repo 视图数据」。
            // - `readmeVM.reload(repo:isLoggedIn:)` 是同步入口,内部 fire-and-forget Task,
            //   立即返回不阻塞 UI;
            // - `viewModel.reloadItems(forceRefresh: true)` 重拉 starred_repos / tags /
            //   notes / release 计数等视图数据,需要 await,放进独立 Task 与 README 加载
            //   并行进行;
            // - 两者并行触发,UI 由各自 @Observable 状态机驱动,互不阻塞。
            readmeVM.reload(repo: repo, isLoggedIn: authSession.state.isAuthenticated)
            Task { await viewModel.reloadItems(forceRefresh: true) }
        } onLogin: {
            authSession.signIn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
