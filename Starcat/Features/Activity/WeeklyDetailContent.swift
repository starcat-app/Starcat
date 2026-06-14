//
//  WeeklyDetailContent.swift
//  Starcat
//
//  R-01「三场景共用架构」Weekly 详情页 ContentView 插槽。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.2 / §5.4 + R-01 v1.2 Phase B5 落地，2026-06-10）
//  ────────────────────────────────────────────────────────────────────────────
//
//  Weekly 详情 = `RepoDetailScaffold` (Hero + RepoLocalSections) + body slot
//
//  本 ContentView 负责：
//  - `ReadmeStateView`：README WebView 渲染
//  - **不**渲染贡献者列（trending 独有;weekly 没有 contributors 字段）
//  - **不**渲染 weekly issue 按钮（由 Scaffold 的 trailingActions 接入）
//
//  R-01 v1.5 修订（2026-06-10 下午, dong4j bug 反馈）：
//  - tags / notes / release 三段（`RepoLocalSections`）**从 ContentView 迁回 Scaffold
//    metadataPanel 内**,跟随 hero 整段折叠让位 README 阅读区;
//  - 本 ContentView 不再渲染 `RepoLocalSections`,body 仅剩 `ReadmeStateView`;
//  - 三段可见性逻辑 + spring star 后展开转场都由 `RepoLocalSections` 内部自治
//    （详见 `RepoDetailScaffold.swift` 文件头 v1.5 修订段）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  README 加载策略
//  ────────────────────────────────────────────────────────────────────────────
//
//  Weekly 项目 README 走 `loadTrending` 路径——周刊与 trending 同属"无本地缓存
//  写入"用例，缓存表 = `gh_readmes_trending`（PK = owner/repo），不与 manage SWR
//  状态相互污染。
//
//  **关键约束**：
//  - 使用**外部注入的 readmeVM**（由 `WeeklyDetailView` 局部持有），不复用 HomeView
//    全局 readmeVM，避免周刊详情污染 manage / trending 主路径的 README 状态机。
//  - **翻译入口**（2026-06-11 修订）：参照 `TrendingDetailContent`，**仅本地命中
//    （`repo.id != 0`）才接 `translationControl`**。理由：R-01 v1.0 设计 ⑬ 明确
//    「翻译按钮覆盖所有 repo 详情」，weekly 详情也属其中；翻译缓存以 `repo.id`
//    为外键，未命中本地的 ephemeral repo（id=0,见 `WeeklyDetailView.resolveRepo`
//    步骤 2/3）会撞坏 `readme_translations(repo_id)` 命名空间,所以未命中时
//    显式传 nil 关闭入口。
//  - 与 `translationVM` 共享 HomeView 全局实例（`@Environment` 注入），不为
//    weekly 单独建一份；按钮触发翻译时按 `control.repo` 派发，不依赖 HomeView
//    的 `selectedRepoID` 链路 prepare（点击瞬间 VM 自己会用最新 repo 重置）。
//

import SwiftUI

/// Weekly 场景详情页的 body 内容（README）。
struct WeeklyDetailContent: View {

    let repo: Repo

    /// 由 Scaffold 注入：把 scroll offset 上报回去用于驱动顶部面板折叠。
    let onScrollOffset: (CGFloat) -> Void

    /// 周刊详情专用 readmeVM（由父 view 持有，与全局 readmeVM 解耦）。
    let readmeVM: ReadmeViewModel

    @Environment(AuthSession.self) private var authSession
    // README 翻译共享 HomeView 注入的全局 translationVM + AppSettings
    // （2026-06-11 修订，理由见文件头「关键约束」段）。
    @Environment(ReadmeTranslationViewModel.self) private var translationVM
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ReadmeStateView(
            state: readmeVM.state,
            // 与其他详情页共用目录型 base URL，末尾 `/` 是相对链接保留 HEAD 的关键。
            baseURL: URL(string: repo.htmlUrl).map(ReadmeWebView.repositoryContentBaseURL),
            onScrollOffsetChange: onScrollOffset,
            // R-01 v1.0 设计 ⑬：翻译按钮覆盖所有 repo 详情。
            // 仅本地命中（repo.id != 0）才接入——ephemeral repo 用 id=0 走翻译
            // 缓存会撞坏 `readme_translations(repo_id)` 命名空间。
            translationControl: repo.id != 0 ? ReadmeTranslationControl(
                repo: repo,
                translationVM: translationVM,
                settings: settings
            ) : nil
        ) {
            readmeVM.loadTrending(
                owner: repo.owner,
                repo: repo.name,
                isLoggedIn: authSession.state.isAuthenticated
            )
        } onLogin: {
            authSession.signIn()
        }
        .environment(readmeVM)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
