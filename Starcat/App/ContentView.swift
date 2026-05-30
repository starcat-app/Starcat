//
//  ContentView.swift
//  Starcat
//
//  根视图：根据 AuthSession 状态在登录页与主界面之间切换。
//
//  Week 2 范围：
//  - .unauthenticated / .awaitingUserCode → GithubAuthView
//  - .authenticated → HomePlaceholderView（Week 3 替换为 HomeView 三栏）
//

import SwiftUI

struct ContentView: View {

    @Environment(AuthSession.self) private var authSession

    var body: some View {
        Group {
            if authSession.state.isAuthenticated {
                HomePlaceholderView()
            } else {
                GithubAuthView()
            }
        }
        .animation(.smooth, value: authSession.state)
    }
}
