//
//  DailyRadarRelatedProjectRow.swift
//  Starcat
//
//  文章末尾的相关项目沿用中栏仓库卡片，不维护另一套头像、统计和悬停样式。
//  元数据尚未加载时仅展示样本中的身份与简介，避免用零值冒充真实统计。
//

import SwiftUI

/// 单列阅读内容中的项目入口；不嵌套滚动容器，也不改变主窗口仓库选择。
struct DailyRadarRelatedProjectRow: View {
    let project: DailyRadarReport.Project
    let store: DailyRadarProjectStore
    let onOpen: () -> Void
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var scale

    var body: some View {
        Button(action: onOpen) {
            if let item = store.item(for: project.id, scope: dependencies.databaseScopeRevision) {
                UnifiedRepoRow(
                    card: item.asCardData(registry: dependencies.starredRegistry),
                    showLibraryBadge: false,
                    showReadStatusBadge: false
                )
            } else {
                placeholder
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .task(id: dependencies.databaseScopeRevision) {
            await store.load(project: project, dependencies: dependencies)
        }
    }

    /// 加载与失败都保留可点击的仓库身份，点击进入同一详情层查看或重试。
    private var placeholder: some View {
        RepoRowSurface(isSelected: false) {
            HStack(spacing: 12) {
                RemoteAvatar(urlString: RepoAvatarURL.from(owner: String(project.id.split(separator: "/")[0])), size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: project.id)
                        .font(scale.font(.body, weight: .semibold))
                        .lineLimit(1)
                    Text(verbatim: project.summary)
                        .font(scale.font(.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if store.failed(for: project.id, scope: dependencies.databaseScopeRevision) {
                            Image(systemName: "exclamationmark.circle")
                            Text("error.loadFailed")
                        } else {
                            ProgressView().controlSize(.mini)
                            Text("weekly.detail.loadingRepo")
                        }
                    }
                    .font(scale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80)
        }
    }
}
