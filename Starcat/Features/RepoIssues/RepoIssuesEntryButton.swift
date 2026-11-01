//
//  RepoIssuesEntryButton.swift
//  Starcat
//
//  详情页 hero 顶部操作区的「Issues + 数量」入口胶囊。
//
//  设计（2026-11-01，dong4j 设计图）：
//  - 「Issues 图标 + Issues + 未解决数量」，锚定同排其它 hero 图标胶囊的视觉体积；
//  - 数量用本地 `Repo.openIssuesCount` 兜底（含 PR，打开浮层后由 Search API 精确刷新）；
//  - 未解决数量缺失（老数据未同步）时只显示 "Issues"，不显示占位 0。
//

import SwiftUI

struct RepoIssuesEntryButton: View {
    /// 本地已同步的未解决数（含 PR）；nil 时胶囊只显示 "Issues"。
    let openIssuesCount: Int?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "circle.circle")
                    .font(.system(size: 12, weight: .semibold))
                Text(String.l10n("repo.issues.entry.title", defaultValue: "Issues"))
                    .font(.system(size: 12, weight: .semibold))
                if let openIssuesCount, openIssuesCount > 0 {
                    Text(openIssuesCount, format: .number)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .heroActionIconSurface(colorScheme: colorScheme)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(String.l10n("repo.issues.entry.help", defaultValue: "查看并新建 Issue"))
        .fixedSize()
    }
}
