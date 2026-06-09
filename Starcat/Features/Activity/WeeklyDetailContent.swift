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
//  Weekly 详情 = `RepoDetailScaffold` (Hero) + body slot
//
//  本 ContentView 只负责 README WebView 渲染：
//  - **不**渲染贡献者列（trending 独有；weekly 没有 contributors 字段）
//  - **不**渲染 weekly issue 按钮（由 Scaffold 的 trailingActions 接入）
//  - **不**渲染 tags / notes / release 三段（Scaffold heroShowsLocalSections 决定）
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
//  - 不接 `translationControl`：翻译 VM 用 `repo.id` 作缓存键，未命中本地（id=0）
//    会撞坏命名空间；即便本地命中也保持简洁不接（与 trending 详情页同款决策）。
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

    var body: some View {
        ReadmeStateView(
            state: readmeVM.state,
            // 拼接 blob/HEAD：与 trending / manage 详情页一致，让 README 内的相对
            // 链接能正确解析为 https://github.com/owner/repo/blob/HEAD/xxx。
            baseURL: URL(string: "\(repo.htmlUrl)/blob/HEAD"),
            owner: repo.owner,
            repo: repo.name,
            onScrollOffsetChange: onScrollOffset,
            // weekly 详情不接翻译入口（与 trending 详情对齐）。
            translationControl: nil
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
