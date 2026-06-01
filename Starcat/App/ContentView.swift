//
//  ContentView.swift
//  Starcat
//
//  根视图：根据 AuthSession 状态在登录页与主界面之间切换。
//
//  Week 3 范围：
//  - .unauthenticated / .awaitingUserCode → GithubAuthView
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
            tagRepository: dependencies.tagRepository,
            repoTagRepository: dependencies.repoTagRepository,
            repoNoteRepository: dependencies.repoNoteRepository,
            trendingRepository: dependencies.trendingRepository,
            githubAPIClient: dependencies.apiClient
        )
        .frame(minWidth: 800, minHeight: 600)
        .animation(.smooth, value: authSession.state)
        .sheet(isPresented: showAuthViewBinding) {
            GithubAuthView()
        }
    }
}
