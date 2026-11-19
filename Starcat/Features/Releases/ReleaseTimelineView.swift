//
//  ReleaseTimelineView.swift
//  Starcat
//
//  订阅版本工作区。左侧导航始终保留，右侧只呈现选中版本的说明或下载文件。
//

import SwiftUI

struct ReleaseTimelineView: View {
    @Bindable var model: ReleaseTimelineViewModel
    let onClose: () -> Void
    @Environment(\.starcatInterfaceScale) private var scale
    @Namespace private var rowSelection
    @State private var tab = ReleaseWorkspaceTab.notes
    @State private var assetFilter = ReleaseArtifactFilter()
    @State private var downloads = ReleaseWorkspaceDownloads()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    sidebar.frame(width: min(280, geometry.size.width * 0.25))
                        .background(.bar)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .nativeDetailTransition(value: model.selectedID)
                }
            }
            if let error = model.errorMessage {
                Divider()
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("action.retry") { Task { await model.retry() } }
                }
                .font(scale.font(.caption)).padding(8)
            }
        }
        .task { await model.reload() }
        .releaseAssetDownloadToast(message: $downloads.message, fileURL: $downloads.fileURL)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AIOrganizationBusinessIconBadge(icon: .packageAsset, tint: .accentColor)
            Text("releases.timeline.title").font(scale.font(.panelTitle, weight: .semibold))
            Spacer()
            SyncIconButton(isRefreshing: model.isChecking, disabled: model.isChecking,
                           tooltip: String.l10n("releases.timeline.checkNow")) {
                Task { await model.checkNow() }
            }
            SheetCloseButton(action: onClose, iconFont: .title3, helpKey: "general.close")
        }
        .padding(.horizontal, 16).frame(height: AIOrganizationLayout.headerHeight)
    }

    private var sidebar: some View {
        let visible = model.visibleEntries
        let identity = model.search
        return VStack(spacing: 0) {
            ReleaseSearchField(label: "releases.workspace.search", text: $model.search)
                .padding(10)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if !model.hasLoaded && model.errorMessage == nil {
                            ListLoadingSkeleton(rowCount: 7, rowHeight: 49)
                        }
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                            Button { model.select(entry.id) } label: {
                                ReleaseNavigationLabel(entry: entry)
                            }
                            .buttonStyle(.plain).focusEffectDisabled()
                            .listRowSurface(index: index, isSelected: entry.id == model.selectedID,
                                            selectionNamespace: rowSelection)
                            .accessibilityAddTraits(entry.id == model.selectedID ? .isSelected : [])
                            .id(entry.id)
                            .automaticListPagination(appearingIndex: index, visibleItemCount: visible.count,
                                                     loadedItemCount: model.entries.count, hasMore: model.hasMore,
                                                     isLoading: model.isLoading, identity: identity) {
                                await model.loadMore()
                            }
                        }
                        if model.isLoading && model.hasLoaded { ProgressView().controlSize(.small) }
                    }.padding(6)
                }
                .onChange(of: model.selectedID) { _, selected in
                    if let selected { scroll.scrollTo(selected) }
                }
            }
            .automaticListPaginationFill(
                visibleItemCount: model.pendingTarget == nil ? visible.count : 0, loadedItemCount: model.entries.count,
                hasMore: model.hasMore, isLoading: model.isLoading,
                identity: "\(identity):\(model.pendingTarget.map(String.init) ?? "")"
            ) { await model.loadMore() }
        }
    }

    @ViewBuilder private var detail: some View {
        if let entry = model.selection {
            ReleaseWorkspaceDetail(entry: entry, tab: $tab, filter: $assetFilter, downloads: downloads)
        } else if model.errorMessage != nil {
            EmptyStateView(systemImage: "exclamationmark.triangle", title: "releases.timeline.error.loadFailed")
        } else if !model.hasLoaded || model.hasMore {
            ListLoadingSkeleton(rowCount: 4, rowHeight: 48, showsIcon: false).padding(18)
        } else if model.entries.isEmpty {
            EmptyStateView(systemImage: "shippingbox", title: "releases.timeline.empty.title",
                           subtitle: "releases.timeline.empty.subtitle")
        } else {
            EmptyStateView(systemImage: "magnifyingglass", title: "empty.noResults") {
                Button("ai.usage.empty.clearFilters") { model.search = "" }
            }
        }
    }
}

