//
//  ActivityReleaseDetailContent.swift
//  Starcat
//
//  活动页「发行版」详情下半部分：同一个 repo 的 Release notes Markdown 时间线。
//
//  设计约束：
//  - 上半部分由 `RepoDetailScaffold` 统一渲染，本文件只负责 body slot。
//  - Release notes 使用 GitHub API 返回的完整 Markdown 原文，交给 MarkdownUI 渲染。
//  - ScrollView 必须把 offset 回传给 Scaffold，保证 hero + RepoLocalSections 跟随折叠，
//    与 Manage / Trending / Activity repo-backed 的 README 详情体验一致。
//

import AppKit
import MarkdownUI
import SwiftUI

struct ActivityReleaseDetailContent: View {

    let repo: Repo
    let releases: [ReleaseRecord]
    let onScrollOffset: (CGFloat) -> Void

    /// 默认展开最新一条 Release，其余折叠。
    ///
    /// `ReleaseRecord.id` 是 GitHub release 全局唯一 id，用 Set 做展开状态稳定可靠。
    /// 当 releases 快照变化（例如详情打开后本地缓存刷新）时，重置为“最新一条展开”，
    /// 符合 dong4j 对初始状态的要求。
    @State private var expandedReleaseIDs: Set<Int64> = []
    @State private var expansionSnapshotIDs: [Int64] = []

    var body: some View {
        ScrollView {
            if releases.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    header
                    ForEach(releases, id: \.id) { release in
                        releaseCard(release)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .detailScrollViewStyle()
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentOffset.y)
        } action: { _, newOffset in
            onScrollOffset(newOffset)
        }
        .onAppear {
            syncDefaultExpansionIfNeeded(force: true)
        }
        .onChange(of: releaseIDs) { _, _ in
            syncDefaultExpansionIfNeeded(force: true)
        }
        // 与 README 详情页的 `ReadmeStateView.frame(maxWidth:maxHeight:)` 对齐：
        // body slot 必须吃满 Scaffold 剩余空间，滚动才发生在内容区自身，而不是让
        // 外层布局按内容高度重新测量。否则顶部折叠虽然能被 offset 驱动，但视觉节奏
        // 会和 Manage / Trending / Activity repo-backed 的 README 详情不一致。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("activity.release.timeline.title", systemImage: "shippingbox")
                .font(.headline)
            Text(verbatim: "\(releases.count)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "shippingbox",
            title: "activity.release.empty.title",
            subtitle: "activity.release.empty.subtitle",
            iconSize: 40,
            spacing: 12
        )
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding()
    }

    private func releaseCard(_ release: ReleaseRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            releaseHeader(release, isExpanded: expandedReleaseIDs.contains(release.id))
            if expandedReleaseIDs.contains(release.id) {
                releaseBody(release)
                assetsSection(release)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        }
    }

    private func releaseHeader(_ release: ReleaseRecord, isExpanded: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                toggleReleaseExpansion(release.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(verbatim: release.name?.isEmpty == false ? release.name! : release.tagName)
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Text(verbatim: release.tagName)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.bar, in: Capsule())

                    if release.isPrerelease {
                        Text("releases.row.prerelease")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.orange)
                    }
                }

                if let date = Self.releaseDate(release) {
                    Label(Self.absoluteDate(date), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if let url = URL(string: release.htmlUrl) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("releases.openOnGitHub", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
            }
        }
    }

    @ViewBuilder
    private func releaseBody(_ release: ReleaseRecord) -> some View {
        if let markdown = release.bodyMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
           !markdown.isEmpty {
            Markdown(markdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("activity.release.noNotes")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func assetsSection(_ release: ReleaseRecord) -> some View {
        let assets = ReleaseAssetCodec.decode(release.assetsJson)
        if !assets.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(assets) { asset in
                        assetRow(asset)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(String(format: String(localized: "releases.row.assetsCountFormat"), assets.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func assetRow(_ asset: ReleaseAsset) -> some View {
        HStack(spacing: 8) {
            Image(systemName: assetIcon(asset.name))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(verbatim: asset.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            if let url = URL(string: asset.browserDownloadUrl) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("releases.downloadAsset", systemImage: "arrow.down.circle")
                        .font(.caption2)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help("releases.downloadAsset")
            }
        }
        .padding(.vertical, 3)
    }

    private static func releaseDate(_ release: ReleaseRecord) -> Date? {
        ActivityReleaseDetailScaffoldShell.releaseDate(release)
    }

    private static func absoluteDate(_ date: Date) -> String {
        ActivityReleaseDetailScaffoldShell.absoluteDate(date)
    }

    private func assetIcon(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".dmg") { return "internaldrive" }
        if lower.hasSuffix(".pkg") { return "shippingbox.fill" }
        if lower.hasSuffix(".zip") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return "doc.zipper" }
        if lower.hasSuffix(".exe") || lower.hasSuffix(".msi") { return "pc" }
        if lower.hasSuffix(".deb") || lower.hasSuffix(".rpm") || lower.hasSuffix(".appimage") { return "terminal" }
        if lower.hasSuffix(".app") { return "macwindow" }
        return "doc"
    }

    private var releaseIDs: [Int64] {
        releases.map(\.id)
    }

    private func toggleReleaseExpansion(_ releaseID: Int64) {
        if expandedReleaseIDs.contains(releaseID) {
            expandedReleaseIDs.remove(releaseID)
        } else {
            expandedReleaseIDs.insert(releaseID)
        }
    }

    private func syncDefaultExpansionIfNeeded(force: Bool = false) {
        let ids = releaseIDs
        guard force || expansionSnapshotIDs != ids else { return }
        expansionSnapshotIDs = ids
        if let latest = ids.first {
            expandedReleaseIDs = [latest]
        } else {
            expandedReleaseIDs = []
        }
    }
}
