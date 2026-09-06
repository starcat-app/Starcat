//
//  GitHubStarListAIGroupingPresentationObserver.swift
//  Starcat
//
//  AI 仓库分组审核页的高频 revision 观察边界。
//
//  Session 的 Worker 会连续修改 job、建议和批量选择状态。把 revision 观察放在独立的
//  零尺寸 View 中，确保这些变化只唤醒刷新桥，不让整个 Sheet 跟着重复计算 body。
//

import SwiftUI

/// 将业务 Session 的高频变化转发给缓存展示层，同时隔离 SwiftUI 的依赖追踪范围。
struct GitHubStarListAIGroupingPresentationObserver: View {
    let session: GitHubStarListAIGroupingSession
    let presentation: GitHubStarListAIGroupingPresentationStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: session.presentationRevision) { _, _ in
                presentation.scheduleSynchronize(from: session)
            }
            .onDisappear {
                presentation.cancelPendingWork()
            }
    }
}
