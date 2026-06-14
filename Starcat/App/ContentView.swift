//
//  ContentView.swift
//  Starcat
//
//  根视图：根据 AuthSession 状态在登录页与主界面之间切换。
//
//  Week 3 范围：
//  - .unauthenticated / .awaitingUserCode → GithubAuthView（V2 视觉升级版，2026-06-03 上线）
//  - .authenticated → HomeView（三栏布局）
//

import SwiftUI

struct ContentView: View {

    @Environment(AuthSession.self) private var authSession
    @Environment(AppDependencies.self) private var dependencies

    /// 当用户主动点击"登录"按钮时（isAuthenticating = true）显示 GithubAuthView sheet。
    /// 注意：不使用 `!isAuthenticated` 作为条件，是为了避免应用启动时就弹出登录窗口，
    /// 用户需要先浏览 trending，点击详情遇到 403 后才主动登录。
    private var showAuthViewBinding: Binding<Bool> {
        Binding(
            get: { authSession.isAuthenticating },
            set: { _ in }
        )
    }

    var body: some View {
        HomeView(
            repository: dependencies.repoRepository,
            readmeAPI: dependencies.readmeAPI,
            readmeAvailability: dependencies.readmeAvailability,
            readmeOnHTMLLoaded: dependencies.makeReadmeOnHTMLLoadedHandler(),
            tagRepository: dependencies.tagRepository,
            repoTagRepository: dependencies.repoTagRepository,
            repoNoteRepository: dependencies.repoNoteRepository,
            searchHistoryRepository: dependencies.searchHistoryRepository,
            semanticSearchService: dependencies.semanticSearchService,
            trendingRepository: dependencies.trendingRepository,
            githubAPIClient: dependencies.apiClient,
            readmeTranslationService: dependencies.readmeTranslationService
        )
        // 这里的 SwiftUI root minWidth 会参与系统窗口约束。
        // 旧值 800×600 会在 NavigationSplitView 自动折叠 sidebar 后重新成为窗口下限，
        // 导致中栏 420 + 右栏 770 被继续压缩。改成 AppKit 硬下限同源常量，
        // 保证折叠态也至少保住 RepoList + Detail 两列。
        .frame(
            minWidth: MainWindowFrameDefaults.contentMinSize.width,
            minHeight: MainWindowFrameDefaults.contentMinSize.height
        )
        .animation(.smooth, value: authSession.state)
        .sheet(isPresented: showAuthViewBinding) {
            GithubAuthView()
        }
    }
}
