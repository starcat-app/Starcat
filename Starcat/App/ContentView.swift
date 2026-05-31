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

    var body: some View {
        Group {
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
        }
        .animation(.smooth, value: authSession.state)
    }
}
