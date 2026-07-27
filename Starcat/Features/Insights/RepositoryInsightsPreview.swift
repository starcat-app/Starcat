//
//  RepositoryInsightsPreview.swift
//  Starcat
//
//  仓库洞察的稳定滚动宿主。首个小提交先接通 Manage 详情模式与 Scaffold 折叠协议，
//  后续统计区块直接替换占位内容，不再改动 README / 洞察的生命周期边界。
//

import SwiftUI

struct RepositoryInsightsPreview: View {
    let repo: Repo
    let onScrollReport: (RepoDetailScrollReport) -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ContentUnavailableView {
                    Label("insights.repo.preview.title", systemImage: "chart.xyaxis.line")
                } description: {
                    Text(repo.fullName)
                    Text("insights.repo.preview.subtitle")
                }
                .padding(.top, 28)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
        }
        .detailScrollViewStyle()
        .onScrollGeometryChange(for: RepoDetailScrollReport.self) { geometry in
            RepoDetailScrollReport(
                offsetY: max(0, geometry.contentOffset.y),
                scrollOverflow: max(0, geometry.contentSize.height - geometry.containerSize.height)
            )
        } action: { _, report in
            onScrollReport(report)
        }
        .accessibilityLabel(Text("insights.repo.mode.insights"))
    }
}
