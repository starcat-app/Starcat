//
//  RepoSubscriberCountView.swift
//  Starcat
//
//  仓库详情和集合卡片共用的关注者统计，保留调用方原有的菜单或徽标样式。
//

import SwiftUI

/// 共用详情为正文底栏和关注面板提供同一个手动刷新入口。
struct RepoSubscriberCountRefresh {
    let id: UUID?
    let perform: @MainActor () -> Void
}

extension EnvironmentValues {
    @Entry var repoSubscriberCountRefresh: RepoSubscriberCountRefresh? = nil
}

/// 将按需请求绑定到仓库和当前账号，保证快速切换时只展示当前仓库的结果。
struct RepoSubscriberCountView<Content: View>: View {
    let repo: Repo
    let loadsIfMissing: Bool
    @ViewBuilder var content: (Int?) -> Content

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.repoSubscriberCountRefresh) private var subscriberCountRefresh

    private struct Target: Equatable {
        let repoID: Int64
        let fullName: String
        let scope: RepoDetailDatabaseScope
    }

    private struct Request: Equatable {
        let target: Target
        let refreshID: UUID?
    }

    @State private var resolved: (request: Request, count: Int)?

    var body: some View {
        let scope = RepoDetailDatabaseScope(dependencies)
        let target = Target(repoID: repo.id, fullName: repo.fullName, scope: scope)
        let request = Request(target: target, refreshID: subscriberCountRefresh?.id)
        let current = resolved?.request.target == target ? resolved : nil
        // 主动刷新拿到的真值优先于详情初始快照，刷新失败时继续显示上一次的值。
        let count = current?.request.refreshID != nil ? current?.count : repo.subscribersCount ?? current?.count
        let shouldRefresh = request.refreshID != nil && request.refreshID != current?.request.refreshID
        let canLoad = (shouldRefresh || (loadsIfMissing && count == nil)) && scope.isReady
            && (!repo.isPrivate || scope.authenticatedUserID != nil)

        content(count)
            .task(id: canLoad ? request : nil, priority: .utility) {
                guard canLoad else { return }
                let isCurrent = { RepoDetailDatabaseScope(dependencies) == scope }
                guard let fetchedCount = try? await RepoSubscriberCountResolver.resolve(
                    for: repo, repository: dependencies.repoRepository,
                    apiClient: dependencies.apiClient, forceRefresh: shouldRefresh, isCurrent: isCurrent
                ), !Task.isCancelled, isCurrent() else { return }
                resolved = (request, fetchedCount)
            }
    }
}
