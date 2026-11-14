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
    /// 工作台精确计数优先、本地元数据兜底；nil 时只显示标题，已知为 0 时仍显示数字。
    let openIssuesCount: Int?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                BusinessIcon(systemImage: "circle.circle", pointSize: interfaceScale.scaled(13), weight: .semibold)
                HStack(spacing: 0) {
                    Text(String.l10n("repo.issues.entry.title", defaultValue: "Issues"))
                    if let openIssuesCount {
                        Text(verbatim: " · ")
                        RepoMetadataCountLabel(count: openIssuesCount)
                    }
                }
            }
            .foregroundStyle(.primary)
            // 中性底色与描边随主题反转；深色提高不透明度，保持 Hero 色底上的可见边界。
            .modifier(RepoMetadataCapsuleStyle(
                background: Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08),
                border: Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.18)
            ))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover(opacity: 0.8, scale: 1.0)
        .clickablePointer()
        .help(String.l10n("repo.issues.entry.help", defaultValue: "查看并新建 Issue"))
        .fixedSize()
    }
}
