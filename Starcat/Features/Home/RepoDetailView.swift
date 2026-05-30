//
//  RepoDetailView.swift
//  Starcat
//
//  右栏：仓库详情。
//
//  Week 3 范围：基础元信息卡片（头像、名称、描述、stats、topics、外链）。
//  README WebView 渲染、标签管理、笔记编辑留 Week 4。
//
//  设计约束：
//  - 无选中行时显示空态
//  - "Open on GitHub" 按钮：用 NSWorkspace 打开外部浏览器，不在沙盒内嵌
//

import SwiftUI
import AppKit

struct RepoDetailView: View {

    @Environment(HomeViewModel.self) private var viewModel

    var body: some View {
        if let repo = viewModel.selectedRepo {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(repo)
                    descriptionSection(repo)
                    statsSection(repo)
                    topicsSection(repo)
                    Divider()
                    readmePlaceholder
                    Spacer(minLength: 24)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(repo.name)
            .navigationSubtitle(repo.owner)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openOnGitHub(url: repo.htmlUrl)
                    } label: {
                        Label("在 GitHub 打开", systemImage: "safari")
                    }
                }
            }
        } else {
            emptyState
        }
    }

    // MARK: - 子段

    private func header(_ repo: Repo) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: repo.owner), size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(repo.fullName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    if repo.isArchived {
                        BadgeChip(text: "Archived", systemImage: "archivebox", tint: .orange)
                    }
                    if repo.isFork {
                        BadgeChip(text: "Fork", systemImage: "tuningfork", tint: .gray)
                    }
                    if repo.isPrivate {
                        BadgeChip(text: "Private", systemImage: "lock.fill", tint: .purple)
                    }
                    if let license = repo.license {
                        BadgeChip(text: license, systemImage: "scale.3d", tint: .secondary)
                    }
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func descriptionSection(_ repo: Repo) -> some View {
        if let desc = repo.description, !desc.isEmpty {
            Text(desc)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private func statsSection(_ repo: Repo) -> some View {
        HStack(spacing: 24) {
            StatItem(label: "Stars", value: repo.starsCount, systemImage: "star.fill", tint: .yellow)
            StatItem(label: "Forks", value: repo.forksCount, systemImage: "tuningfork", tint: .secondary)
            StatItem(label: "Watchers", value: repo.watchersCount, systemImage: "eye.fill", tint: .secondary)
        }
    }

    @ViewBuilder
    private func topicsSection(_ repo: Repo) -> some View {
        let topics = repo.topicsArray
        if !topics.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Topics")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(topics, id: \.self) { topic in
                        Text(topic)
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
    }

    /// Week 3 README 占位；Week 4 接入 WebView。
    private var readmePlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("README")
                .font(.headline)
            Text("README WebView 将在 Week 4 接入。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("未选中仓库")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("从左侧列表选择一个查看详情")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 外链

    private func openOnGitHub(url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }
}

// MARK: - 小组件

/// 通用胶囊徽章；命名避开 `Tag`（与 Core/Database/Models/Tag 冲突）。
private struct BadgeChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}

private struct StatItem: View {
    let label: String
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).foregroundStyle(tint)
                Text(value, format: .number).monospacedDigit()
            }
            .font(.system(size: 16, weight: .medium))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - FlowLayout（Topics 自动换行）

/// 简易 Flow 布局：左到右排列，超出宽度换行。
/// 用 SwiftUI 原生 `Layout` 协议实现，避免依赖第三方。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
