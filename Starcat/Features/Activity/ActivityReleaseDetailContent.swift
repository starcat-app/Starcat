//
//  ActivityReleaseDetailContent.swift
//  Starcat
//
//  活动页「发行版」详情下半部分：同一个 repo 的 Release notes Markdown 时间线。
//
//  设计约束：
//  - 上半部分由 `RepoDetailScaffold` 统一渲染，本文件只负责 body slot。
//  - Release notes 先做 GitHub Markdown 预处理（HTML `<img>`、列表项独立行图片），
//    再交给 MarkdownUI；大图按详情栏宽度等比缩小。
//  - ScrollView 必须把 offset 回传给 Scaffold，保证 hero + RepoLocalSections 跟随折叠，
//    与 Manage / Trending / Activity repo-backed 的 README 详情体验一致。
//

import AppKit
import MarkdownUI
import SwiftUI

struct ActivityReleaseDetailContent: View {

    let repo: Repo
    let releases: [ReleaseRecord]
    let onScrollReport: (RepoDetailScrollReport) -> Void

    /// 默认展开最新一条 Release，其余折叠。
    ///
    /// `ReleaseRecord.id` 是 GitHub release 全局唯一 id，用 Set 做展开状态稳定可靠。
    /// 当 releases 快照变化（例如详情打开后本地缓存刷新）时，重置为“最新一条展开”，
    /// 符合 dong4j 对初始状态的要求。
    @State private var expandedReleaseIDs: Set<Int64> = []
    @State private var expansionSnapshotIDs: [Int64] = []
    @State private var expandedAssetReleaseIDs: Set<Int64> = []
    /// 折叠/展开前锚定当前 release 卡片，避免 ScrollView 因高度突变乱跳。
    @State private var scrollAnchorReleaseID: Int64?
    /// 展开/折叠布局重算期间暂停向 Scaffold 上报滚动，避免 hero 折叠 progress 跟着抖。
    @State private var isExpansionLayoutPass = false
    /// 附件下载结果挂在详情底部，避免行内 toast 居中。
    @State private var downloadToast: String?
    @State private var downloadToastFileURL: URL?

    var body: some View {
        ScrollView {
            if releases.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    header
                    ForEach(releases, id: \.id) { release in
                        releaseCard(release)
                            .id(release.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .scrollPosition(id: $scrollAnchorReleaseID, anchor: .top)
        .detailScrollViewStyle()
        .reportingMarkdownContainerWidth(horizontalInset: 24)
        .releaseAssetDownloadToast(
            message: $downloadToast,
            fileURL: $downloadToastFileURL
        )
        .onScrollGeometryChange(for: RepoDetailScrollReport.self) { geometry in
            let overflow = max(0, geometry.contentSize.height - geometry.containerSize.height)
            return RepoDetailScrollReport(
                offsetY: max(0, geometry.contentOffset.y),
                scrollOverflow: overflow
            )
        } action: { _, report in
            guard !isExpansionLayoutPass else { return }
            onScrollReport(report)
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
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(verbatim: release.name?.isEmpty == false ? release.name! : release.tagName)
                                .font(.headline)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help(isExpanded ? Text("releases.row.collapseNotes") : Text("releases.row.expandNotes"))

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
            Markdown(GitHubMarkdownPreparing.prepare(markdown))
                .textSelection(.enabled)
                // 与订阅发布时间线同一套：大截图按详情栏宽度等比缩小，避免被卡片裁切。
                .fittedGitHubMarkdownImages()
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
            let isExpanded = expandedAssetReleaseIDs.contains(release.id)
            DisclosureGroup(
                isExpanded: Binding(
                    get: { isExpanded },
                    set: { expanded in
                        if expanded { expandedAssetReleaseIDs.insert(release.id) }
                        else { expandedAssetReleaseIDs.remove(release.id) }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                        ReleaseAssetRowView(
                            asset: asset,
                            rowIndex: index,
                            onDownloadFinished: { finish in
                                ReleaseAssetDownloadToastSupport.apply(
                                    finish,
                                    message: &downloadToast,
                                    fileURL: &downloadToastFileURL
                                )
                            }
                        )
                    }
                }
                .padding(.top, 4)
            } label: {
                Button {
                    if isExpanded { expandedAssetReleaseIDs.remove(release.id) }
                    else { expandedAssetReleaseIDs.insert(release.id) }
                } label: {
                    HStack {
                        Text(String(format: String.l10n("releases.row.assetsCountFormat"), assets.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
    }

    private static func releaseDate(_ release: ReleaseRecord) -> Date? {
        ActivityReleaseDetailScaffoldShell.releaseDate(release)
    }

    private static func absoluteDate(_ date: Date) -> String {
        ActivityReleaseDetailScaffoldShell.absoluteDate(date)
    }

    private var releaseIDs: [Int64] {
        releases.map(\.id)
    }

    private func toggleReleaseExpansion(_ releaseID: Int64) {
        scrollAnchorReleaseID = releaseID
        isExpansionLayoutPass = true
        if expandedReleaseIDs.contains(releaseID) {
            expandedReleaseIDs.remove(releaseID)
        } else {
            expandedReleaseIDs.insert(releaseID)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            isExpansionLayoutPass = false
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