/// 同一条记录只在左栏展示仓库、时间、tag；长标题和完整信息留给详情。
private struct ReleaseNavigationLabel: View {
    let entry: ReleaseTimelineEntry
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var scale

    var body: some View {
        HStack(spacing: 9) {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: entry.repo.owner), size: 26, showBorder: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(verbatim: entry.repo.fullName).font(scale.font(.body, weight: .semibold))
                        .truncationMode(.middle).layoutPriority(1)
                    Spacer(minLength: 4)
                    if let date = entry.displayDate {
                        Text(verbatim: RelativeTimeText.pastEvent(date, locale: locale))
                            .font(scale.font(.captionSmall)).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: entry.release.tagName).font(scale.font(.code))
                    .foregroundStyle(.secondary).truncationMode(.middle)
            }.lineLimit(1)
        }
        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 49, alignment: .leading)
        .contentShape(Rectangle())
        .help(Text(verbatim: "\(entry.repo.fullName) · \(entry.release.tagName)"))
    }
}

private enum ReleaseWorkspaceTab: CaseIterable { case notes, files }

/// 顶部链接分别指向仓库和该版本；替换正文不重建筛选状态、下载任务或导航列表。
private struct ReleaseWorkspaceDetail: View {
    let entry: ReleaseTimelineEntry
    @Binding var tab: ReleaseWorkspaceTab
    @Binding var filter: ReleaseArtifactFilter
    let downloads: ReleaseWorkspaceDownloads
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.locale) private var locale

    var body: some View {
        let assets = ReleaseAssetCodec.decode(entry.release.assetsJson)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let url = URL(string: entry.repo.htmlUrl) {
                        Link(destination: url) {
                            HStack(spacing: 5) {
                                Image(systemName: "folder")
                                Text(verbatim: entry.repo.fullName).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    if let url = URL(string: entry.release.htmlUrl) {
                        Link(destination: url) {
                            Label("releases.openOnGitHub", systemImage: "arrow.up.right.square")
                        }.lineLimit(1)
                    }
                }.font(scale.font(.caption))
                let name = entry.release.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(verbatim: name.flatMap { $0.isEmpty ? nil : $0 } ?? entry.release.tagName)
                    .font(scale.font(.panelTitle)).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 7) {
                    Text(verbatim: entry.release.tagName).font(scale.font(.code)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(Text(verbatim: entry.release.tagName))
                    if entry.release.isPrerelease {
                        Text("releases.row.prerelease").font(scale.font(.captionSmall, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.17), in: Capsule()).fixedSize()
                    }
                    if let date = entry.displayDate {
                        Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(date, format: .dateTime.year().month().day().locale(locale))
                            .font(scale.font(.captionSmall)).foregroundStyle(.secondary).fixedSize()
                    }
                }
                CountedSegmentedControl(
                    items: ReleaseWorkspaceTab.allCases, selection: $tab, totalCount: assets.count,
                    title: { item in
                        if item == .notes { return "releases.workspace.notes" }
                        return LocalizedStringKey(String(
                            format: String.l10n("releases.workspace.downloadsFormat"), locale: locale, assets.count
                        ))
                    },
                    count: { _ in nil }, accessibilityLabel: "releases.timeline.title"
                )
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 3)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            Group {
                switch tab {
                case .notes: notes
                case .files: ReleaseWorkspaceAssets(assets: assets, filter: $filter, downloads: downloads)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .nativeDetailTransition(value: tab)
        }
    }

    @ViewBuilder private var notes: some View {
        if let notes = entry.release.bodyMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            // 正文自带滚动与阅读工具，不能再套原生 ScrollView；附件页仍使用原有下载状态。
            MarkdownDocumentWebView(
                markdown: GitHubMarkdownPreparing.prepare(notes),
                baseURL: URL(string: entry.release.htmlUrl)
            )
        } else {
            EmptyStateView(systemImage: "doc.text", title: "activity.release.noNotes")
        }
    }
}

/// 两个搜索域外观一致，但分别作用于仓库版本和当前版本的附件。
struct ReleaseSearchField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    @Environment(\.starcatInterfaceScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(label, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).focusEffectDisabled()
                    .accessibilityLabel(Text("ai.usage.empty.clearFilters"))
            }
        }
        .font(scale.font(.body))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.22)) }
    }
}
